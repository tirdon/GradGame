// ECS+Math.swift
// ──────────────────────────────────────────────────────────────────────────
// Determinism primitives for the GradGame engine: world bounds, tunables, the
// `Math.round`-compatible 3 dp rounding, and the trajectory sweep length. These
// are the load-bearing constants — changing any value (or the rounding/PRNG math
// in ECS+Systems.swift) shifts deterministic placements/obstacles/arcs and breaks
// the JS game's cross-client arc reproducibility.
//
// wasm-safety: nothing here touches `Int32`/`UInt` interpolation, `Sequence`
// for-in, generic `Array` higher-order methods, or `Dictionary`. See
// swiftwasm-trapping-patterns.
// ──────────────────────────────────────────────────────────────────────────

/// Battlefield tunables (port of BunServer/constants.ts, mirrored in gradgame-graph.js).
enum GradGameWorld {
    static let xMin = -12.0
    static let xMax = 12.0
    static let yMin = -6.75
    static let yMax = 6.75
}

let kCannonRadius = 0.55       // a shot within this of a cannon scores
let kMuzzleClearance = 0.7     // ignore collisions this close to the firer
let kStep = 0.03               // trajectory integration step
let kMaxAbsY = 1.0e4           // samples beyond this are gaps (asymptotes)
let kMinSeparation = 5.0       // min spacing between cannons on Start
let kMaxSeats = 4

/// `Math.round`-compatible rounding to 3 dp: `floor(v*1000 + 0.5)/1000` rounds
/// halves toward +∞ exactly like JS, so paths match the old engine bit-for-bit.
@inline(__always)
func round3(_ v: Double) -> Double {
    ((v * 1000 + 0.5).rounded(.down)) / 1000
}

/// Upper bound on the number of integration steps across the field, plus slack.
/// `internal` (not `private`) so the systems in ECS+Systems.swift can call it.
@inline(__always)
func sweepLimit() -> Int {
    Int(((GradGameWorld.xMax - GradGameWorld.xMin) / kStep).rounded(.up)) + 4
}
