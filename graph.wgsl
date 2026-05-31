/* ═══════════════════════════════════════════════════════════════════════════
   graph.wgsl — WebGPU shaders for GradGame function graph renderer
   ═══════════════════════════════════════════════════════════════════════════ */

/* ─── Shared uniform block ─────────────────────────────────────────────── */
struct Uniforms {
    resolution : vec2f,   // canvas width, height in pixels
    xMin       : f32,
    xMax       : f32,
    yMin       : f32,
    yMax       : f32,
    sampleCount: f32,     // number of curve samples
    thickness  : f32,     // curve half-thickness in pixels
    time       : f32,     // animation time (seconds)
    _pad       : f32,
}

@group(0) @binding(0) var<uniform> u : Uniforms;

/* ─── Storage buffer: sampled y-values from JS eval ────────────────────── */
@group(0) @binding(1) var<storage, read> samples : array<f32>;

/* ─── C¹ continuity flags ──────────────────────────────────────────────── */
/* Compute writes per-sample flags via group 1 (read-write).              */
@group(1) @binding(0) var<storage, read_write> flags : array<u32>;
/* Curve shader reads the same buffer via group 0 binding 2 (read-only).  */
@group(0) @binding(2) var<storage, read> c1flags : array<u32>;


/* ═══════════════════════════════════════════════════════════════════════════
   GRID PASS — fullscreen quad that draws axes + grid
   ═══════════════════════════════════════════════════════════════════════════ */

struct GridVSOut {
    @builtin(position) pos : vec4f,
    @location(0)       uv  : vec2f,
}

@vertex
fn gridVS(@builtin(vertex_index) vi : u32) -> GridVSOut {
    // Two-triangle fullscreen quad: 0,1,2  and  2,1,3
    let x = f32(vi & 1u) * 2.0 - 1.0;
    let y = f32((vi >> 1u) & 1u) * 2.0 - 1.0;
    var out : GridVSOut;
    out.pos = vec4f(x, y, 0.0, 1.0);
    out.uv  = vec2f(x, y) * 0.5 + 0.5;         // [0,1]
    return out;
}

@fragment
fn gridFS(in : GridVSOut) -> @location(0) vec4f {
    let px = in.uv * u.resolution;              // pixel coords

    // Map pixel → math coords
    let mx = mix(u.xMin, u.xMax, in.uv.x);
    let my = mix(u.yMin, u.yMax, in.uv.y);

    var color = vec4f(0.0);

    // ── Minor grid ──────────────────────────────────────────────────────
    let gridSpacingX = bestGridStep(u.xMax - u.xMin);
    let gridSpacingY = bestGridStep(u.yMax - u.yMin);

    let gx = abs(fract(mx / gridSpacingX + 0.5) - 0.5) * gridSpacingX;
    let gy = abs(fract(my / gridSpacingY + 0.5) - 0.5) * gridSpacingY;

    let pxPerUnitX = u.resolution.x / (u.xMax - u.xMin);
    let pxPerUnitY = u.resolution.y / (u.yMax - u.yMin);

    let gxPx = gx * pxPerUnitX;
    let gyPx = gy * pxPerUnitY;

    let minorAlpha = 0.08;
    let gridLineW  = 1.0;
    color = mix(color, vec4f(0.42, 0.48, 0.58, minorAlpha),
                smoothstep(gridLineW + 0.5, gridLineW - 0.5, gxPx));
    color = mix(color, vec4f(0.42, 0.48, 0.58, minorAlpha),
                smoothstep(gridLineW + 0.5, gridLineW - 0.5, gyPx));

    // ── Axes (x = 0, y = 0) ─────────────────────────────────────────────
    let axPx = abs(mx) * pxPerUnitX;
    let ayPx = abs(my) * pxPerUnitY;
    let axisW = 1.5;
    let axisAlpha = 0.32;
    color = mix(color, vec4f(0.40, 0.45, 0.55, axisAlpha),
                smoothstep(axisW + 0.8, axisW - 0.8, axPx));
    color = mix(color, vec4f(0.40, 0.45, 0.55, axisAlpha),
                smoothstep(axisW + 0.8, axisW - 0.8, ayPx));

    return color;
}

/* Pick a "nice" grid spacing: 1, 2, 5, 10, 20, 50, … */
fn bestGridStep(range : f32) -> f32 {
    let rough = range / 8.0;                     // aim for ~8 grid lines
    let mag   = pow(10.0, floor(log10(rough)));
    let norm  = rough / mag;
    if (norm < 1.5)  { return mag; }
    if (norm < 3.5)  { return mag * 2.0; }
    if (norm < 7.5)  { return mag * 5.0; }
    return mag * 10.0;
}

fn log10(x : f32) -> f32 { return log(x) / log(10.0); }


/* ═══════════════════════════════════════════════════════════════════════════
   COMPUTE PASS — C¹ continuity via central finite difference
   ═══════════════════════════════════════════════════════════════════════════
   For each sample i, compute f'(x_i) with central differences, predict
   the next canvas position, and compare:
       length(predicted − actual)  ≤  hypot(dy_canvas, dx_canvas)
   Flag = 1 when C¹ holds, 0 when it does not.                            */

@compute @workgroup_size(64)
fn checkC1(@builtin(global_invocation_id) gid : vec3u) {
    let i = gid.x;
    let N = u32(u.sampleCount);
    if (i >= N) { return; }

    let y_cur = samples[i];

    /* Boundaries and invalid samples */
    if (i == 0u || i >= N - 1u || !isFinite(y_cur)) {
        flags[i] = select(0u, 1u, isFinite(y_cur));
        return;
    }

    let y_prev = samples[i - 1u];
    let y_next = samples[i + 1u];

    if (!isFinite(y_prev) || !isFinite(y_next)) {
        flags[i] = 0u;
        return;
    }

    /* Math-space sample step */
    let dx_m = (u.xMax - u.xMin) / f32(N - 1u);

    /* Central finite difference:  f'(x_i) ≈ (y_{i+1} − y_{i−1}) / 2·dx */
    let dydx = (y_next - y_prev) / (2.0 * dx_m);

    /* Canvas scale factors */
    let sx = u.resolution.x / (u.xMax - u.xMin);
    let sy = u.resolution.y / (u.yMax - u.yMin);

    /* Current canvas position */
    let cx = f32(i) * (u.resolution.x / f32(N - 1u));
    let cy = (1.0 - (y_cur - u.yMin) / (u.yMax - u.yMin)) * u.resolution.y;

    /* Predicted next canvas position using the tangent */
    let pred_x = cx + dx_m * sx;
    let pred_y = cy - dydx * dx_m * sy;           /* minus: canvas y flipped */

    /* Actual next canvas position */
    let act_x = f32(i + 1u) * (u.resolution.x / f32(N - 1u));
    let act_y = (1.0 - (y_next - u.yMin) / (u.yMax - u.yMin)) * u.resolution.y;

    /* length(predicted − actual)  vs  hypot(dy, dx)  in canvas px */
    let err  = length(vec2f(pred_x - act_x, pred_y - act_y));
    let step = length(vec2f(act_x - cx, act_y - cy));

    flags[i] = select(0u, 1u, err <= step);
}


/* ═══════════════════════════════════════════════════════════════════════════
   CURVE PASS — thick anti-aliased line from sampled y-values
   ═══════════════════════════════════════════════════════════════════════════
   Each sample index i generates a quad (4 vertices, 6 indices via
   triangle-strip restart emulated by the index buffer built in JS).
   The vertex shader reads two adjacent samples to build a thick segment.  */

struct CurveVSOut {
    @builtin(position) pos  : vec4f,
    @location(0)       dist : f32,     // signed distance from centreline
    @location(1)       fade : f32,     // 0 at NaN/Inf gaps, 1 otherwise
    @location(2)       c1ok : f32,     // 1.0 = C¹ continuous, 0.0 = not
}

@vertex
fn curveVS(@builtin(vertex_index) vid : u32) -> CurveVSOut {
    // Each segment has 6 verts (two triangles); decode segment + corner
    let segIdx   = vid / 6u;
    let cornerId = vid % 6u;

    // Map corner → (end, side):  0→(0,-1)  1→(0,+1)  2→(1,-1)  3→(1,-1)  4→(0,+1)  5→(1,+1)
    var endF  : f32;
    var sideF : f32;
    switch cornerId {
        case 0u: { endF = 0.0; sideF = -1.0; }
        case 1u: { endF = 0.0; sideF =  1.0; }
        case 2u: { endF = 1.0; sideF = -1.0; }
        case 3u: { endF = 1.0; sideF = -1.0; }
        case 4u: { endF = 0.0; sideF =  1.0; }
        case 5u: { endF = 1.0; sideF =  1.0; }
        default: { endF = 0.0; sideF = 0.0; }
    }

    let N = u32(u.sampleCount);
    let i0 = segIdx;
    let i1 = min(segIdx + 1u, N - 1u);

    let y0 = samples[i0];
    let y1 = samples[i1];

    // Check for NaN / Inf
    let valid0 = isFinite(y0);
    let valid1 = isFinite(y1);
    let valid  = valid0 && valid1;

    // Map sample index → NDC x  (-1..1)
    let t0 = f32(i0) / f32(N - 1u);
    let t1 = f32(i1) / f32(N - 1u);

    // Map y → NDC y
    let ndc_x0 = t0 * 2.0 - 1.0;
    let ndc_x1 = t1 * 2.0 - 1.0;
    let ndc_y0 = ((y0 - u.yMin) / (u.yMax - u.yMin)) * 2.0 - 1.0;
    let ndc_y1 = ((y1 - u.yMin) / (u.yMax - u.yMin)) * 2.0 - 1.0;

    let pA = select(vec2f(0.0), vec2f(ndc_x0, ndc_y0), valid);
    let pB = select(vec2f(0.0), vec2f(ndc_x1, ndc_y1), valid);

    // Segment direction and normal in pixel space
    let pxA = (pA * 0.5 + 0.5) * u.resolution;
    let pxB = (pB * 0.5 + 0.5) * u.resolution;
    let dir = pxB - pxA;
    let len = length(dir);
    let d   = select(vec2f(1.0, 0.0), dir / len, len > 0.001);
    let n   = vec2f(-d.y, d.x);

    // Interpolated point + offset
    let pxP = mix(pxA, pxB, endF) + n * sideF * (u.thickness + 1.0);

    // Back to NDC
    let ndc = (pxP / u.resolution) * 2.0 - 1.0;

    /* Read C¹ flags for both endpoints of this segment */
    let f0 = c1flags[i0];
    let f1 = c1flags[i1];

    var out : CurveVSOut;
    out.pos  = vec4f(ndc.x, ndc.y, 0.0, 1.0);
    out.dist = sideF;
    out.fade = select(0.0, 1.0, valid);
    out.c1ok = select(0.0, 1.0, f0 == 1u && f1 == 1u);
    return out;
}

@fragment
fn curveFS(in : CurveVSOut) -> @location(0) vec4f {
    if (in.fade < 0.5) { discard; }

    // Smooth anti-aliased edge
    let d  = abs(in.dist);
    let aa = 1.0 - smoothstep(0.6, 1.0, d);

    // Blue when C¹ continuous, red when not
    let blue_core = vec3f(0.145, 0.388, 0.922);   // #2563eb
    let blue_glow = vec3f(0.420, 0.580, 1.000);
    let red_core  = vec3f(0.863, 0.149, 0.149);   // #dc2626
    let red_glow  = vec3f(1.000, 0.400, 0.400);

    let core = mix(red_core, blue_core, in.c1ok);
    let glow = mix(red_glow, blue_glow, in.c1ok);
    let c    = mix(glow, core, smoothstep(0.0, 0.5, d));

    return vec4f(c, aa * 0.92);
}

fn isFinite(v : f32) -> bool {
    return !(v != v) && abs(v) < 1.0e+15;  // NaN check + Inf guard
}


/* ═══════════════════════════════════════════════════════════════════════════
   GRADGAME — battlefield geometry rendered entirely on the GPU
   ═══════════════════════════════════════════════════════════════════════════
   Two extra pipelines turn the function-grapher canvas into a game board:

     • entityVS/entityFS — instanced SDF discs for obstacles, cannons, the
       projectile head and the active-turn glow.
     • pathVS/pathFS     — generic thick world-space polylines for trajectory
       arcs, the projectile trail, cannon barrels and the aim preview.

   Both reuse the shared Uniforms viewport (xMin..yMax) for the world→clip
   mapping below. They live in group(0) at fresh bindings (3, 4) so each
   pipeline binds only what it references.                                    */

fn worldToNdc(p : vec2f) -> vec2f {
    let nx = (p.x - u.xMin) / (u.xMax - u.xMin) * 2.0 - 1.0;
    let ny = (p.y - u.yMin) / (u.yMax - u.yMin) * 2.0 - 1.0;
    return vec2f(nx, ny);
}

/* ─── Entities: instanced discs ────────────────────────────────────────────
   Each instance is a world-space circle. The vertex shader expands a unit
   quad (slightly oversized for glow/AA) around the centre; the fragment
   shader draws an SDF disc whose look depends on `kind`.                     */

struct Entity {
    center : vec2f,   // world coords
    radius : f32,     // world units
    kind   : f32,     // 0 obstacle · 1 cannon · 2 projectile head · 3 turn glow
    color  : vec4f,   // straight rgba
}
@group(0) @binding(3) var<storage, read> entities : array<Entity>;

struct EntityVSOut {
    @builtin(position) pos   : vec4f,
    @location(0)       local : vec2f,   // [-M, M]; |local| = 1 at the true radius
    @location(1)       kind  : f32,
    @location(2)       color : vec4f,
}

const ENTITY_MARGIN : f32 = 1.3;

@vertex
fn entityVS(@builtin(vertex_index) vid : u32,
            @builtin(instance_index) iid : u32) -> EntityVSOut {
    var corners = array<vec2f, 6>(
        vec2f(-1.0, -1.0), vec2f( 1.0, -1.0), vec2f(-1.0,  1.0),
        vec2f(-1.0,  1.0), vec2f( 1.0, -1.0), vec2f( 1.0,  1.0)
    );
    let c = corners[vid] * ENTITY_MARGIN;
    let e = entities[iid];
    let world = e.center + c * e.radius;

    var out : EntityVSOut;
    out.pos   = vec4f(worldToNdc(world), 0.0, 1.0);
    out.local = c;
    out.kind  = e.kind;
    out.color = e.color;
    return out;
}

@fragment
fn entityFS(in : EntityVSOut) -> @location(0) vec4f {
    let d  = length(in.local);                  // 1.0 at the true radius
    let aa = max(fwidth(d), 0.0015);
    let k  = in.kind;

    var rgb   = in.color.rgb;
    var alpha = 0.0;

    if (k < 0.5) {
        // obstacle: filled disc with a little radial shading
        let fill = 1.0 - smoothstep(1.0 - aa, 1.0, d);
        rgb   = in.color.rgb * mix(1.0, 0.62, clamp(d, 0.0, 1.0));
        alpha = fill * in.color.a;
    } else if (k < 1.5) {
        // cannon: filled disc + bright rim
        let fill = 1.0 - smoothstep(1.0 - aa, 1.0, d);
        let rim  = smoothstep(0.72, 0.82, d) * (1.0 - smoothstep(0.97, 1.0 + aa, d));
        rgb   = mix(in.color.rgb, vec3f(1.0), rim * 0.65);
        alpha = max(fill, rim) * in.color.a;
    } else if (k < 2.5) {
        // projectile head: white-hot core + soft glow
        let core = 1.0 - smoothstep(0.30 - aa, 0.30 + aa, d);
        let glow = (1.0 - smoothstep(0.30, 1.0, d)) * 0.55;
        rgb   = mix(in.color.rgb, vec3f(1.0), core);
        alpha = clamp(max(core, glow), 0.0, 1.0) * in.color.a;
    } else {
        // turn glow: hollow halo ring
        let ring = smoothstep(0.52, 0.86, d) * (1.0 - smoothstep(0.92, 1.0, d));
        alpha = ring * in.color.a;
    }

    if (alpha <= 0.001) { discard; }
    return vec4f(rgb, alpha);
}

/* ─── Paths: thick world-space polylines ───────────────────────────────────
   One storage buffer holds every polyline concatenated. A vertex whose
   `flags` marks a polyline start breaks the segment that would bridge into
   it, so all arcs draw in a single instanced-free draw of (count-1)*6 verts.
   Built to mirror curveVS, but in world coords with per-vertex colour/width. */

struct PathVert {
    pos   : vec2f,   // world coords
    flags : f32,     // 1.0 = polyline start (segment before it is a gap)
    width : f32,     // half-thickness in px
    color : vec4f,   // straight rgba
}
@group(0) @binding(4) var<storage, read> pathVerts : array<PathVert>;

struct PathVSOut {
    @builtin(position) pos   : vec4f,
    @location(0)       dist  : f32,
    @location(1)       fade  : f32,
    @location(2)       color : vec4f,
}

@vertex
fn pathVS(@builtin(vertex_index) vid : u32) -> PathVSOut {
    let segIdx   = vid / 6u;
    let cornerId = vid % 6u;

    var endF  : f32;
    var sideF : f32;
    switch cornerId {
        case 0u: { endF = 0.0; sideF = -1.0; }
        case 1u: { endF = 0.0; sideF =  1.0; }
        case 2u: { endF = 1.0; sideF = -1.0; }
        case 3u: { endF = 1.0; sideF = -1.0; }
        case 4u: { endF = 0.0; sideF =  1.0; }
        case 5u: { endF = 1.0; sideF =  1.0; }
        default: { endF = 0.0; sideF =  0.0; }
    }

    let a = pathVerts[segIdx];
    let b = pathVerts[segIdx + 1u];

    // Gap when the next vertex begins a new polyline.
    let valid = b.flags < 0.5;

    let pxA = (worldToNdc(a.pos) * 0.5 + 0.5) * u.resolution;
    let pxB = (worldToNdc(b.pos) * 0.5 + 0.5) * u.resolution;
    let dir = pxB - pxA;
    let len = length(dir);
    let dd  = select(vec2f(1.0, 0.0), dir / len, len > 0.001);
    let nn  = vec2f(-dd.y, dd.x);

    let w   = a.width;
    let pxP = mix(pxA, pxB, endF) + nn * sideF * (w + 1.0);
    let ndc = (pxP / u.resolution) * 2.0 - 1.0;

    var out : PathVSOut;
    out.pos   = vec4f(ndc.x, ndc.y, 0.0, 1.0);
    out.dist  = sideF;
    out.fade  = select(0.0, 1.0, valid);
    out.color = a.color;
    return out;
}

@fragment
fn pathFS(in : PathVSOut) -> @location(0) vec4f {
    if (in.fade < 0.5) { discard; }
    let d  = abs(in.dist);
    let aa = 1.0 - smoothstep(0.55, 1.0, d);
    return vec4f(in.color.rgb, in.color.a * aa);
}
