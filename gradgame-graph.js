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

    /* GradGame battlefield extents (must match BunServer/constants.ts WORLD). */
    const WORLD          = { xMin: -12, xMax: 12, yMin: -6.75, yMax: 6.75 };
    const VIEW_MARGIN    = 1.08;           // show a little past the world edges
    const CAP_ENTITIES   = 128;            // max instanced discs per frame
    const CAP_PATH_VERTS = 8192;           // max concatenated polyline vertices

    /* ── DOM refs ───────────────────────────────────────────────────────── */
    const host = document.querySelector('.canvas-frame');
    if (!host) return;

    /* Create a dedicated WebGPU canvas layered above the existing 2D canvas */
    const canvas = document.createElement('canvas');
    canvas.id = 'canvas-graph';
    canvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;display:block;z-index:1;';
    host.appendChild(canvas);

    /* A 2D overlay canvas for the f(x,y) plots (level-set contour + −∇f vector
       field). It sits above the WebGPU curve and shares the same viewport.
       pointer-events:none lets pan/zoom fall through to the WebGPU canvas. */
    const fieldCanvas = document.createElement('canvas');
    fieldCanvas.id = 'canvas-field';
    fieldCanvas.style.cssText = 'position:absolute;inset:0;width:100%;height:100%;display:block;z-index:2;pointer-events:none;';
    host.appendChild(fieldCanvas);
    const fieldCtx = fieldCanvas.getContext('2d');

    /* ── State ──────────────────────────────────────────────────────────── */
    let device, context, format, shaderModule;
    let gridPipeline, curvePipeline, computePipeline;
    let uniformBuffer, sampleBuffer, flagsBuffer;
    let gridBindGroup, curveBindGroup, computeFlagsBindGroup;

    /* ── GradGame battlefield state ────────────────────────────────────────
       When the game takes over (Battlefield.enterGameMode), the renderer stops
       sampling the expression curve / scalar field and instead draws the scene
       pushed each frame via Battlefield.setScene: instanced discs (entities) +
       concatenated thick polylines (paths). */
    let entityPipeline, pathPipeline;
    let entityBuffer, pathBuffer;
    let entityBindGroup, pathBindGroup;
    let gameMode = false;
    let scene = { entities: [], paths: [] };
    const entityData = new Float32Array(CAP_ENTITIES * 8);   // [x,y,r,kind, r,g,b,a]
    const pathData   = new Float32Array(CAP_PATH_VERTS * 8); // [x,y,flag,w, r,g,b,a]
    let animId = null;
    let startTime = performance.now() / 1000;
    let currentExprJS = null;      // last successfully compiled JS string
    let compiledFn    = null;      // cached Function object

    /* Base ("cropped canvas") extent — the fully zoomed-out view at
       magnification 1. The coordinate-space slider redefines it. Pan/zoom may
       never expand the window past this (magnification stays >= 1) nor move it
       outside these bounds. */
    let baseXMin = -10, baseXMax = 10;
    let baseYMin = -6,  baseYMax = 6;

    /* Viewport (math coords) */
    let viewXMin = baseXMin, viewXMax = baseXMax;
    let viewYMin = baseYMin, viewYMax = baseYMax;

    /* ── Scalar-field state ─────────────────────────────────────────────────
       The same expression is read as f(x,y) and sampled on a grid over the
       viewport. From that grid we draw the level-set contour f(x,y) = c (c set
       by a slider) and the −∇f vector field. The grid is resampled only when
       the view or the expression changes (fieldDirty); sweeping c afterwards is
       cheap (re-marches the cached grid). */
    const FIELD_W   = 140;        // grid cells across x
    const FIELD_H   = 90;         // grid cells across y
    const ARROW_NX  = 22;         // −∇f arrows across x
    const ARROW_NY  = 14;         // −∇f arrows across y
    const CONTOUR_BANDS = 7;      // faint background contour levels

    let fieldDirty      = true;
    let overlayNeedsDraw = true;
    let fieldVals       = new Float32Array((FIELD_W + 1) * (FIELD_H + 1));
    let fieldMin = 0, fieldMax = 1;   // finite value range of the last sample
    let contourT = 0.5;               // contour slider position in [0,1]
    let arrows = [];                  // cached {x,y,dx,dy,mag} in math coords
    let arrowMaxMag = 1;

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
        // Redefine the magnification-1 base extent, then reset the view to it.
        baseXMin = -half;
        baseXMax =  half;
        baseYMin = -half / aspect;
        baseYMax =  half / aspect;
        viewXMin = baseXMin;
        viewXMax = baseXMax;
        viewYMin = baseYMin;
        viewYMax = baseYMax;
        _label.textContent = `±${half}`;
        fieldDirty = true;
    });
    _overlay.append(_label, _slider);
    host.appendChild(_overlay);
    /* ── END TEST OVERLAY ─────────────────────────────────────────────── */

    /* ── Contour-level slider — sweeps c for the f(x,y) = c level set ───── */
    const _cPill = document.createElement('div');
    _cPill.id = 'contour-level-control';
    _cPill.style.cssText = `
        position:absolute; bottom:0.75rem; left:0.75rem; z-index:10;
        display:flex; align-items:center; gap:0.5rem;
        padding:0.4rem 0.75rem;
        border-radius:999px;
        background:rgba(15,23,42,0.72);
        backdrop-filter:blur(10px); -webkit-backdrop-filter:blur(10px);
        color:#fbbf24; font:700 0.75rem/1 ui-monospace,SFMono-Regular,monospace;
        user-select:none; pointer-events:auto;
    `;
    const _cLabel = document.createElement('span');
    _cLabel.textContent = 'f = 0';
    const _cSlider = document.createElement('input');
    _cSlider.type = 'range';
    _cSlider.min = '0';
    _cSlider.max = '1000';
    _cSlider.value = '500';
    _cSlider.style.cssText = 'width:7rem; accent-color:#fbbf24; cursor:pointer;';
    _cSlider.addEventListener('input', () => {
        contourT = Number(_cSlider.value) / 1000;
        updateContourLabel();
        overlayNeedsDraw = true;
    });
    _cPill.append(_cLabel, _cSlider);
    host.appendChild(_cPill);

    function contourLevel() {
        return fieldMin + contourT * (fieldMax - fieldMin);
    }
    function updateContourLabel() {
        _cLabel.textContent = `f = ${formatNum(contourLevel())}`;
    }
    function formatNum(v) {
        if (!Number.isFinite(v)) return '—';
        const a = Math.abs(v);
        if (a !== 0 && (a < 0.01 || a >= 1e4)) return v.toExponential(1);
        return (Math.round(v * 100) / 100).toString();
    }

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

        // GradGame: instanced disc entities (32 B each) + concatenated polyline verts (32 B each)
        entityBuffer = device.createBuffer({
            size: CAP_ENTITIES * 8 * 4,
            usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
        });
        pathBuffer = device.createBuffer({
            size: CAP_PATH_VERTS * 8 * 4,
            usage: GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST,
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

        /* ── GradGame: entity (instanced discs) + path (thick polylines) ──
           Both reuse the shared uniform (binding 0) plus one storage buffer
           each (bindings 3 / 4), all in group 0. */
        const entityLayout = device.createBindGroupLayout({
            entries: [
                { binding: 0, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: { type: 'uniform' } },
                { binding: 3, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: { type: 'read-only-storage' } },
            ],
        });
        const pathLayout = device.createBindGroupLayout({
            entries: [
                { binding: 0, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: { type: 'uniform' } },
                { binding: 4, visibility: GPUShaderStage.VERTEX | GPUShaderStage.FRAGMENT, buffer: { type: 'read-only-storage' } },
            ],
        });

        entityPipeline = device.createRenderPipeline({
            layout: device.createPipelineLayout({ bindGroupLayouts: [entityLayout] }),
            vertex:   { module: shaderModule, entryPoint: 'entityVS' },
            fragment: { module: shaderModule, entryPoint: 'entityFS',
                        targets: [{ format, blend: blendPremul }] },
            primitive: { topology: 'triangle-list' },
        });
        pathPipeline = device.createRenderPipeline({
            layout: device.createPipelineLayout({ bindGroupLayouts: [pathLayout] }),
            vertex:   { module: shaderModule, entryPoint: 'pathVS' },
            fragment: { module: shaderModule, entryPoint: 'pathFS',
                        targets: [{ format, blend: blendPremul }] },
            primitive: { topology: 'triangle-list' },
        });

        entityBindGroup = device.createBindGroup({
            layout: entityLayout,
            entries: [
                { binding: 0, resource: { buffer: uniformBuffer } },
                { binding: 3, resource: { buffer: entityBuffer  } },
            ],
        });
        pathBindGroup = device.createBindGroup({
            layout: pathLayout,
            entries: [
                { binding: 0, resource: { buffer: uniformBuffer } },
                { binding: 4, resource: { buffer: pathBuffer    } },
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
        fieldDirty = true;

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
        if (gameMode) fitWorldView();
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

    /* Centre WORLD in the canvas with isotropic scale (round circles), showing a
       little past the edges. Recomputed each frame in game mode. */
    function fitWorldView() {
        const ww = WORLD.xMax - WORLD.xMin;
        const wh = WORLD.yMax - WORLD.yMin;
        const cx = (WORLD.xMin + WORLD.xMax) / 2;
        const cy = (WORLD.yMin + WORLD.yMax) / 2;
        const ca = (canvas.width || 1) / (canvas.height || 1);
        const wa = ww / wh;
        let halfW, halfH;
        if (ca > wa) { halfH = wh / 2; halfW = halfH * ca; }
        else         { halfW = ww / 2; halfH = halfW / ca; }
        halfW *= VIEW_MARGIN; halfH *= VIEW_MARGIN;
        viewXMin = cx - halfW; viewXMax = cx + halfW;
        viewYMin = cy - halfH; viewYMax = cy + halfH;
    }

    /* Flatten the pushed scene into the GPU buffers. Returns the live counts. */
    function packGameBuffers() {
        const ents = scene.entities || [];
        const nEnt = Math.min(ents.length, CAP_ENTITIES);
        for (let i = 0; i < nEnt; i++) {
            const e = ents[i], o = i * 8, c = e.color || [1, 1, 1, 1];
            entityData[o]     = e.x;
            entityData[o + 1] = e.y;
            entityData[o + 2] = e.r;
            entityData[o + 3] = e.kind || 0;
            entityData[o + 4] = c[0]; entityData[o + 5] = c[1];
            entityData[o + 6] = c[2]; entityData[o + 7] = c[3] == null ? 1 : c[3];
        }

        const paths = scene.paths || [];
        let v = 0;
        for (let p = 0; p < paths.length && v < CAP_PATH_VERTS; p++) {
            const pts = paths[p].points;
            if (!pts || pts.length < 2) continue;
            const c = paths[p].color || [1, 1, 1, 1];
            const w = paths[p].width == null ? CURVE_THICKNESS : paths[p].width;
            for (let k = 0; k < pts.length && v < CAP_PATH_VERTS; k++, v++) {
                const o = v * 8;
                pathData[o]     = pts[k][0];
                pathData[o + 1] = pts[k][1];
                pathData[o + 2] = k === 0 ? 1 : 0;   // 1 = polyline start → bridge segment is a gap
                pathData[o + 3] = w;
                pathData[o + 4] = c[0]; pathData[o + 5] = c[1];
                pathData[o + 6] = c[2]; pathData[o + 7] = c[3] == null ? 1 : c[3];
            }
        }
        return { nEnt, nPathVerts: v };
    }

    function render() {
        resizeCanvas();
        writeUniforms();

        let game = null;
        if (gameMode) {
            game = packGameBuffers();
            if (game.nEnt > 0) {
                device.queue.writeBuffer(entityBuffer, 0, entityData, 0, game.nEnt * 8);
            }
            if (game.nPathVerts > 1) {
                device.queue.writeBuffer(pathBuffer, 0, pathData, 0, game.nPathVerts * 8);
            }
        } else {
            sampleExpression();
        }

        const tex = context.getCurrentTexture();
        const encoder = device.createCommandEncoder();

        /* Compute pass — C¹ continuity check (grapher only) */
        if (!gameMode && compiledFn) {
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

        /* Grid (always) */
        pass.setPipeline(gridPipeline);
        pass.setBindGroup(0, gridBindGroup);
        pass.draw(4);   // fullscreen quad (triangle-strip)

        if (gameMode) {
            /* Trajectories/aim first, then cannons/obstacles/projectile on top. */
            if (game.nPathVerts > 1) {
                pass.setPipeline(pathPipeline);
                pass.setBindGroup(0, pathBindGroup);
                pass.draw((game.nPathVerts - 1) * 6);
            }
            if (game.nEnt > 0) {
                pass.setPipeline(entityPipeline);
                pass.setBindGroup(0, entityBindGroup);
                pass.draw(6, game.nEnt);   // 6 verts/quad × nEnt instances
            }
        } else if (compiledFn) {
            /* Curve: 6 verts per segment, (SAMPLE_COUNT-1) segments */
            pass.setPipeline(curvePipeline);
            pass.setBindGroup(0, curveBindGroup);
            pass.draw((SAMPLE_COUNT - 1) * 6);
        }

        pass.end();
        device.queue.submit([encoder.finish()]);
    }

    /* ══════════════════════════════════════════════════════════════════════
       Scalar field f(x,y): contour level set + −∇f vector field (2D overlay)
       ══════════════════════════════════════════════════════════════════════ */

    function resizeOverlay() {
        const rect = host.getBoundingClientRect();
        const dpr  = window.devicePixelRatio || 1;
        const w = Math.max(1, Math.round(rect.width  * dpr));
        const h = Math.max(1, Math.round(rect.height * dpr));
        if (fieldCanvas.width !== w || fieldCanvas.height !== h) {
            fieldCanvas.width  = w;   // resizing clears the canvas …
            fieldCanvas.height = h;
            overlayNeedsDraw = true;  // … so force a redraw
        }
    }

    function mathToPx(x, y) {
        const px = (x - viewXMin) / (viewXMax - viewXMin) * fieldCanvas.width;
        const py = (1 - (y - viewYMin) / (viewYMax - viewYMin)) * fieldCanvas.height;
        return [px, py];
    }

    function evalF(x, y) {
        try {
            const v = compiledFn(x, y);
            return typeof v === 'number' ? v : NaN;
        } catch {
            return NaN;
        }
    }

    /* Resample f(x,y) over the viewport grid; refresh the finite value range. */
    function sampleField() {
        const dxm = (viewXMax - viewXMin) / FIELD_W;
        const dym = (viewYMax - viewYMin) / FIELD_H;
        let mn = Infinity, mx = -Infinity, k = 0;
        for (let j = 0; j <= FIELD_H; j++) {
            const y = viewYMin + j * dym;
            for (let i = 0; i <= FIELD_W; i++) {
                const v = evalF(viewXMin + i * dxm, y);
                fieldVals[k++] = v;
                if (Number.isFinite(v)) {
                    if (v < mn) mn = v;
                    if (v > mx) mx = v;
                }
            }
        }
        if (Number.isFinite(mn) && Number.isFinite(mx) && mx > mn) {
            fieldMin = mn; fieldMax = mx;
        } else {
            fieldMin = 0; fieldMax = 1;
        }
    }

    /* Sample −∇f on the coarse arrow grid (central differences). */
    function sampleArrows() {
        arrows = [];
        arrowMaxMag = 0;
        const xr = viewXMax - viewXMin;
        const yr = viewYMax - viewYMin;
        const hx = xr * 1e-3, hy = yr * 1e-3;
        for (let j = 0; j < ARROW_NY; j++) {
            const y = viewYMin + (j + 0.5) / ARROW_NY * yr;
            for (let i = 0; i < ARROW_NX; i++) {
                const x = viewXMin + (i + 0.5) / ARROW_NX * xr;
                const gx = (evalF(x + hx, y) - evalF(x - hx, y)) / (2 * hx);
                const gy = (evalF(x, y + hy) - evalF(x, y - hy)) / (2 * hy);
                if (!Number.isFinite(gx) || !Number.isFinite(gy)) continue;
                const dx = -gx, dy = -gy;                 // −∇f
                const mag = Math.hypot(dx, dy);
                if (!Number.isFinite(mag)) continue;
                if (mag > arrowMaxMag) arrowMaxMag = mag;
                arrows.push({ x, y, dx, dy, mag });
            }
        }
        if (!(arrowMaxMag > 0) || !Number.isFinite(arrowMaxMag)) arrowMaxMag = 1;
    }

    /* Marching squares: corner bits BL=1, BR=2, TR=4, TL=8 → edge-pair list.
       Edges: 0 bottom, 1 right, 2 top, 3 left. */
    const MS_TABLE = [
        [], [[3, 0]], [[0, 1]], [[1, 3]],
        [[1, 2]], [[3, 0], [1, 2]], [[0, 2]], [[2, 3]],
        [[2, 3]], [[0, 2]], [[0, 1], [2, 3]], [[1, 2]],
        [[1, 3]], [[0, 1]], [[0, 3]], []
    ];

    function edgePoint(edge, xi, yj, dxm, dym, vbl, vbr, vtr, vtl, c) {
        let t, x, y;
        switch (edge) {
            case 0:  t = (c - vbl) / (vbr - vbl); x = xi + t * dxm;       y = yj;           break;
            case 1:  t = (c - vbr) / (vtr - vbr); x = xi + dxm;           y = yj + t * dym; break;
            case 2:  t = (c - vtr) / (vtl - vtr); x = xi + dxm - t * dxm; y = yj + dym;     break;
            default: t = (c - vtl) / (vbl - vtl); x = xi;                 y = yj + dym - t * dym; break;
        }
        return mathToPx(x, y);
    }

    /* March one level c from the cached grid into the given Path2D. */
    function marchLevel(path, c, dxm, dym) {
        const stride = FIELD_W + 1;
        for (let j = 0; j < FIELD_H; j++) {
            const yj = viewYMin + j * dym;
            const row = j * stride;
            for (let i = 0; i < FIELD_W; i++) {
                const xi = viewXMin + i * dxm;
                const base = row + i;
                const vbl = fieldVals[base];
                const vbr = fieldVals[base + 1];
                const vtl = fieldVals[base + stride];
                const vtr = fieldVals[base + stride + 1];
                if (!Number.isFinite(vbl) || !Number.isFinite(vbr) ||
                    !Number.isFinite(vtr) || !Number.isFinite(vtl)) continue;
                let idx = 0;
                if (vbl >= c) idx |= 1;
                if (vbr >= c) idx |= 2;
                if (vtr >= c) idx |= 4;
                if (vtl >= c) idx |= 8;
                const segs = MS_TABLE[idx];
                for (let s = 0; s < segs.length; s++) {
                    const a = edgePoint(segs[s][0], xi, yj, dxm, dym, vbl, vbr, vtr, vtl, c);
                    const b = edgePoint(segs[s][1], xi, yj, dxm, dym, vbl, vbr, vtr, vtl, c);
                    path.moveTo(a[0], a[1]);
                    path.lineTo(b[0], b[1]);
                }
            }
        }
    }

    function arrowColor(t) {
        // weak → indigo, strong → magenta
        const r = Math.round(120 + 135 * t);
        const g = Math.max(0, Math.round(120 - 40 * t));
        const b = Math.round(246 - 60 * t);
        return `rgba(${r}, ${g}, ${b}, ${(0.45 + 0.45 * t).toFixed(3)})`;
    }

    function drawArrows(ctx, dpr) {
        if (!arrows.length) return;
        const cellPx = Math.min(fieldCanvas.width / ARROW_NX,
                                fieldCanvas.height / ARROW_NY);
        const maxLen = cellPx * 0.46;
        ctx.lineCap = 'round';
        ctx.lineWidth = 1.4 * dpr;
        for (let k = 0; k < arrows.length; k++) {
            const a = arrows[k];
            if (!(a.mag > 0)) continue;
            const ux = a.dx / a.mag, uy = a.dy / a.mag;
            // length grows with magnitude (sqrt for dynamic range), capped
            const len = maxLen * Math.min(1, Math.sqrt(a.mag / arrowMaxMag));
            if (len < 1.5 * dpr) continue;
            const [ox, oy] = mathToPx(a.x, a.y);
            const ex = ox + ux * len;
            const ey = oy - uy * len;                 // px y is flipped
            const ang = Math.atan2(ey - oy, ex - ox);
            const hl = Math.min(len * 0.42, 7 * dpr);
            ctx.strokeStyle = arrowColor(Math.min(1, a.mag / arrowMaxMag));
            ctx.beginPath();
            ctx.moveTo(ox, oy);
            ctx.lineTo(ex, ey);
            ctx.lineTo(ex - hl * Math.cos(ang - 0.45), ey - hl * Math.sin(ang - 0.45));
            ctx.moveTo(ex, ey);
            ctx.lineTo(ex - hl * Math.cos(ang + 0.45), ey - hl * Math.sin(ang + 0.45));
            ctx.stroke();
        }
    }

    function drawField() {
        const ctx = fieldCtx;
        ctx.clearRect(0, 0, fieldCanvas.width, fieldCanvas.height);
        if (!compiledFn || !(fieldMax > fieldMin)) return;

        const dpr = window.devicePixelRatio || 1;
        const dxm = (viewXMax - viewXMin) / FIELD_W;
        const dym = (viewYMax - viewYMin) / FIELD_H;

        // Faint background contour family for context
        const fam = new Path2D();
        for (let b = 1; b < CONTOUR_BANDS; b++) {
            const c = fieldMin + (b / CONTOUR_BANDS) * (fieldMax - fieldMin);
            marchLevel(fam, c, dxm, dym);
        }
        ctx.lineWidth = 1 * dpr;
        ctx.strokeStyle = 'rgba(94, 234, 212, 0.18)';   // teal
        ctx.stroke(fam);

        // −∇f vector field
        drawArrows(ctx, dpr);

        // Bold contour at the slider-selected level c
        const bold = new Path2D();
        marchLevel(bold, contourLevel(), dxm, dym);
        ctx.lineCap = 'round';
        ctx.lineWidth = 2.5 * dpr;
        ctx.strokeStyle = 'rgba(251, 191, 36, 0.95)';   // amber
        ctx.shadowColor = 'rgba(251, 191, 36, 0.55)';
        ctx.shadowBlur = 6 * dpr;
        ctx.stroke(bold);
        ctx.shadowBlur = 0;
    }

    function tick() {
        render();

        /* Scalar-field overlay is grapher-only; the game owns the canvas itself. */
        if (!gameMode) {
            resizeOverlay();
            if (fieldDirty) {
                if (compiledFn) {
                    sampleField();
                    sampleArrows();
                    updateContourLabel();
                }
                fieldDirty = false;
                overlayNeedsDraw = true;
            }
            if (overlayNeedsDraw) {
                drawField();
                overlayNeedsDraw = false;
            }
        }

        animId = requestAnimationFrame(tick);
    }

    /* ── Expression input integration ───────────────────────────────────── */

    function attachInputListeners() {
        // Watch the expression input. Re-parse on every input event.
        // The Wasm module (gradgame-wasm.js) stores parsed JS in a data
        // attribute; we read it after a short delay.
        const input = document.getElementById('expr-input');
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

    /* Constrain the view to the base extent: never zoom out past it
       (magnification >= 1) and never pan outside it. */
    function clampView() {
        const baseXRange = baseXMax - baseXMin;
        const baseYRange = baseYMax - baseYMin;

        if (viewXMax - viewXMin >= baseXRange) {
            viewXMin = baseXMin;
            viewXMax = baseXMax;
        } else if (viewXMin < baseXMin) {
            viewXMax += baseXMin - viewXMin;
            viewXMin  = baseXMin;
        } else if (viewXMax > baseXMax) {
            viewXMin -= viewXMax - baseXMax;
            viewXMax  = baseXMax;
        }

        if (viewYMax - viewYMin >= baseYRange) {
            viewYMin = baseYMin;
            viewYMax = baseYMax;
        } else if (viewYMin < baseYMin) {
            viewYMax += baseYMin - viewYMin;
            viewYMin  = baseYMin;
        } else if (viewYMax > baseYMax) {
            viewYMin -= viewYMax - baseYMax;
            viewYMax  = baseYMax;
        }
    }

    function attachPointerListeners() {
        canvas.style.pointerEvents = 'auto';
        canvas.style.touchAction   = 'none';

        canvas.addEventListener('pointerdown', (e) => {
            if (gameMode) return;            // battlefield view is fixed
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
            clampView();
            fieldDirty = true;
        });

        canvas.addEventListener('pointerup',     () => { isPanning = false; });
        canvas.addEventListener('pointercancel', () => { isPanning = false; });
        canvas.addEventListener('lostpointercapture', () => { isPanning = false; });

        canvas.addEventListener('wheel', (e) => {
            if (gameMode) return;            // battlefield view is fixed
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
            clampView();
            fieldDirty = true;
        }, { passive: false });
    }

    /* ── Resize observer ────────────────────────────────────────────────── */
    new ResizeObserver(() => resizeCanvas()).observe(host);

    /* ── GradGame battlefield API ──────────────────────────────────────────
       gradgame-game.js drives the board through this. enterGameMode swaps the
       grapher chrome out for a fixed WORLD view; setScene pushes the per-frame
       entities + polylines. Defined synchronously so the game module can call
       it before the async WebGPU init resolves (rendering starts once ready). */
    function enterGameMode() {
        gameMode = true;
        window.webgpuGraphActive = true;
        _overlay.style.display   = 'none';   // ±10 coordinate-space slider
        _cPill.style.display     = 'none';   // f = 0 contour slider
        fieldCanvas.style.display = 'none';  // scalar-field overlay
        if (canvas.width && canvas.height) fitWorldView();
    }
    window.Battlefield = {
        enterGameMode,
        setScene(s) { scene = s || { entities: [], paths: [] }; },
        world: WORLD,
        get ready() { return Boolean(device); },
    };

    /* ── Kick off ───────────────────────────────────────────────────────── */
    init().catch((err) => {
        console.error('WebGPU graph init failed:', err);
    });
})();
