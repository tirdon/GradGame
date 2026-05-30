(async () => {
    const wasmPath = 'GradGame.wasm';
    const result = document.getElementById('wasm-add-result');
    const expressionInput = document.getElementById('session-load');
    const texResult = document.getElementById('tex-parser-result');
    const jsResult = document.getElementById('js-parser-result');
    const evalX = document.getElementById('eval-x');
    const evalY = document.getElementById('eval-y');
    const evalResult = document.getElementById('js-eval-result');
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();
    let wasmExports = null;
    let wasmModule = null;
    let recovering = null;
    let renderTimer = null;

    // Thrown when a Wasm call traps (e.g. a stack overflow while parsing or
    // simplifying a deeply nested expression). A trap leaves the instance
    // unusable, so the caller must surface a message and re-instantiate.
    class WasmTrapError extends Error {
        constructor(cause) {
            super('Expression too complex.');
            this.name = 'WasmTrapError';
            this.cause = cause;
        }
    }

    function writeUint32(memory, pointer, value) {
        new DataView(memory.buffer).setUint32(pointer, value, true);
    }

    function memoryBytes() {
        return new Uint8Array(wasmExports.memory.buffer);
    }

    function decodeWasmString(pointer, length) {
        if (!pointer || length <= 0) {
            return '';
        }

        return decoder.decode(memoryBytes().subarray(pointer, pointer + length));
    }

    function parseExpression(input, exportName, simplify = false) {
        const bytes = encoder.encode(input);
        let inputPointer = 0;

        if (bytes.length > 0) {
            inputPointer = wasmExports.gradGameAllocate(bytes.length);
            if (!inputPointer) {
                throw new Error('Unable to allocate Wasm input memory.');
            }
            memoryBytes().set(bytes, inputPointer);
        }

        let outputPointer;
        try {
            outputPointer = wasmExports[exportName](inputPointer, bytes.length, simplify ? 1 : 0);
        } catch (error) {
            // The instance is now poisoned; its leaked input allocation is reclaimed
            // when the instance is replaced, so there is nothing safe to free here.
            throw new WasmTrapError(error);
        }
        const outputLength = wasmExports.gradGameLastResultLength();
        const ok = wasmExports.gradGameLastParseSucceeded() === 1;
        const text = decodeWasmString(outputPointer, outputLength);

        if (inputPointer) {
            wasmExports.gradGameDeallocate(inputPointer, bytes.length);
        }
        wasmExports.gradGameFreeLastResult();

        return { ok, text };
    }

    function parseToTeX(input) {
        return parseExpression(input, 'parseExpressionToTex', true);
    }

    function parseToJavaScript(input) {
        return parseExpression(input, 'parseExpressionToJavaScript');
    }

    function setOutput(output, text, status) {
        if (!output) {
            return;
        }

        output.dataset.status = status;
        output.textContent = text;
        output.setAttribute('aria-label', text);
        if (output === jsResult) {
            delete output.dataset.js;
        }
        if (output === evalResult) {
            delete output.dataset.value;
        }
    }

    function setTexOutput(text, status, renderMath) {
        if (!texResult) {
            return;
        }

        texResult.dataset.status = status;
        texResult.dataset.tex = text;
        texResult.setAttribute('aria-label', text);

        if (renderMath && window.katex) {
            try {
                window.katex.render(text, texResult, {
                    displayMode: false,
                    strict: 'ignore',
                    throwOnError: false,
                });
                return;
            } catch (error) {
                console.error(error);
            }
        }

        texResult.textContent = text;
    }

    function evaluateJavaScriptExpression(expression) {
        const x = Number(evalX?.value ?? 0);
        const y = Number(evalY?.value ?? 0);

        if (Number.isNaN(x) || Number.isNaN(y)) {
            return 'NaN';
        }

        const value = Function('x', 'y', `"use strict"; return (${expression});`)(x, y);
        if (typeof value !== 'number') {
            return 'NaN';
        }

        if (Number.isNaN(value)) {
            return 'NaN';
        }

        if (Object.is(value, -0)) {
            return '0';
        }

        return String(value);
    }

    function renderExpression() {
        if (!wasmExports || !texResult || !expressionInput) {
            return;
        }

        const input = expressionInput.value.trim();
        if (!input) {
            setTexOutput('Enter an expression.', 'idle', false);
            setOutput(jsResult, 'Enter an expression.', 'idle');
            setOutput(evalResult, 'NaN', 'idle');
            return;
        }

        try {
            const tex = parseToTeX(input);
            setTexOutput(tex.text, tex.ok ? 'pass' : 'fail', tex.ok);

            if (!tex.ok) {
                setOutput(jsResult, tex.text, 'fail');
                setOutput(evalResult, 'NaN', 'fail');
                return;
            }

            // The JS-eval pipeline below is optional; skip it when its UI is absent.
            if (!jsResult) {
                return;
            }

            const js = parseToJavaScript(input);
            setOutput(jsResult, js.text, js.ok ? 'pass' : 'fail');
            jsResult.dataset.js = js.text;

            if (!js.ok) {
                setOutput(evalResult, 'NaN', 'fail');
                return;
            }

            const value = evaluateJavaScriptExpression(js.text);
            setOutput(evalResult, value, 'pass');
            if (evalResult) { evalResult.dataset.value = value; }
        } catch (error) {
            // WasmTrapError carries the user-facing 'Expression too complex.' message.
            setTexOutput(error.message, 'fail', false);
            setOutput(jsResult, error.message, 'fail');
            setOutput(evalResult, 'NaN', 'fail');
            console.error(error);
            if (error instanceof WasmTrapError) {
                // The instance is dead. Replace it so the next keystroke works again.
                // Do not re-render here: the offending input is still on screen, and
                // re-parsing it would just trap and recover in a tight loop.
                recoverWasm();
            }
        }
    }

    // Debounced entry point for input events: a long expression should not be
    // re-parsed on every keystroke, which is both wasteful and the surest way to
    // overflow the Wasm stack repeatedly.
    function scheduleRender() {
        if (renderTimer) {
            clearTimeout(renderTimer);
        }
        renderTimer = setTimeout(() => {
            renderTimer = null;
            renderExpression();
        }, 120);
    }

    function logJavaScriptParse() {
        if (!wasmExports || !expressionInput) {
            return;
        }

        const input = expressionInput.value.trim();
        if (!input) {
            console.log('');
            return;
        }

        try {
            const js = parseToJavaScript(input);
            console.log(js.text);
        } catch (error) {
            console.error(error);
            if (error instanceof WasmTrapError) {
                recoverWasm();
            }
        }
    }

    // Records the current expression into the history panel. Fired on Enter (an
    // explicit "commit" gesture) so history holds finished expressions, not every
    // intermediate keystroke. Decoupled via a DOM event so gradgame-history.js owns
    // the panel without reaching into this module's parse pipeline.
    function commitToHistory() {
        if (!wasmExports || !expressionInput) {
            return;
        }

        const input = expressionInput.value.trim();
        if (!input) {
            return;
        }

        try {
            const tex = parseToTeX(input);
            document.dispatchEvent(new CustomEvent('gradgame:commit', {
                detail: { input, tex: tex.text, ok: tex.ok },
            }));
        } catch (error) {
            console.error(error);
            if (error instanceof WasmTrapError) {
                recoverWasm();
            }
        }
    }

    async function instantiate() {
        const imports = { wasi_snapshot_preview1: wasiSnapshotPreview1 };
        const instance = await WebAssembly.instantiate(wasmModule, imports);
        wasmExports = instance.exports;
        window.gradGameWasm = wasmExports;
    }

    // Drops the poisoned instance immediately (so renderExpression short-circuits
    // on its `!wasmExports` guard instead of calling into a dead module) and builds
    // a fresh one from the already-compiled module. Guarded so overlapping traps
    // share a single re-instantiation.
    function recoverWasm() {
        wasmExports = null;
        if (recovering || !wasmModule) {
            return;
        }
        recovering = instantiate()
            .catch((error) => {
                console.error('Wasm recovery failed:', error);
            })
            .finally(() => {
                recovering = null;
            });
    }

    const wasiSnapshotPreview1 = {
        args_get: () => 0,
        args_sizes_get: (argc, argvBufSize) => {
            if (!wasmExports?.memory) return 0;
            writeUint32(wasmExports.memory, argc, 0);
            writeUint32(wasmExports.memory, argvBufSize, 0);
            return 0;
        },
        environ_get: () => 0,
        environ_sizes_get: (count, bufSize) => {
            if (!wasmExports?.memory) return 0;
            writeUint32(wasmExports.memory, count, 0);
            writeUint32(wasmExports.memory, bufSize, 0);
            return 0;
        },
        fd_close: () => 0,
        fd_fdstat_get: () => 0,
        fd_prestat_get: () => 8,
        fd_prestat_dir_name: () => 8,
        fd_read: () => 0,
        fd_seek: () => 0,
        fd_write: () => 0,
        path_open: () => 8,
        proc_exit: (code) => {
            throw new Error(`WASI proc_exit(${code})`);
        },
        random_get: (buffer, length) => {
            if (!wasmExports?.memory) return 0;
            crypto.getRandomValues(new Uint8Array(wasmExports.memory.buffer, buffer, length));
            return 0;
        },
    };

    try {
        const response = await fetch(wasmPath);
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}`);
        }

        const imports = { wasi_snapshot_preview1: wasiSnapshotPreview1 };
        const responseCopy = response.clone();
        const { module, instance } = await WebAssembly.instantiateStreaming(response, imports).catch(
            async () => WebAssembly.instantiate(await responseCopy.arrayBuffer(), imports)
        );

        // Keep the compiled module so a trapped instance can be cheaply rebuilt.
        wasmModule = module;
        wasmExports = instance.exports;
        window.gradGameWasm = wasmExports;

        // Expose a synchronous parse API for the game (fire-on-demand, so it does
        // not depend on the debounced data-js attribute). The closures read the
        // live `wasmExports`, so they keep working across trap recovery.
        window.gradGameParse = {
            toJavaScript: parseToJavaScript,
            toTeX: parseToTeX,
        };

        const value = wasmExports.add(2, 3);
        if (result) {
            result.textContent = `Swift add(2, 3) = ${value}`;
            result.dataset.status = value === 5 ? 'pass' : 'fail';
        }

        expressionInput?.addEventListener('input', scheduleRender);
        expressionInput?.addEventListener('keydown', (event) => {
            if (event.key === 'Enter') {
                logJavaScriptParse();
                commitToHistory();
            }
        });
        evalX?.addEventListener('input', scheduleRender);
        evalY?.addEventListener('input', scheduleRender);
        renderExpression();
    } catch (error) {
        if (result) {
            result.textContent = `Swift Wasm test failed: ${error.message}`;
            result.dataset.status = 'fail';
        }
        if (texResult) {
            setTexOutput('Parser unavailable.', 'fail', false);
        }
        setOutput(jsResult, 'Parser unavailable.', 'fail');
        setOutput(evalResult, 'NaN', 'fail');
        console.error(error);
    }
})();
