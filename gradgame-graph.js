/**
 * gradgame-graph.js
 * ──────────────────────────────────────────────────────────────────────────
 * WebGPU-accelerated function graph renderer for GradGame.
 *
 * Flow:
 *   1. The Wasm parser converts the user's expression → JavaScript string.
 *   2. This module evaluates the JS string with `Function()` for each sample
 *      across the viewport x-range, producing a Float32Array of y-values.
 *   3. The y-values are uploaded to a GPU storage buffer.
 *   4. Two render passes draw on the <canvas>:
 *        • Grid pass  — axes + grid lines (fullscreen quad)
 *        • Curve pass — thick anti-aliased line segments
 *
 * All WGSL shaders live in `graph.wgsl` (fetched once at init).
 * ──────────────────────────────────────────────────────────────────────────
 */
(() => {
    'use strict';

    /* ── Configuration ──────────────────────────────────────────────────── */
    const SAMPLE_COUNT   = 2048;
    const CURVE_THICKNESS = 2.5;           // half-width in CSS px
    const WGSL_PATH      = 'graph.wgsl';

    /* ── DOM refs ───────────────────────────────────────────────────────── */
    const host = document.querySelector('.canvas-frame');
    if (!host) return;

    /* Create a dedicated WebGPU canvas layered above the existing 2D canvas */
    const canvas = document.createElement('canvas');
    canvas.id = 'canvas-graph';
    canvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;display:block;z-index:1;';
    host.appendChild(canvas);

    /* ── State ──────────────────────────────────────────────────────────── */
    let device, context, format, shaderModule;
    let gridPipeline, curvePipeline, computePipeline;
    let uniformBuffer, sampleBuffer, flagsBuffer;
    let gridBindGroup, curveBindGroup, computeFlagsBindGroup;
    let animId = null;
    let startTime = performance.now() / 1000;
    let currentExprJS = null;      // last successfully compiled JS string
    let compiledFn    = null;      // cached Function object

    /* Viewport (math coords) */
    let viewXMin = -10, viewXMax = 10;
    let viewYMin = -6,  viewYMax = 6;

    /* ── TEST OVERLAY: coordinate-space slider (remove this block later) ── */
    const _overlay = document.createElement('div');
    _overlay.id = 'graph-debug-overlay';
    _overlay.style.cssText = `
        position:absolute; bottom:0.75rem; right:0.75rem; z-index:10;
        display:flex; align-items:center; gap:0.5rem;
        padding:0.4rem 0.75rem;
        border-radius:999px;
        background:rgba(15,23,42,0.72);
        backdrop-filter:blur(10px); -webkit-backdrop-filter:blur(10px);
        color:#e2e8f0; font:700 0.75rem/1 ui-monospace,SFMono-Regular,monospace;
        user-select:none; pointer-events:auto;
    `;
    const _label = document.createElement('span');
    _label.textContent = '±10';
    const _slider = document.createElement('input');
    _slider.type = 'range';
    _slider.min = '1';
    _slider.max = '100';
    _slider.value = '10';
    _slider.style.cssText = 'width:6rem; accent-color:#60a5fa; cursor:pointer;';
    _slider.addEventListener('input', () => {
        const half = Number(_slider.value);
        const aspect = (host.clientWidth || 1) / (host.clientHeight || 1);
        viewXMin = -half;
        viewXMax =  half;
        viewYMin = -half / aspect;
        viewYMax =  half / aspect;
        _label.textContent = `±${half}`;
    });
    _overlay.append(_label, _slider);
    host.appendChild(_overlay);
    /* ── END TEST OVERLAY ─────────────────────────────────────────────── */

    /* Pan / zoom state */
    let isPanning = false;
    let panStartMouse = { x: 0, y: 0 };
    let panStartView  = { xMin: 0, xMax: 0, yMin: 0, yMax: 0 };

    /* ══════════════════════════════════════════════════════════════════════
       Init
       ══════════════════════════════════════════════════════════════════════ */

    async function init() {
        if (!navigator.gpu) {
            console.warn('WebGPU not supported – graph disabled.');
            return;
        }

        const adapter = await navigator.gpu.requestAdapter();
        if (!adapter) {
            console.warn('No WebGPU adapter – graph disabled.');
            return;
        }

        device = await adapter.requestDevice();

        window.webgpuGraphActive = true;

        context = canvas.getContext('webgpu');
        format  = navigator.gpu.getPreferredCanvasFormat();
        context.configure({ device, format, alphaMode: 'premultiplied' });

        /* Fetch WGSL shader source */
        const wgslResp = await fetch(WGSL_PATH);
        if (!wgslResp.ok) throw new Error(`Failed to load ${WGSL_PATH}`);
        const wgslCode = await wgslResp.text();
        shaderModule = device.createShaderModule({ code: wgslCode });

        createBuffers();
        createPipelines();
        attachInputListeners();
        attachPointerListeners();
        resizeCanvas();
        tick();
    }

    /* ── Buffers ────────────────────────────────────────────────────────── */

    function createBuffers() {
        // Uniforms: 10 × f32 = 40 bytes, padded to 48 for 16-byte alignment
        uniformBuffer = device.createBuffer({
            size: 48,
            usage: GPUBufferUsage.UNIFORM | GPUBufferUsage.COPY_DST,
        });

        // Sample buffer: SAMPLE_COUNT × f32
        sampleBuffer = device.createBuffer({
            size: SAMPLE_COUNT * 4,
            usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
        });

        // C¹ flags buffer: SAMPLE_COUNT × u32 (written by compute, read by curve)
        flagsBuffer = device.createBuffer({
            size: SAMPLE_COUNT * 4,
            usage: GPUBufferUsage.STORAGE,
        });
    }

    /* ── Pipelines ──────────────────────────────────────────────────────── */

    function createPipelines() {
        /* ── Bind group layouts ─────────────────────────────────────── */

        // Grid / compute group 0: uniform + samples
        const baseLayout = device.createBindGroupLayout({
            entries: [
                { binding: 0, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT | GPUShaderStage.COMPUTE,
                  buffer: { type: 'uniform' } },
                { binding: 1, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT | GPUShaderStage.COMPUTE,
                  buffer: { type: 'read-only-storage' } },
            ],
        });

        // Compute group 1: flags (read-write storage)
        const computeFlagsLayout = device.createBindGroupLayout({
            entries: [
                { binding: 0, visibility: GPUShaderStage.COMPUTE,
                  buffer: { type: 'storage' } },
            ],
        });

        // Curve group 0: uniform + samples + flags (read-only)
        const curveLayout = device.createBindGroupLayout({
            entries: [
                { binding: 0, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
                  buffer: { type: 'uniform' } },
                { binding: 1, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT,
                  buffer: { type: 'read-only-storage' } },
                { binding: 2, visibility: GPUShaderStage.VERTEX,
                  buffer: { type: 'read-only-storage' } },
            ],
        });

        /* ── Pipeline layouts ───────────────────────────────────────── */
        const gridPipelineLayout = device.createPipelineLayout({
            bindGroupLayouts: [baseLayout],
        });
        const computePipelineLayout = device.createPipelineLayout({
            bindGroupLayouts: [baseLayout, computeFlagsLayout],
        });
        const curvePipelineLayout = device.createPipelineLayout({
            bindGroupLayouts: [curveLayout],
        });

        /* ── Blend state ────────────────────────────────────────────── */
        const blendPremul = {
            color: { srcFactor: 'src-alpha', dstFactor: 'one-minus-src-alpha', operation: 'add' },
            alpha: { srcFactor: 'one',       dstFactor: 'one-minus-src-alpha', operation: 'add' },
        };

        /* ── Pipelines ──────────────────────────────────────────────── */
        gridPipeline = device.createRenderPipeline({
            layout: gridPipelineLayout,
            vertex:   { module: shaderModule, entryPoint: 'gridVS' },
            fragment: { module: shaderModule, entryPoint: 'gridFS',
                        targets: [{ format, blend: blendPremul }] },
            primitive: { topology: 'triangle-strip' },
        });

        computePipeline = device.createComputePipeline({
            layout: computePipelineLayout,
            compute: { module: shaderModule, entryPoint: 'checkC1' },
        });

        curvePipeline = device.createRenderPipeline({
            layout: curvePipelineLayout,
            vertex:   { module: shaderModule, entryPoint: 'curveVS' },
            fragment: { module: shaderModule, entryPoint: 'curveFS',
                        targets: [{ format, blend: blendPremul }] },
            primitive: { topology: 'triangle-list' },
        });

        /* ── Bind groups ────────────────────────────────────────────── */
        gridBindGroup = device.createBindGroup({
            layout: baseLayout,
            entries: [
                { binding: 0, resource: { buffer: uniformBuffer } },
                { binding: 1, resource: { buffer: sampleBuffer  } },
            ],
        });

        computeFlagsBindGroup = device.createBindGroup({
            layout: computeFlagsLayout,
            entries: [
                { binding: 0, resource: { buffer: flagsBuffer } },
            ],
        });

        curveBindGroup = device.createBindGroup({
            layout: curveLayout,
            entries: [
                { binding: 0, resource: { buffer: uniformBuffer } },
                { binding: 1, resource: { buffer: sampleBuffer  } },
                { binding: 2, resource: { buffer: flagsBuffer   } },
            ],
        });
    }

    /* ── Sampling ───────────────────────────────────────────────────────── */

    /**
     * Re-compile the JS expression string into a reusable Function and
     * evaluate it across the current x-range.
     */
    function sampleExpression() {
        const data = new Float32Array(SAMPLE_COUNT);

        if (!compiledFn) {
            data.fill(NaN);
            device.queue.writeBuffer(sampleBuffer, 0, data);
            return;
        }

        const dx = (viewXMax - viewXMin) / (SAMPLE_COUNT - 1);
        for (let i = 0; i < SAMPLE_COUNT; i++) {
            const x = viewXMin + i * dx;
            try {
                const v = compiledFn(x, 0);
                data[i] = typeof v === 'number' ? v : NaN;
            } catch {
                data[i] = NaN;
            }
        }

        device.queue.writeBuffer(sampleBuffer, 0, data);
    }

    /**
     * Called when the parsed JS expression changes.
     */
    function setExpression(jsExpr) {
        if (jsExpr === currentExprJS) return;
        currentExprJS = jsExpr;

        if (!jsExpr) {
            compiledFn = null;
            return;
        }

        try {
            compiledFn = new Function(
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
                 return (${jsExpr});`
            );
        } catch {
            compiledFn = null;
        }
    }

    /* ── Rendering ──────────────────────────────────────────────────────── */

    function resizeCanvas() {
        const rect  = host.getBoundingClientRect();
        const dpr   = window.devicePixelRatio || 1;
        const w     = Math.max(1, Math.round(rect.width  * dpr));
        const h     = Math.max(1, Math.round(rect.height * dpr));
        if (canvas.width !== w || canvas.height !== h) {
            canvas.width  = w;
            canvas.height = h;
        }
    }

    function writeUniforms() {
        const dpr = window.devicePixelRatio || 1;
        const buf = new Float32Array([
            canvas.width,  canvas.height,
            viewXMin,      viewXMax,
            viewYMin,      viewYMax,
            SAMPLE_COUNT,  CURVE_THICKNESS * dpr,
            (performance.now() / 1000) - startTime,
            0,  // pad
        ]);
        device.queue.writeBuffer(uniformBuffer, 0, buf);
    }

    function render() {
        resizeCanvas();
        writeUniforms();
        sampleExpression();

        const tex = context.getCurrentTexture();
        const encoder = device.createCommandEncoder();

        /* Compute pass — C¹ continuity check */
        if (compiledFn) {
            const cp = encoder.beginComputePass();
            cp.setPipeline(computePipeline);
            cp.setBindGroup(0, gridBindGroup);          // uniform + samples
            cp.setBindGroup(1, computeFlagsBindGroup);  // flags (rw)
            cp.dispatchWorkgroups(Math.ceil(SAMPLE_COUNT / 64));
            cp.end();
        }

        const pass = encoder.beginRenderPass({
            colorAttachments: [{
                view: tex.createView(),
                loadOp:  'clear',
                storeOp: 'store',
                clearValue: { r: 0, g: 0, b: 0, a: 0 },
            }],
        });

        /* Grid */
        pass.setPipeline(gridPipeline);
        pass.setBindGroup(0, gridBindGroup);
        pass.draw(4);   // fullscreen quad (triangle-strip)

        /* Curve */
        if (compiledFn) {
            pass.setPipeline(curvePipeline);
            pass.setBindGroup(0, curveBindGroup);
            // 6 verts per segment, (SAMPLE_COUNT-1) segments
            pass.draw((SAMPLE_COUNT - 1) * 6);
        }

        pass.end();
        device.queue.submit([encoder.finish()]);
    }

    function tick() {
        render();
        animId = requestAnimationFrame(tick);
    }

    /* ── Expression input integration ───────────────────────────────────── */

    function attachInputListeners() {
        // Watch the expression input. Re-parse on every input event.
        // The Wasm module (gradgame-wasm.js) stores parsed JS in a data
        // attribute; we read it after a short delay.
        const input = document.getElementById('session-load');
        if (!input) return;

        const poll = () => {
            const jsResultEl = document.getElementById('js-parser-result');
            const jsExpr = jsResultEl?.dataset?.js ?? null;
            setExpression(jsExpr);
        };

        input.addEventListener('input', () => {
            // Wait a tick so the Wasm module finishes writing data-js
            setTimeout(poll, 180);
        });

        // If the input already has a value (e.g. restored from history)
        setTimeout(poll, 400);

        // Also observe changes via MutationObserver on the JS result element
        const observer = new MutationObserver(poll);
        const jsResultEl = document.getElementById('js-parser-result');
        if (jsResultEl) {
            observer.observe(jsResultEl, { attributes: true, attributeFilter: ['data-js'] });
        }
    }

    /* ── Pointer-based pan & scroll-wheel zoom ──────────────────────────── */

    function attachPointerListeners() {
        canvas.style.pointerEvents = 'auto';
        canvas.style.touchAction   = 'none';

        canvas.addEventListener('pointerdown', (e) => {
            if (e.button !== 0) return;
            isPanning = true;
            panStartMouse = { x: e.clientX, y: e.clientY };
            panStartView  = { xMin: viewXMin, xMax: viewXMax, yMin: viewYMin, yMax: viewYMax };
            canvas.setPointerCapture(e.pointerId);
        });

        canvas.addEventListener('pointermove', (e) => {
            if (!isPanning) return;
            const rect = canvas.getBoundingClientRect();
            const dxPx = e.clientX - panStartMouse.x;
            const dyPx = e.clientY - panStartMouse.y;

            const xRange = panStartView.xMax - panStartView.xMin;
            const yRange = panStartView.yMax - panStartView.yMin;

            const dxMath = -(dxPx / rect.width)  * xRange;
            const dyMath =  (dyPx / rect.height) * yRange;

            viewXMin = panStartView.xMin + dxMath;
            viewXMax = panStartView.xMax + dxMath;
            viewYMin = panStartView.yMin + dyMath;
            viewYMax = panStartView.yMax + dyMath;
        });

        canvas.addEventListener('pointerup',     () => { isPanning = false; });
        canvas.addEventListener('pointercancel', () => { isPanning = false; });
        canvas.addEventListener('lostpointercapture', () => { isPanning = false; });

        canvas.addEventListener('wheel', (e) => {
            e.preventDefault();

            const rect = canvas.getBoundingClientRect();
            const mx   = (e.clientX - rect.left) / rect.width;
            const my   = 1 - (e.clientY - rect.top) / rect.height;

            const factor = e.deltaY > 0 ? 1.12 : 1 / 1.12;

            const xRange = viewXMax - viewXMin;
            const yRange = viewYMax - viewYMin;
            const cx     = viewXMin + mx * xRange;
            const cy     = viewYMin + my * yRange;

            viewXMin = cx - (cx - viewXMin) * factor;
            viewXMax = cx + (viewXMax - cx) * factor;
            viewYMin = cy - (cy - viewYMin) * factor;
            viewYMax = cy + (viewYMax - cy) * factor;
        }, { passive: false });
    }

    /* ── Resize observer ────────────────────────────────────────────────── */
    new ResizeObserver(() => resizeCanvas()).observe(host);

    /* ── Kick off ───────────────────────────────────────────────────────── */
    init().catch((err) => {
        console.error('WebGPU graph init failed:', err);
    });
})();
