/**
 * gradgame-game.js — 4-player Graph War controller (browser glue).
 * ──────────────────────────────────────────────────────────────────────────
 * Calls the wasm engine (window.gradGameEngine, from gradgame-wasm.js), syncs the
 * shared match over Firebase Realtime Database, and feeds the WGSL battlefield
 * renderer (window.Battlefield, from gradgame-graph.js) a fresh scene each frame.
 *
 * `start({ db, auth, uid })` is called by the Firebase bootstrap in index.html
 * once anonymous sign-in resolves.
 *
 * Data model (games/main):
 *   meta:    { status, round, turnIndex, winner, turnSeconds, turnStartedAt }
 *   players/{0..3}: { uid, name, token, x, y, alive, ready, score, color, joinedAt }
 *   obstacles: [ { x, y, r }, … ]
 *   shot:    { seq, by, expr, dir, outcome, impact, ts }   // latest shot only; clients rebuild the path
 *   history/{seq}: { seq, round, by, name, color, expr, tex, outcome, hitSeat, ts }
 *
 * Authority: client-side. The shooter computes its own outcome and writes the
 * shot + the resulting elimination/turn transition in one multi-path update;
 * every client animates the latest `shot` (so off-turn players spectate).
 * ──────────────────────────────────────────────────────────────────────────
 */
import {
    ref, onValue, set, update, remove,
    runTransaction, onDisconnect, serverTimestamp,
} from 'https://www.gstatic.com/firebasejs/12.14.0/firebase-database.js';

// The Graph War engine (expression evaluator, trajectory sim, placement, turn
// logic) now lives entirely in GradGame.wasm, reached through window.gradGameEngine
// (set up by gradgame-wasm.js). Only these UI/battlefield constants stay in JS.
const WORLD = { xMin: -12, xMax: 12, yMin: -6.75, yMax: 6.75 };
const CANNON_RADIUS = 0.55;
const TURN_SECONDS = 30;
const PLAYER_COLORS = [
    [0.13, 0.83, 0.93, 1.0], // 0 cyan   #22d3ee
    [0.98, 0.45, 0.52, 1.0], // 1 rose   #fb7185
    [0.98, 0.75, 0.14, 1.0], // 2 amber  #fbbf24
    [0.65, 0.55, 0.98, 1.0], // 3 violet #a78bfa
];
const PLAYER_COLOR_HEX = ['#22d3ee', '#fb7185', '#fbbf24', '#a78bfa'];

const GAME_PATH = 'games/main';
const KEY_TOKEN = 'gradgame:token';
const KEY_NAME  = 'gradgame:name';
const MAX_HISTORY_ENTRIES = 30;

let started = false;

export function start({ db, uid }) {
    if (started) return;
    started = true;

    // The wasm engine API (installed by gradgame-wasm.js before sign-in resolves).
    const E = window.gradGameEngine;

    /* ── Identity ──────────────────────────────────────────────────────── */
    let token = localStorage.getItem(KEY_TOKEN);
    if (!token) {
        token = (crypto.randomUUID && crypto.randomUUID()) || String(Math.random()).slice(2);
        localStorage.setItem(KEY_TOKEN, token);
    }

    /* ── Renderer hand-off ─────────────────────────────────────────────── */
    if (window.Battlefield) window.Battlefield.enterGameMode();
    console.log('[GraphWar] start: uid=', uid, 'seat-token=', token.slice(0, 8));
    setTimeout(() => {
        const ready = !!(window.Battlefield && window.Battlefield.ready);
        console.log('[GraphWar] WebGPU renderer ready =', ready,
            ready ? '' : '(blank board → check for a "WebGPU graph init failed" error above)');
    }, 1800);

    /* ── Local state ───────────────────────────────────────────────────── */
    let state = null;           // { meta, players[4], obstacles[], shot, history[] }
    let mySeat = -1;
    let serverOffset = 0;
    let seenSeq = 0;
    let lastRoundKey = '';
    let emptyResetPending = false;
    const shotQueue = [];
    const observedHistory = [];
    let activeShot = null;      // { by, path, outcome, impact, t0, dur, doneAt }
    const persistentArcs = [];  // resolved arcs kept (faint) for the round
    let aimPoints = null;
    let aimKey = '';            // signature of the cached aim preview (expr|x|y|dir)

    const serverNow = () => Date.now() + serverOffset;
    const gRef = (p) => ref(db, p ? `${GAME_PATH}/${p}` : GAME_PATH);

    /* ── DOM ───────────────────────────────────────────────────────────── */
    const $ = (id) => document.getElementById(id);
    const chips = [0, 1, 2, 3].map((s) => document.querySelector(`.player-chip[data-seat="${s}"]`));
    const statusEl = $('game-status');
    const timerEl  = $('game-timer');
    const readyBtn = $('game-ready');
    const toastEl  = $('game-toast');
    const inputEl  = $('session-load');

    chips.forEach((chip, seat) => {
        if (!chip) return;
        chip.style.setProperty('--pc', PLAYER_COLOR_HEX[seat]);
        chip.addEventListener('click', () => onChipClick(seat));
    });
    readyBtn?.addEventListener('click', toggleReady);
    inputEl?.addEventListener('keydown', (e) => {
        if (e.key === 'Enter') fire();
    });

    /* ── Subscriptions ─────────────────────────────────────────────────── */
    onValue(ref(db, '.info/serverTimeOffset'), (s) => { serverOffset = s.val() || 0; });
    onValue(gRef(), onState);

    /* ── Watchdog: turn timeout + vacated-turn recovery ────────────────── */
    setInterval(watchdog, 700);

    /* ── Render loop ───────────────────────────────────────────────────── */
    requestAnimationFrame(frame);

    /* ════════════════════════════════════════════════════════════════════
       State
       ════════════════════════════════════════════════════════════════════ */
    function onState(snap) {
        const v = snap.val() || {};
        let meta = v.meta || emptyLobbyMeta();
        const playersRaw = v.players || {};
        const players = [0, 1, 2, 3].map((i) => playersRaw[i] || null);
        let obstacles = Array.isArray(v.obstacles)
            ? v.obstacles
            : (v.obstacles ? Object.values(v.obstacles) : []);
        let shot = v.shot || null;
        let history = parseHistory(v.history, players);

        if (!players.some(Boolean)) {
            if (needsEmptyGameReset(meta, obstacles, shot)) resetEmptyGame();
            meta = emptyLobbyMeta();
            obstacles = [];
            shot = null;
            history = [];
            clearRoundEffects();
        } else if (!shot) {
            seenSeq = 0;
        }

        state = { meta, players, obstacles, shot, history };

        mySeat = players.findIndex((p) => p && (p.uid === uid || p.token === token));

        // Fresh round / new match → drop the faint arcs from the previous one.
        const roundKey = `${meta.round || 0}:${meta.status}`;
        if (roundKey !== lastRoundKey) {
            persistentArcs.length = 0;
            if (meta.status === 'lobby' || (meta.status === 'playing' && !shot)) {
                observedHistory.length = 0;
            }
            lastRoundKey = roundKey;
            if (meta.status !== 'playing') { activeShot = null; shotQueue.length = 0; }
        }

        // New shot to animate (every client watches the latest shot).
        if (shot && shot.seq && shot.seq !== seenSeq) {
            seenSeq = shot.seq;
            shotQueue.push(shot);
            recordObservedShot(shot, players, meta.round || 0);
        }

        state.history = mergeHistory(state.history, observedHistory);
        updateHUD();
        updateHistoryPanel();
        maybeStart();
    }

    /* ════════════════════════════════════════════════════════════════════
       Seats — claim / leave / ready
       ════════════════════════════════════════════════════════════════════ */
    function onChipClick(seat) {
        if (!state) return;
        const occupant = state.players[seat];
        if (seat === mySeat) { leaveSeat(seat); return; }
        if (occupant) { toast('Seat taken'); return; }
        if (mySeat >= 0) { toast('You already hold a seat'); return; }
        claimSeat(seat);
    }

    async function claimSeat(seat) {
        const name = playerName();
        try {
            const res = await runTransaction(gRef(`players/${seat}`), (cur) => {
                if (cur) return; // occupied → abort
                return {
                    uid, name, token, color: seat,
                    x: 0, y: 0, alive: false, ready: false, score: 0,
                    joinedAt: Date.now(),
                };
            });
            if (res.committed) {
                mySeat = seat;
                onDisconnect(gRef(`players/${seat}`)).remove(); // closing the tab frees the seat
            } else {
                toast('Seat taken');
            }
        } catch (err) {
            console.error('claim failed', err);
        }
    }

    async function leaveSeat(seat) {
        try {
            await onDisconnect(gRef(`players/${seat}`)).cancel();
            const leavingLastSeat = state && !state.players.some((p, i) => i !== seat && p);
            if (leavingLastSeat) {
                await update(gRef(), {
                    [`players/${seat}`]: null,
                    ...emptyLobbyUpdates(),
                });
                clearRoundEffects();
            } else {
                await remove(gRef(`players/${seat}`));
            }
            mySeat = -1;
        } catch (err) {
            console.error('leave failed', err);
        }
    }

    function toggleReady() {
        if (mySeat < 0 || !state) return;
        if (state.meta.status === 'playing') return;
        const me = state.players[mySeat];
        set(gRef(`players/${mySeat}/ready`), !(me && me.ready));
    }

    /* All occupied seats ready (≥2) → the lowest seat performs the start write. */
    function maybeStart() {
        if (mySeat < 0 || !state) return;
        if (state.meta.status === 'playing') return;
        const occ = occupiedSeats();
        if (occ.length < 2 || mySeat !== occ[0]) return;
        if (!occ.every((i) => state.players[i].ready)) return;

        const positions = E.placePlayers(occ);
        const obstacles = E.generateObstacles(positions);
        const updates = { obstacles, shot: null };
        for (const i of occ) {
            updates[`players/${i}/x`] = positions[i].x;
            updates[`players/${i}/y`] = positions[i].y;
            updates[`players/${i}/alive`] = true;
            updates[`players/${i}/ready`] = false;
            updates[`players/${i}/score`] = 0;
        }
        updates.meta = {
            status: 'playing',
            round: (state.meta.round || 0) + 1,
            turnIndex: occ[0],
            winner: null,
            turnSeconds: TURN_SECONDS,
            turnStartedAt: serverTimestamp(),
        };
        console.log('[GraphWar] starting match: seats', occ, 'positions', positions);
        update(gRef(), updates)
            .then(() => {
                console.log('[GraphWar] start write OK');
                clearSharedHistory();
            })
            .catch((err) => {
                console.error('[GraphWar] start write FAILED (re-paste database.rules.json — a client must be able to write other seats):', err);
                toast('Start blocked — update database rules');
            });
    }

    /* ════════════════════════════════════════════════════════════════════
       Firing — compute the shot client-side, write shot + turn transition
       ════════════════════════════════════════════════════════════════════ */
    function fire() {
        if (!canFire()) {
            console.log('[GraphWar] fire blocked:', {
                hasState: !!state, status: state && state.meta.status,
                mySeat, turnIndex: state && state.meta.turnIndex,
                alive: state && mySeat >= 0 && state.players[mySeat] && state.players[mySeat].alive,
                activeShot: !!activeShot, queued: shotQueue.length,
            });
            return;
        }
        const me = state.players[mySeat];
        const expr = inputEl.value.trim();
        const cannons = cannonArray();
        const dir = E.aimDirection({ x: me.x, y: me.y }, cannons, mySeat);
        const sim = E.simulateShot({
            expr, originX: me.x, originY: me.y, dir,
            shooterSeat: mySeat, cannons, obstacles: state.obstacles,
        });
        if (!sim) { toast('Type a valid function first'); console.log('[GraphWar] invalid function for fire:', expr); return; }

        const seq = (state.shot && state.shot.seq ? state.shot.seq : 0) + 1;
        const shot = {
            // No `js`/`path`: clients rebuild the arc from `expr` + dir + impact via
            // the wasm engine's resampleArc (the wasm parser is the single source).
            seq, by: mySeat, expr, dir,
            outcome: sim.outcome, impact: sim.impact || null,
            ts: serverTimestamp(),
        };
        const historyEntry = historyEntryForShot({
            ...shot,
            round: state.meta.round || 1,
            hitSeat: sim.hitSeat >= 0 ? sim.hitSeat : null,
        }, state.players);
        const updates = {
            // No `path`: every client rebuilds it from expr + dir + impact (resampleArc).
            shot,
        };

        const alive = state.players.map((p) => p && p.alive);
        if (sim.outcome === 'hit' && sim.hitSeat >= 0) {
            updates[`players/${sim.hitSeat}/alive`] = false;
            alive[sim.hitSeat] = false;
            updates[`players/${mySeat}/score`] = (me.score || 0) + 1;
        }

        const survivors = [];
        for (let i = 0; i < 4; i++) if (state.players[i] && alive[i]) survivors.push(i);

        const meta = {
            status: 'playing',
            round: state.meta.round || 1,
            turnIndex: state.meta.turnIndex,
            winner: null,
            turnSeconds: state.meta.turnSeconds || TURN_SECONDS,
            turnStartedAt: serverTimestamp(),
        };
        if (survivors.length <= 1) {
            meta.status = 'over';
            meta.winner = survivors.length === 1 ? survivors[0] : null;
        } else {
            meta.turnIndex = E.nextAliveSeat(
                state.players.map((p, i) => (p ? { alive: alive[i] } : null)),
                mySeat,
            );
        }
        updates.meta = meta;

        console.log('[GraphWar] firing shot:', { outcome: sim.outcome, hitSeat: sim.hitSeat, pathLen: sim.path.length, nextTurn: meta.turnIndex });
        update(gRef(), updates)
            .then(() => {
                console.log('[GraphWar] shot write OK');
                writeHistoryEntry(historyEntry);
            })
            .catch((err) => { console.error('[GraphWar] shot write FAILED (check RTDB rules):', err); toast('Write blocked — check database rules'); });
        inputEl.value = '';
        aimPoints = null;
    }

    function canFire() {
        return state && state.meta.status === 'playing'
            && mySeat >= 0 && state.meta.turnIndex === mySeat
            && state.players[mySeat] && state.players[mySeat].alive
            && !activeShot && shotQueue.length === 0;
    }

    /* ════════════════════════════════════════════════════════════════════
       Watchdog — only one client ever advances a given turn
       ════════════════════════════════════════════════════════════════════ */
    function watchdog() {
        if (!state || state.meta.status !== 'playing' || activeShot) return;
        const ti = state.meta.turnIndex;
        const holder = state.players[ti];
        const remaining = remainingMs();
        const aliveSeats = aliveSeatList();

        if (mySeat === ti && holder && holder.alive && remaining <= 0) {
            passTurn(ti);                                   // my time is up
        } else if ((!holder || !holder.alive) && aliveSeats[0] === mySeat && remaining < -1000) {
            passTurn(ti);                                   // turn holder vanished
        } else if (remaining < -5000 && aliveSeats[0] === mySeat) {
            passTurn(ti);                                   // stalled (holder disconnected)
        }
    }

    function passTurn(fromSeat) {
        const survivors = aliveSeatList();
        if (survivors.length <= 1) {
            update(gRef('meta'), {
                status: 'over', winner: survivors[0] ?? null,
                turnIndex: state.meta.turnIndex,
            });
            return;
        }
        const next = E.nextAliveSeat(
            state.players.map((p) => (p ? { alive: p.alive } : null)),
            fromSeat,
        );
        update(gRef('meta'), {
            status: 'playing', turnIndex: next, winner: null,
            round: state.meta.round || 1,
            turnSeconds: state.meta.turnSeconds || TURN_SECONDS,
            turnStartedAt: serverTimestamp(),
        });
    }

    function emptyLobbyMeta() {
        return {
            status: 'lobby',
            round: 0,
            turnIndex: 0,
            winner: null,
            turnSeconds: TURN_SECONDS,
        };
    }

    function emptyLobbyUpdates() {
        return {
            meta: emptyLobbyMeta(),
            obstacles: null,
            shot: null,
        };
    }

    function needsEmptyGameReset(meta, obstacles, shot) {
        return Boolean(
            shot
            || obstacles.length
            || meta.status !== 'lobby'
            || (meta.round || 0) !== 0
            || (meta.turnIndex || 0) !== 0
            || meta.winner != null
            || meta.turnStartedAt != null
            || (meta.turnSeconds || TURN_SECONDS) !== TURN_SECONDS
        );
    }

    function resetEmptyGame() {
        if (emptyResetPending) return;
        emptyResetPending = true;
        update(gRef(), emptyLobbyUpdates())
            .then(() => {
                clearSharedHistory();
            })
            .catch((err) => {
                console.error('[GraphWar] empty lobby reset failed', err);
            })
            .finally(() => {
                emptyResetPending = false;
            });
    }

    function clearRoundEffects() {
        seenSeq = 0;
        shotQueue.length = 0;
        observedHistory.length = 0;
        activeShot = null;
        persistentArcs.length = 0;
        aimPoints = null;
        if (state) state.history = [];
        updateHistoryPanel();
    }

    function parseHistory(raw, players) {
        const values = Array.isArray(raw)
            ? raw.filter(Boolean)
            : (raw && typeof raw === 'object' ? Object.values(raw) : []);
        return values
            .map((entry) => normalizeHistoryEntry(entry, players))
            .filter(Boolean)
            .sort(compareHistoryEntries)
            .slice(-MAX_HISTORY_ENTRIES);
    }

    function historyEntryForShot(shot, players) {
        const tex = parseInputToTeX(shot.expr || '');
        return normalizeHistoryEntry({
            seq: shot.seq,
            round: shot.round || 0,
            by: shot.by,
            name: players[shot.by]?.name,
            color: PLAYER_COLOR_HEX[shot.by],
            expr: shot.expr,
            tex: tex.ok ? tex.text : '',
            ok: tex.ok,
            outcome: shot.outcome,
            hitSeat: shot.hitSeat ?? null,
            ts: shot.ts || Date.now(),
        }, players);
    }

    function normalizeHistoryEntry(entry, players) {
        if (!entry || typeof entry.expr !== 'string' || !entry.expr.trim()) return null;
        const seat = Number(entry.by);
        if (!Number.isInteger(seat) || seat < 0 || seat > 3) return null;
        const player = players[seat];
        const seq = Number(entry.seq) || 0;
        return {
            seq,
            round: Number(entry.round) || 0,
            by: seat,
            name: String(entry.name || player?.name || `Player ${seat + 1}`).slice(0, 24),
            color: validPlayerColor(entry.color) ? entry.color : PLAYER_COLOR_HEX[seat],
            expr: entry.expr.trim(),
            tex: typeof entry.tex === 'string' ? entry.tex : '',
            ok: entry.ok !== false,
            outcome: typeof entry.outcome === 'string' ? entry.outcome : '',
            hitSeat: Number.isInteger(entry.hitSeat) ? entry.hitSeat : null,
            ts: typeof entry.ts === 'number' ? entry.ts : 0,
        };
    }

    function validPlayerColor(color) {
        return typeof color === 'string' && /^#[0-9a-f]{6}$/i.test(color);
    }

    function compareHistoryEntries(a, b) {
        return (a.round - b.round) || (a.seq - b.seq) || (a.ts - b.ts);
    }

    function mergeHistory(...groups) {
        const byKey = new Map();
        for (const group of groups) {
            for (const entry of group || []) {
                byKey.set(`${entry.round}:${entry.seq}`, entry);
            }
        }
        return [...byKey.values()].sort(compareHistoryEntries).slice(-MAX_HISTORY_ENTRIES);
    }

    function recordObservedShot(shot, players, round) {
        const entry = historyEntryForShot({ ...shot, round }, players);
        if (!entry) return;
        const key = `${entry.round}:${entry.seq}`;
        const existing = observedHistory.findIndex((item) => `${item.round}:${item.seq}` === key);
        if (existing >= 0) observedHistory.splice(existing, 1);
        observedHistory.push(entry);
        observedHistory.sort(compareHistoryEntries);
        if (observedHistory.length > MAX_HISTORY_ENTRIES) {
            observedHistory.splice(0, observedHistory.length - MAX_HISTORY_ENTRIES);
        }
    }

    function writeHistoryEntry(entry) {
        if (!entry) return;
        set(gRef(`history/${entry.seq}`), {
            ...entry,
            ts: serverTimestamp(),
        }).catch((err) => {
            console.warn('[GraphWar] history write skipped (update database.rules.json for shared history):', err);
        });
    }

    function clearSharedHistory() {
        remove(gRef('history')).catch((err) => {
            console.warn('[GraphWar] history clear skipped:', err);
        });
    }

    function updateHistoryPanel() {
        document.dispatchEvent(new CustomEvent('gradgame:history', {
            detail: { entries: state ? state.history : [] },
        }));
    }

    /* ════════════════════════════════════════════════════════════════════
       Animation + scene
       ════════════════════════════════════════════════════════════════════ */
    function frame(now) {
        requestAnimationFrame(frame);
        pollAim();
        stepAnimation(now);
        if (window.Battlefield) window.Battlefield.setScene(buildScene());
        updateTimer();
    }

    function stepAnimation(now) {
        if (!activeShot && shotQueue.length) {
            const s = shotQueue.shift();
            const path = pathForShot(s);                 // rebuilt locally; RTDB carries no path
            const dur = Math.min(1700, Math.max(450, (path ? path.length : 0) * 3));
            activeShot = { ...s, path, t0: now, dur, doneAt: 0 };
        }
        if (!activeShot) return;
        const elapsed = now - activeShot.t0;
        if (elapsed >= activeShot.dur) {
            if (!activeShot.doneAt) activeShot.doneAt = now;
            if (now - activeShot.doneAt > 520) {            // brief linger on impact
                if (activeShot.path && activeShot.path.length > 1) {
                    persistentArcs.push({ points: activeShot.path, seat: activeShot.by });
                }
                activeShot = null;
            }
        }
    }

    /* Rebuild a shot's polyline from its compact RTDB record (js + dir + impact).
       The shooter's cannon hasn't moved since firing, so its current position is
       the firing origin; the stored impact x ends the arc exactly where the
       authoritative sim stopped, independent of since-changed alive/obstacle state. */
    function pathForShot(shot) {
        if (!shot || !state) return null;
        const shooter = state.players[shot.by];
        if (!shooter || shooter.x == null) return null;
        const hasImpact = shot.impact && typeof shot.impact.x === 'number';
        const pts = E.resampleArc({
            expr: shot.expr, originX: shooter.x, originY: shooter.y,
            dir: shot.dir || 1, endX: hasImpact ? shot.impact.x : null,
        });
        if (!pts) return null;
        if (hasImpact) pts.push([shot.impact.x, shot.impact.y]);
        return pts.length > 1 ? pts : null;
    }

    function buildScene() {
        const entities = [];
        const paths = [];
        if (!state) return { entities, paths };

        // Obstacles
        for (const o of state.obstacles) {
            entities.push({ x: o.x, y: o.y, r: o.r, kind: 0, color: [0.30, 0.35, 0.45, 0.95] });
        }

        // Faint resolved arcs from this round
        for (const arc of persistentArcs) {
            const c = PLAYER_COLORS[arc.seat] || [1, 1, 1, 1];
            paths.push({ points: arc.points, color: [c[0], c[1], c[2], 0.22], width: 2 });
        }

        // Aim preview (my turn)
        if (aimPoints && aimPoints.length > 1 && canFire()) {
            const c = PLAYER_COLORS[mySeat] || [1, 1, 1, 1];
            paths.push({ points: aimPoints, color: [c[0], c[1], c[2], 0.40], width: 1.5 });
        }

        // Active shot trail + head
        if (activeShot && activeShot.path && activeShot.path.length > 1) {
            const c = PLAYER_COLORS[activeShot.by] || [1, 1, 1, 1];
            const n = activeShot.path.length;
            const progress = Math.min(1, (performance.now() - activeShot.t0) / activeShot.dur);
            const head = Math.max(1, Math.floor(progress * (n - 1)));
            paths.push({ points: activeShot.path.slice(0, head + 1), color: [c[0], c[1], c[2], 0.95], width: 3 });
            const hp = activeShot.path[head];
            entities.push({ x: hp[0], y: hp[1], r: CANNON_RADIUS * 0.55, kind: 2, color: c });
        }

        // Cannons (+ turn glow) — only once a match has placed them (not at the
        // lobby origin); shown during play and on the final 'over' board.
        const playing = state.meta.status === 'playing';
        const showBoard = playing || state.meta.status === 'over';
        for (let seat = 0; showBoard && seat < 4; seat++) {
            const p = state.players[seat];
            if (!p || p.x == null) continue;
            const isTurn = playing && state.meta.turnIndex === seat && p.alive && !activeShot;
            const base = PLAYER_COLORS[seat] || [1, 1, 1, 1];
            if (isTurn) {
                entities.push({ x: p.x, y: p.y, r: CANNON_RADIUS * 2.4, kind: 3, color: [base[0], base[1], base[2], 0.5] });
            }
            const color = p.alive ? base : [0.5, 0.52, 0.58, 0.45];
            entities.push({ x: p.x, y: p.y, r: CANNON_RADIUS, kind: 1, color });
        }

        return { entities, paths };
    }

    /* Rebuild the aim curve via the wasm engine only when the expression, my cannon
       position, or the firing direction changes — keyed so the steady state makes
       no wasm calls per frame (resampleArc with endX=null sweeps to the field edge). */
    function pollAim() {
        if (!canFire()) { aimPoints = null; aimKey = ''; return; }
        const me = state.players[mySeat];
        const dir = E.aimDirection({ x: me.x, y: me.y }, cannonArray(), mySeat);
        const input = inputEl ? inputEl.value.trim() : '';
        const key = `${input}|${me.x}|${me.y}|${dir}`;
        if (key === aimKey) return;
        aimKey = key;
        const pts = input
            ? E.resampleArc({ expr: input, originX: me.x, originY: me.y, dir, endX: null })
            : null;
        aimPoints = (pts && pts.length > 1) ? pts : null;
    }

    /* ════════════════════════════════════════════════════════════════════
       HUD
       ════════════════════════════════════════════════════════════════════ */
    function updateHUD() {
        if (!state) return;
        const { meta, players } = state;
        const playing = meta.status === 'playing';

        chips.forEach((chip, seat) => {
            if (!chip) return;
            const p = players[seat];
            const nameEl = chip.querySelector('.player-chip-name');
            let st;
            if (!p) st = 'empty';
            else if (!p.alive && playing) st = 'dead';
            else if (playing && meta.turnIndex === seat) st = 'turn';
            else st = 'occupied';
            chip.dataset.state = st;
            chip.classList.toggle('is-self', seat === mySeat);
            chip.classList.toggle('is-ready', Boolean(p && p.ready && !playing));
            if (nameEl) {
                nameEl.textContent = p
                    ? p.name + (seat === mySeat ? ' (you)' : '')
                    : 'Open';
            }
        });

        // Status line
        if (meta.status === 'over') {
            const w = meta.winner;
            const wp = w != null ? players[w] : null;
            statusEl.textContent = wp ? `${wp.name} wins! 🏆` : 'Match over';
        } else if (playing) {
            const tp = players[meta.turnIndex];
            if (mySeat >= 0 && meta.turnIndex === mySeat) statusEl.textContent = 'Your turn — type f(x) and press Enter';
            else statusEl.textContent = `${tp ? tp.name : 'Someone'} is aiming…`;
        } else {
            const occ = occupiedSeats();
            statusEl.textContent = occ.length < 2
                ? 'Waiting for players… claim a seat above'
                : 'Ready up to start';
        }

        // Ready / start button
        if (mySeat < 0) {
            readyBtn.hidden = true;
        } else {
            readyBtn.hidden = false;
            if (playing) {
                readyBtn.disabled = true;
                readyBtn.textContent = 'In play';
            } else {
                readyBtn.disabled = false;
                readyBtn.textContent = (players[mySeat] && players[mySeat].ready) ? 'Ready ✓ (cancel)' : 'Ready';
            }
        }

        // Input availability
        const my = canFire();
        if (inputEl) {
            inputEl.disabled = playing && !my && mySeat >= 0 && false; // keep editable for live preview
            inputEl.placeholder = my ? 'sin x   ·   x^2/8   ·   2 sin x' : 'sin x y + x ^ 2 + 3';
        }
    }

    function updateTimer() {
        if (!state || state.meta.status !== 'playing' || !timerEl) {
            if (timerEl) timerEl.textContent = '';
            return;
        }
        const remaining = Math.max(0, Math.ceil(remainingMs() / 1000));
        timerEl.textContent = `⏱ ${remaining}s`;
        timerEl.classList.toggle('low', remaining <= 5);
    }

    /* ════════════════════════════════════════════════════════════════════
       Helpers
       ════════════════════════════════════════════════════════════════════ */
    function occupiedSeats() {
        const out = [];
        for (let i = 0; i < 4; i++) if (state.players[i]) out.push(i);
        return out;
    }
    function aliveSeatList() {
        const out = [];
        for (let i = 0; i < 4; i++) if (state.players[i] && state.players[i].alive) out.push(i);
        return out;
    }
    function cannonArray() {
        return state.players.map((p) => (p ? { x: p.x, y: p.y, alive: p.alive } : null));
    }
    function remainingMs() {
        const m = state.meta;
        if (!m.turnStartedAt) return (m.turnSeconds || TURN_SECONDS) * 1000;
        return m.turnStartedAt + (m.turnSeconds || TURN_SECONDS) * 1000 - serverNow();
    }
    /* Render the raw expression to TeX via the Wasm parser exposed by
       gradgame-wasm.js — used for the shared shot history. */
    function parseInputToTeX(input) {
        if (input && window.gradGameParse) {
            try {
                const r = window.gradGameParse.toTeX(input);
                return r && r.ok ? { ok: true, text: r.text } : { ok: false, text: '' };
            } catch (e) {
                console.error('[GraphWar] TeX parse failed', e);
            }
        }
        return { ok: false, text: '' };
    }
    function playerName() {
        let name = localStorage.getItem(KEY_NAME);
        if (!name) {
            name = (window.prompt('Pick a name', 'Player') || 'Player').trim().slice(0, 24) || 'Player';
            localStorage.setItem(KEY_NAME, name);
        }
        return name;
    }
    let toastTimer = null;
    function toast(msg) {
        if (!toastEl) return;
        toastEl.textContent = msg;
        toastEl.classList.add('show');
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => toastEl.classList.remove('show'), 2200);
    }
}
