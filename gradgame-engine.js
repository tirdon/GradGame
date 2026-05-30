/**
 * gradgame-engine.js
 * ──────────────────────────────────────────────────────────────────────────
 * Pure, dependency-free Graph War engine for the 4-player browser game — the
 * client-side port of BunServer's authoritative engine (`ecs.ts`, `systems.ts`,
 * `constants.ts`, `game.ts`). It has NO DOM, NO Firebase and NO `window` use,
 * so it is deterministically testable under Bun/Node and re-usable from the
 * browser glue (`gradgame-game.js`) and the renderer.
 *
 * It exports:
 *   • a tiny ECS core (World / defineComponent) — the "create ECS" ask,
 *   • the battlefield tunables (WORLD, STEP, …),
 *   • compile(js)            — parser-JS string → f(x) evaluator,
 *   • simulateShot(...)      — sweep y = py + f(x−px) → outcome + path,
 *   • aimDirection / turn / placement helpers for the 4-way free-for-all.
 * ──────────────────────────────────────────────────────────────────────────
 */

/* ═══ Tiny ECS core (port of BunServer/ecs.ts) ═══════════════════════════════ */

let nextComponentId = 0;

/** Declare a component type once, then reuse the handle. */
export function defineComponent(name) {
    return { id: nextComponentId++, name };
}

export class World {
    constructor() {
        this.nextEntity = 1;
        this.alive = new Set();
        this.stores = new Map(); // componentId → Map(entity → data)
    }

    create() {
        const e = this.nextEntity++;
        this.alive.add(e);
        return e;
    }

    destroy(e) {
        this.alive.delete(e);
        for (const store of this.stores.values()) store.delete(e);
    }

    exists(e) {
        return this.alive.has(e);
    }

    _storeFor(type) {
        let store = this.stores.get(type.id);
        if (!store) {
            store = new Map();
            this.stores.set(type.id, store);
        }
        return store;
    }

    add(e, type, data) {
        this._storeFor(type).set(e, data);
        return e;
    }

    remove(e, type) {
        this.stores.get(type.id)?.delete(e);
    }

    get(e, type) {
        return this.stores.get(type.id)?.get(e);
    }

    has(e, type) {
        return this.stores.get(type.id)?.has(e) ?? false;
    }

    /** Every entity owning all of the given components (iterates the smallest store). */
    query(...types) {
        if (types.length === 0) return [...this.alive];
        let smallest;
        for (const t of types) {
            const store = this.stores.get(t.id);
            if (!store) return [];
            if (!smallest || store.size < smallest.size) smallest = store;
        }
        const result = [];
        outer: for (const e of smallest.keys()) {
            for (const t of types) {
                if (!this.stores.get(t.id).has(e)) continue outer;
            }
            result.push(e);
        }
        return result;
    }

    first(type) {
        const store = this.stores.get(type.id);
        if (!store) return undefined;
        for (const e of store.keys()) return e;
        return undefined;
    }
}

/* ═══ Battlefield tunables (port of BunServer/constants.ts) ══════════════════ */

export const WORLD = { xMin: -12, xMax: 12, yMin: -6.75, yMax: 6.75 };
export const HIT_RADIUS = 0.55;        // a shot within this of a cannon scores
export const CANNON_RADIUS = HIT_RADIUS;
export const MUZZLE_CLEARANCE = 0.7;   // ignore collisions this close to the firer
export const STEP = 0.03;              // trajectory integration step
export const MAX_ABS_Y = 1e4;          // samples beyond this are gaps (asymptotes)
export const MAX_SEATS = 4;
export const TURN_SECONDS = 30;        // default per-turn clock
export const MIN_SEPARATION = 5.0;     // min spacing between cannons on Start

/** Per-seat colours (straight rgba in 0..1) used by the renderer + HUD. */
export const PLAYER_COLORS = [
    [0.13, 0.83, 0.93, 1.0], // 0 cyan   #22d3ee
    [0.98, 0.45, 0.52, 1.0], // 1 rose   #fb7185
    [0.98, 0.75, 0.14, 1.0], // 2 amber  #fbbf24
    [0.65, 0.55, 0.98, 1.0], // 3 violet #a78bfa
];
export const PLAYER_COLOR_HEX = ['#22d3ee', '#fb7185', '#fbbf24', '#a78bfa'];

/* ═══ Math evaluator (port of game.ts:compile) ══════════════════════════════ */

/** Compile the parser's JavaScript output into a reusable f(x) closure (or null). */
export function compile(js) {
    if (!js) return null;
    try {
        const fn = new Function(
            'x', 'y',
            `"use strict";
             var abs=Math.abs,acos=Math.acos,asin=Math.asin,atan=Math.atan,
                 atan2=Math.atan2,ceil=Math.ceil,cos=Math.cos,exp=Math.exp,
                 floor=Math.floor,log=Math.log,log2=Math.log2,log10=Math.log10,
                 max=Math.max,min=Math.min,pow=Math.pow,round=Math.round,
                 sign=Math.sign,sin=Math.sin,sqrt=Math.sqrt,tan=Math.tan,
                 PI=Math.PI,E=Math.E,
                 ln=Math.log,sec=function(a){return 1/Math.cos(a)},
                 csc=function(a){return 1/Math.sin(a)},
                 cot=function(a){return 1/Math.tan(a)};
             return (${js});`,
        );
        return (s) => {
            const v = fn(s, 0);
            return typeof v === 'number' ? v : NaN;
        };
    } catch {
        return null;
    }
}

/* ═══ Trajectory simulation (port of BunServer/systems.ts) ═══════════════════ */

function round3(v) {
    return Math.round(v * 1000) / 1000;
}

/**
 * Sweep the shot  y = originY + f(x − originX)  from the cannon in `dir` until
 * the first of: hit (a living non-shooter cannon), blocked (an obstacle), or out
 * (field edge). Returns { outcome, impact, path, hitSeat }.
 *
 * @param cannons  array indexed by seat 0..3 of { x, y, alive } | null
 */
export function simulateShot({ originX, originY, dir, f, cannons, obstacles, shooterSeat }) {
    const path = [];
    const limit = Math.ceil((WORLD.xMax - WORLD.xMin) / STEP) + 4;
    let x = originX;
    let outcome = null, impact = null, hitSeat = -1;

    for (let i = 0; i < limit; i++) {
        // bounds — off the field in the firing direction
        if ((dir > 0 && x > WORLD.xMax) || (dir < 0 && x < WORLD.xMin)) {
            outcome = 'out';
            break;
        }

        const s = x - originX;
        const travelled = Math.abs(s);
        const wy = originY + f(s);
        const valid = Number.isFinite(wy) && Math.abs(wy) < MAX_ABS_Y;
        if (valid) path.push([round3(x), round3(wy)]);

        // collision (ignored within the muzzle clearance / on off-scale samples)
        if (valid && travelled > MUZZLE_CLEARANCE) {
            let hit = -1;
            for (let c = 0; c < (cannons ? cannons.length : 0); c++) {
                const cn = cannons[c];
                if (c === shooterSeat || !cn || !cn.alive) continue;
                if (Math.hypot(x - cn.x, wy - cn.y) < CANNON_RADIUS) { hit = c; break; }
            }
            if (hit >= 0) {
                outcome = 'hit'; impact = { x: round3(x), y: round3(wy) }; hitSeat = hit;
                break;
            }
            let blocked = false;
            for (let o = 0; o < (obstacles ? obstacles.length : 0); o++) {
                const ob = obstacles[o];
                if (Math.hypot(x - ob.x, wy - ob.y) < ob.r) { blocked = true; break; }
            }
            if (blocked) { outcome = 'blocked'; impact = { x: round3(x), y: round3(wy) }; break; }
        }

        x += dir * STEP;
    }

    if (!outcome) outcome = 'out';
    if (!impact) {
        const last = path.length ? path[path.length - 1] : null;
        impact = last ? { x: last[0], y: last[1] } : null;
    }
    return { outcome, impact, path, hitSeat };
}

/**
 * Rebuild a shot's visible polyline from compact data (no stored path).
 * Sweeps  y = originY + f(x − originX)  from the cannon in `dir`, using the same
 * STEP / MAX_ABS_Y / rounding as simulateShot, stopping at `endX` (the shot's
 * impact x) so the arc ends exactly where the authoritative sim did — regardless
 * of how cannon/obstacle state has changed since. `endX == null` ⇒ sweep to edge.
 * Every client calls this to animate a shot identically without RTDB carrying the
 * whole point array.
 */
export function resampleArc({ originX, originY, dir, f, endX }) {
    const path = [];
    const limit = Math.ceil((WORLD.xMax - WORLD.xMin) / STEP) + 4;
    let x = originX;
    for (let i = 0; i < limit; i++) {
        if ((dir > 0 && x > WORLD.xMax) || (dir < 0 && x < WORLD.xMin)) break;
        const wy = originY + f(x - originX);
        if (Number.isFinite(wy) && Math.abs(wy) < MAX_ABS_Y) path.push([round3(x), round3(wy)]);
        if (endX != null && ((dir > 0 && x >= endX) || (dir < 0 && x <= endX))) break;
        x += dir * STEP;
    }
    return path;
}

/** Fire toward the nearest living opponent; default +1 if somehow none. */
export function aimDirection(origin, cannons, shooterSeat) {
    let bestX = null, bestD = Infinity;
    for (let c = 0; c < cannons.length; c++) {
        const cn = cannons[c];
        if (c === shooterSeat || !cn || !cn.alive) continue;
        const d = Math.hypot(cn.x - origin.x, cn.y - origin.y);
        if (d < bestD) { bestD = d; bestX = cn.x; }
    }
    if (bestX === null) return 1;
    return bestX >= origin.x ? 1 : -1;
}

/* ═══ Turn rotation + match helpers ═════════════════════════════════════════ */

/** Count occupied, still-living seats. */
export function aliveCount(players) {
    let n = 0;
    for (const p of players) if (p && p.alive) n++;
    return n;
}

/**
 * Next seat to move: scan (from+1)%4 .. skipping empty / eliminated seats.
 * `(from+4)%4 === from`, so a sole survivor returns its own seat; callers should
 * test `aliveCount === 1` for game-over first. Returns -1 if nobody can move.
 */
export function nextAliveSeat(players, fromSeat) {
    for (let k = 1; k <= MAX_SEATS; k++) {
        const j = (fromSeat + k) % MAX_SEATS;
        const p = players[j];
        if (p && p.alive) return j;
    }
    return -1;
}

/* ═══ Random battlefield generation (port of game.ts) ═══════════════════════ */

function rand(rng, min, max) {
    return min + rng() * (max - min);
}

/**
 * Random cannon positions for the occupied seats, spaced ≥ MIN_SEPARATION.
 * Returns an array indexed by seat 0..3 of { x, y } | null.
 */
export function placePlayers(occupiedSeats, rng = Math.random) {
    const positions = [null, null, null, null];
    const placed = [];
    for (const seat of occupiedSeats) {
        let pos, guard = 0;
        do {
            pos = {
                x: rand(rng, WORLD.xMin + 1.5, WORLD.xMax - 1.5),
                y: rand(rng, WORLD.yMin + 1.2, WORLD.yMax - 1.2),
            };
            guard++;
        } while (guard < 400 && placed.some((p) => Math.hypot(p.x - pos.x, p.y - pos.y) < MIN_SEPARATION));
        placed.push(pos);
        positions[seat] = pos;
    }
    return positions;
}

/** Random obstacles avoiding the cannons (port of game.ts:generateObstacles). */
export function generateObstacles(positions, rng = Math.random) {
    const pts = positions.filter(Boolean);
    const placed = [];
    const count = 3 + Math.floor(rng() * 4); // 3–6
    let guard = 0;
    while (placed.length < count && guard++ < 400) {
        const o = {
            x: rand(rng, -5.5, 5.5),
            y: rand(rng, WORLD.yMin + 1, WORLD.yMax - 1),
            r: rand(rng, 0.55, 1.35),
        };
        const nearPlayer = pts.some((p) => Math.hypot(p.x - o.x, p.y - o.y) < o.r + 2.2);
        const overlaps = placed.some((b) => Math.hypot(b.x - o.x, b.y - o.y) < b.r + o.r + 0.4);
        if (!nearPlayer && !overlaps) placed.push(o);
    }
    return placed;
}

/* ═══ ECS component vocabulary (used by the browser renderer system) ═════════ */

export const Position = defineComponent('Position');   // { x, y }
export const Cannon = defineComponent('Cannon');       // { seat, name, alive, isSelf, isTurn }
export const Obstacle = defineComponent('Obstacle');   // { radius }
export const Polyline = defineComponent('Polyline');   // { points: [[x,y], …] }
export const Stroke = defineComponent('Stroke');       // { color:[r,g,b,a], width }
export const Projectile = defineComponent('Projectile'); // { color, seat }
