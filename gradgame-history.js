// History panel (bottom-trailing). Listens for `gradgame:commit` events fired by
// gradgame-wasm.js when an expression is committed (Enter), keeps a de-duplicated,
// most-recent-first list persisted to localStorage, renders each entry via KaTeX,
// and restores an expression to the input when its row is clicked.
(() => {
    const STORAGE_KEY = 'gradgame:history';
    const MAX_ENTRIES = 30;

    const dock = document.getElementById('history-dock');
    const toggle = document.getElementById('history-toggle');
    const list = document.getElementById('history-list');
    const clearButton = document.getElementById('history-clear');
    const inputField = document.getElementById('session-load');

    if (!dock || !toggle || !list) {
        return;
    }

    let entries = loadEntries();

    function loadEntries() {
        try {
            const raw = localStorage.getItem(STORAGE_KEY);
            if (!raw) {
                return [];
            }
            const parsed = JSON.parse(raw);
            if (!Array.isArray(parsed)) {
                return [];
            }
            return parsed
                .filter((entry) => entry && typeof entry.input === 'string')
                .slice(0, MAX_ENTRIES);
        } catch (error) {
            return [];
        }
    }

    function saveEntries() {
        try {
            localStorage.setItem(STORAGE_KEY, JSON.stringify(entries));
        } catch (error) {
            // Storage may be unavailable (private mode, quota); history is still
            // usable for the current session, so swallow the error.
        }
    }

    function setOpen(open) {
        dock.dataset.open = open ? 'true' : 'false';
        toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    }

    function record(detail) {
        const value = typeof detail.input === 'string' ? detail.input.trim() : '';
        if (!value) {
            return;
        }

        // Drop any earlier identical entry, then prepend so the newest is on top.
        entries = entries.filter((entry) => entry.input !== value);
        entries.unshift({
            input: value,
            tex: detail.ok ? detail.tex : '',
            ok: Boolean(detail.ok),
        });
        if (entries.length > MAX_ENTRIES) {
            entries.length = MAX_ENTRIES;
        }

        saveEntries();
        render();
    }

    function restore(value) {
        if (!inputField) {
            return;
        }
        inputField.value = value;
        // Trigger the same debounced re-render path as typing.
        inputField.dispatchEvent(new Event('input', { bubbles: true }));
        inputField.focus();
        inputField.setSelectionRange(value.length, value.length);
    }

    function render() {
        list.textContent = '';

        if (!entries.length) {
            const empty = document.createElement('li');
            empty.className = 'history-empty';
            empty.textContent = 'No expressions yet.';
            list.appendChild(empty);
            return;
        }

        // Render oldest-first (inverse of the newest-first storage order), so the
        // most recent commit lands at the bottom, nearest the input.
        for (let i = entries.length - 1; i >= 0; i -= 1) {
            const entry = entries[i];
            const item = document.createElement('li');

            const button = document.createElement('button');
            button.type = 'button';
            button.className = 'history-item';
            button.title = entry.input;
            button.addEventListener('click', () => {
                restore(entry.input);
                setOpen(false);
            });

            const tex = document.createElement('span');
            tex.className = 'history-item-tex';
            if (entry.ok && entry.tex && window.katex) {
                try {
                    window.katex.render(entry.tex, tex, {
                        displayMode: false,
                        strict: 'ignore',
                        throwOnError: false,
                    });
                } catch (error) {
                    tex.textContent = entry.input;
                }
            } else {
                tex.textContent = entry.input;
            }

            button.appendChild(tex);
            item.appendChild(button);
            list.appendChild(item);
        }

        // Pin to the newest entry at the bottom.
        list.scrollTop = list.scrollHeight;
    }

    toggle.addEventListener('click', () => {
        setOpen(dock.dataset.open !== 'true');
    });

    clearButton?.addEventListener('click', () => {
        entries = [];
        saveEntries();
        render();
    });

    document.addEventListener('gradgame:commit', (event) => {
        record(event.detail || {});
    });

    // Dismiss when clicking outside the dock or pressing Escape.
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
