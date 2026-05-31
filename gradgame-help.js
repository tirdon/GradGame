(() => {
    const overlay = document.getElementById('help-overlay');
    const toggleBtn = document.getElementById('help-toggle');
    const closeBtn = document.getElementById('help-close');
    const body = document.getElementById('help-body');

    let contentLoaded = false;
    let isOpen = false;

    /* ── Parsers ─────────────────────────────────────────── */

    function parseOperations(text) {
        const blocks = [];
        let inCode = false;
        let codeItems = [];

        for (const raw of text.split('\n')) {
            const line = raw.trim();

            if (line === '```') {
                if (inCode && codeItems.length > 0) {
                    blocks.push({ type: 'ops', items: codeItems });
                    codeItems = [];
                }
                inCode = !inCode;
                continue;
            }

            if (line) {
                if (inCode) {
                    codeItems.push(line);
                } else {
                    blocks.push({ type: 'label', text: line });
                }
            }
        }

        return blocks;
    }

    function parseExamples(text) {
        return text
            .split('\n')
            .map((l) => l.trim())
            .filter(Boolean)
            .map((line) => {
                const idx = line.indexOf(' = ');
                if (idx === -1) return null;
                return { input: line.substring(0, idx), tex: line.substring(idx + 3) };
            })
            .filter(Boolean);
    }

    /* ── Helpers ──────────────────────────────────────────── */

    function esc(s) {
        return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    function escAttr(s) {
        return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }

    /* ── Renderers ───────────────────────────────────────── */

    function mergeBlocks(blocks) {
        const groups = [];
        let i = 0;

        while (i < blocks.length) {
            const labels = [];
            while (i < blocks.length && blocks[i].type === 'label') {
                labels.push(blocks[i].text);
                i++;
            }

            const ops = [];
            while (i < blocks.length && blocks[i].type === 'ops') {
                ops.push(...blocks[i].items);
                i++;
            }

            if (labels.length > 0 || ops.length > 0) {
                groups.push({ labels, ops });
            }
        }

        return groups;
    }

    function renderContent(opsRaw, examplesRaw) {
        const blocks = parseOperations(opsRaw);
        const groups = mergeBlocks(blocks);
        const examples = parseExamples(examplesRaw);

        let html = '';

        /* Supported Operations */
        html += '<section class="help-section">';
        html += '<h3>Supported Operations</h3>';
        html += '<div class="help-form">';

        groups.forEach((g) => {
            html += '<div class="help-form-group">';

            if (g.labels.length > 0) {
                html += `<div class="help-form-label">${g.labels.map((l) => esc(l)).join(', ')}</div>`;
            }

            if (g.ops.length > 0) {
                html += '<div class="help-form-items">';
                html += g.ops.map((o) => `<code>${esc(o)}</code>`).join('');
                html += '</div>';
            }

            html += '</div>';
        });

        html += '</div></section>';

        /* Input Examples */
        html += '<section class="help-section">';
        html += '<h3>Input Examples</h3>';
        html += '<div class="help-examples">';

        examples.forEach((ex) => {
            html += `<div class="help-example-row" data-input="${escAttr(ex.input)}">`;
            html += `<span class="help-example-input"><code>${esc(ex.input)}</code></span>`;
            html += '<span class="help-example-arrow">↦</span>';
            html += `<span class="help-example-tex" data-tex="${escAttr(ex.tex)}"></span>`;
            html += '</div>';
        });

        html += '</div></section>';

        body.innerHTML = html;

        /* Render KaTeX inside example rows */
        if (window.katex) {
            body.querySelectorAll('.help-example-tex[data-tex]').forEach((el) => {
                try {
                    katex.render(el.dataset.tex, el, {
                        displayMode: false,
                        strict: 'ignore',
                        throwOnError: false,
                    });
                } catch (_) {
                    el.textContent = el.dataset.tex;
                }
            });
        }

        /* Click an example to populate input */
        body.querySelectorAll('.help-example-row[data-input]').forEach((row) => {
            row.addEventListener('click', () => {
                const input = document.getElementById('expr-input');
                if (input) {
                    input.value = row.dataset.input;
                    input.dispatchEvent(new Event('input'));
                }
                closePopup();
            });
        });
    }

    /* ── Fetch & Cache ───────────────────────────────────── */

    async function loadContent() {
        if (contentLoaded) return;

        try {
            const [opsRes, exRes] = await Promise.all([
                fetch('SupportedOperation.txt'),
                fetch('InputExamples.txt'),
            ]);

            if (!opsRes.ok || !exRes.ok) throw new Error('Failed to load help files.');

            const [opsText, exText] = await Promise.all([opsRes.text(), exRes.text()]);

            renderContent(opsText, exText);
            contentLoaded = true;
        } catch (e) {
            body.innerHTML = '<p class="help-error">Unable to load help content.</p>';
            console.error(e);
        }
    }

    /* ── Open / Close ────────────────────────────────────── */

    function openPopup() {
        if (isOpen) return;
        isOpen = true;
        overlay.hidden = false;
        /* Force reflow so the browser registers the hidden→visible change before adding class */
        void overlay.offsetHeight;
        overlay.classList.remove('closing');
        overlay.classList.add('open');
        loadContent();
        document.body.style.overflow = 'hidden';
        closeBtn?.focus();
    }

    function closePopup() {
        if (!isOpen) return;
        isOpen = false;
        overlay.classList.remove('open');
        overlay.classList.add('closing');
        document.body.style.overflow = '';

        const cleanup = () => {
            overlay.hidden = true;
            overlay.classList.remove('closing');
        };

        overlay.addEventListener(
            'animationend',
            function handler(e) {
                if (e.target !== overlay) return;
                overlay.removeEventListener('animationend', handler);
                cleanup();
            }
        );

        /* Fallback in case animationend doesn't fire */
        setTimeout(cleanup, 400);
    }

    /* ── Bindings ─────────────────────────────────────────── */

    toggleBtn?.addEventListener('click', openPopup);
    closeBtn?.addEventListener('click', closePopup);

    overlay?.addEventListener('click', (e) => {
        if (e.target === overlay) closePopup();
    });

    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && isOpen) closePopup();
    });
})();
