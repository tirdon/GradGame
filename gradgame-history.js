// Match history panel. The game controller publishes `gradgame:history` events
// with fired expressions from every player; this file only owns presentation and
// restoring an expression to the input when a row is clicked.
(() => {
    const dock = document.getElementById('history-dock');
    const toggle = document.getElementById('history-toggle');
    const list = document.getElementById('history-list');
    const clearButton = document.getElementById('history-clear');
    const inputField = document.getElementById('expr-input');

    if (!dock || !toggle || !list) {
        return;
    }

    let entries = [];

    if (clearButton) {
        clearButton.hidden = true;
    }

    function setOpen(open) {
        dock.dataset.open = open ? 'true' : 'false';
        toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    }

    function setEntries(nextEntries) {
        entries = Array.isArray(nextEntries)
            ? nextEntries.map(normalizeEntry).filter(Boolean)
            : [];
        render();
    }

    function normalizeEntry(entry) {
        if (!entry || typeof entry.expr !== 'string' || !entry.expr.trim()) {
            return null;
        }

        const seat = Number(entry.by);
        if (!Number.isInteger(seat) || seat < 0 || seat > 3) {
            return null;
        }

        return {
            seq: Number(entry.seq) || 0,
            by: seat,
            name: String(entry.name || `Player ${seat + 1}`).slice(0, 24),
            color: validColor(entry.color) ? entry.color : '#6366f1',
            expr: entry.expr.trim(),
            tex: typeof entry.tex === 'string' ? entry.tex : '',
            ok: entry.ok !== false,
            outcome: typeof entry.outcome === 'string' ? entry.outcome : '',
            hitSeat: Number.isInteger(entry.hitSeat) ? entry.hitSeat : null,
        };
    }

    function validColor(color) {
        return typeof color === 'string' && /^#[0-9a-f]{6}$/i.test(color);
    }

    function restore(value) {
        if (!inputField) {
            return;
        }
        inputField.value = value;
        inputField.dispatchEvent(new Event('input', { bubbles: true }));
        inputField.focus();
        inputField.setSelectionRange(value.length, value.length);
    }

    function render() {
        list.textContent = '';

        if (!entries.length) {
            const empty = document.createElement('li');
            empty.className = 'history-empty';
            empty.textContent = 'No shots yet.';
            list.appendChild(empty);
            return;
        }

        for (const entry of entries) {
            const item = document.createElement('li');

            const button = document.createElement('button');
            button.type = 'button';
            button.className = 'history-item';
            button.title = entry.expr;
            button.style.setProperty('--history-player-color', entry.color);
            button.addEventListener('click', () => {
                restore(entry.expr);
                setOpen(false);
            });

            const meta = document.createElement('span');
            meta.className = 'history-item-meta';

            const dot = document.createElement('span');
            dot.className = 'history-player-dot';
            dot.setAttribute('aria-hidden', 'true');

            const name = document.createElement('span');
            name.className = 'history-player-name';
            name.textContent = entry.name;

            const outcome = document.createElement('span');
            outcome.className = 'history-item-outcome';
            outcome.textContent = outcomeLabel(entry);

            meta.append(dot, name, outcome);

            const tex = document.createElement('span');
            tex.className = 'history-item-tex';
            renderExpression(entry, tex);

            button.append(meta, tex);
            item.appendChild(button);
            list.appendChild(item);
        }

        list.scrollTop = list.scrollHeight;
    }

    function outcomeLabel(entry) {
        if (entry.outcome === 'hit' && entry.hitSeat != null) {
            return `hit P${entry.hitSeat + 1}`;
        }
        if (entry.outcome === 'blocked') {
            return 'blocked';
        }
        if (entry.outcome === 'out') {
            return 'out';
        }
        return `shot ${entry.seq}`;
    }

    function renderExpression(entry, target) {
        const tex = entry.ok && entry.tex ? entry.tex : '';
        if (tex && window.katex) {
            try {
                window.katex.render(tex, target, {
                    displayMode: false,
                    strict: 'ignore',
                    throwOnError: false,
                });
                return;
            } catch (error) {
                // Fall through to raw input if KaTeX cannot render this expression.
            }
        }
        target.textContent = entry.expr;
    }

    toggle.addEventListener('click', () => {
        setOpen(dock.dataset.open !== 'true');
    });

    document.addEventListener('gradgame:history', (event) => {
        setEntries(event.detail?.entries || []);
    });

    document.addEventListener('click', (event) => {
        if (dock.dataset.open === 'true' && !dock.contains(event.target)) {
            setOpen(false);
        }
    });

    document.addEventListener('keydown', (event) => {
        if (event.key === 'Escape' && dock.dataset.open === 'true') {
            setOpen(false);
        }
    });

    setOpen(false);
    render();
})();
