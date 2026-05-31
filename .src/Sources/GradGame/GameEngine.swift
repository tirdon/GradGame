// GameEngine.swift
// ──────────────────────────────────────────────────────────────────────────
// Swift port of the pure GradGame engine that used to live in
// `gradgame-engine.js` (itself a port of BunServer's `systems.ts`/`game.ts`).
// No DOM / Firebase / FFI here — just math over the AST, so it is unit-testable
// on the host and re-used by the wasm exports in GradGame.swift.
//
// wasm-safety: index-based `while` loops, `[Double]`/`[Int]` with
// `append`/`count`/subscript only (no `map`/`filter`/`sorted`), `Int` arithmetic
// bounded to ±Int32.max with wrapping `&*`/`&+` in the PRNG, and no `Int*`/`UInt`
// string interpolation anywhere (see swiftwasm-trapping-patterns).
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

struct Cannon {
    var x: Double
    var y: Double
    var alive: Bool
}

struct Obstacle {
    var x: Double
    var y: Double
    var r: Double
}

/// outcome: 0 = out, 1 = hit, 2 = blocked. `path` is flat [x0,y0,x1,y1,…].
/// impact is `nil` (NaN over the FFI) only when the shot produced no points.
struct ShotResult {
    var outcome: Int
    var impactX: Double
    var impactY: Double
    var hitSeat: Int
    var path: [Double]
}

/// `Math.round`-compatible rounding to 3 dp: `floor(v*1000 + 0.5)/1000` rounds
/// halves toward +∞ exactly like JS, so paths match the old engine bit-for-bit.
@inline(__always)
func round3(_ v: Double) -> Double {
    ((v * 1000 + 0.5).rounded(.down)) / 1000
}

@inline(__always)
private func sweepLimit() -> Int {
    Int(((GradGameWorld.xMax - GradGameWorld.xMin) / kStep).rounded(.up)) + 4
}

/// Sweep `y = originY + f(x − originX)` from the cannon in `dir` until the first
/// of hit / blocked / out. `f(s) = expression(s, 0) − expression(0, 0)` so the arc
/// passes through the cannon (same normalization as the old JS `compile`). Returns
/// `nil` when `f(0)` is non-finite (e.g. 1/x, log x) — the shot can't start.
func simulateShot(
    expression: Expression,
    originX: Double, originY: Double, dir: Double,
    shooterSeat: Int, cannons: [Cannon], obstacles: [Obstacle]
) -> ShotResult? {
    let offset = expression.evaluate(x: 0, y: 0)
    if !offset.isFinite { return nil }

    var path: [Double] = []
    let limit = sweepLimit()
    var x = originX
    var outcome = -1
    var impactX = Double.nan
    var impactY = Double.nan
    var hitSeat = -1
    var impactSet = false

    var i = 0
    while i < limit {
        if (dir > 0 && x > GradGameWorld.xMax) || (dir < 0 && x < GradGameWorld.xMin) {
            outcome = 0 // out
            break
        }

        let s = x - originX
        let travelled = s < 0 ? -s : s
        let wy = originY + (expression.evaluate(x: s, y: 0) - offset)
        let valid = wy.isFinite && (wy < 0 ? -wy : wy) < kMaxAbsY
        if valid {
            path.append(round3(x))
            path.append(round3(wy))
        }

        if valid && travelled > kMuzzleClearance {
            var hit = -1
            var c = 0
            while c < cannons.count {
                let cn = cannons[c]
                if c != shooterSeat && cn.alive {
                    let dx = x - cn.x
                    let dy = wy - cn.y
                    if (dx * dx + dy * dy).squareRoot() < kCannonRadius { hit = c; break }
                }
                c += 1
            }
            if hit >= 0 {
                outcome = 1
                impactX = round3(x); impactY = round3(wy); hitSeat = hit; impactSet = true
                break
            }

            var blocked = false
            var o = 0
            while o < obstacles.count {
                let ob = obstacles[o]
                let dx = x - ob.x
                let dy = wy - ob.y
                if (dx * dx + dy * dy).squareRoot() < ob.r { blocked = true; break }
                o += 1
            }
            if blocked {
                outcome = 2
                impactX = round3(x); impactY = round3(wy); impactSet = true
                break
            }
        }

        x += dir * kStep
        i += 1
    }

    if outcome == -1 { outcome = 0 }
    if !impactSet && path.count >= 2 {
        impactX = path[path.count - 2]
        impactY = path[path.count - 1]
    }
    return ShotResult(outcome: outcome, impactX: impactX, impactY: impactY, hitSeat: hitSeat, path: path)
}

/// Rebuild a shot's visible polyline (no collision tests), stopping at `endX`
/// (the impact x) so every client reproduces the same arc the authoritative sim
/// drew, regardless of since-changed cannon/obstacle state. `endX == nil` sweeps
/// to the field edge. Returns `nil` when `f(0)` is non-finite. Flat [x,y,…].
func resampleArc(
    expression: Expression,
    originX: Double, originY: Double, dir: Double, endX: Double?
) -> [Double]? {
    let offset = expression.evaluate(x: 0, y: 0)
    if !offset.isFinite { return nil }

    var path: [Double] = []
    let limit = sweepLimit()
    var x = originX
    var i = 0
    while i < limit {
        if (dir > 0 && x > GradGameWorld.xMax) || (dir < 0 && x < GradGameWorld.xMin) { break }
        let wy = originY + (expression.evaluate(x: x - originX, y: 0) - offset)
        if wy.isFinite && (wy < 0 ? -wy : wy) < kMaxAbsY {
            path.append(round3(x))
            path.append(round3(wy))
        }
        if let endX, (dir > 0 && x >= endX) || (dir < 0 && x <= endX) { break }
        x += dir * kStep
        i += 1
    }
    return path
}

/// Fire toward the nearest living opponent; default +1 if somehow none.
func aimDirection(originX: Double, originY: Double, shooterSeat: Int, cannons: [Cannon]) -> Int {
    var bestX = 0.0
    var bestD = Double.infinity
    var hasBest = false
    var c = 0
    while c < cannons.count {
        let cn = cannons[c]
        if c != shooterSeat && cn.alive {
            let dx = cn.x - originX
            let dy = cn.y - originY
            let d = (dx * dx + dy * dy).squareRoot()
            if d < bestD { bestD = d; bestX = cn.x; hasBest = true }
        }
        c += 1
    }
    if !hasBest { return 1 }
    return bestX >= originX ? 1 : -1
}

/// `aliveMask` bit `j` set ⇔ seat `j` is occupied AND alive.
func aliveCount(aliveMask: Int) -> Int {
    var n = 0
    var j = 0
    while j < kMaxSeats {
        if (aliveMask >> j) & 1 == 1 { n += 1 }
        j += 1
    }
    return n
}

/// Next seat to move after `fromSeat`, skipping empty/eliminated seats. Returns
/// `fromSeat` for a sole survivor (callers test `aliveCount == 1` first), or -1.
func nextAliveSeat(aliveMask: Int, fromSeat: Int) -> Int {
    var k = 1
    while k <= kMaxSeats {
        let j = (fromSeat + k) % kMaxSeats
        if (aliveMask >> j) & 1 == 1 { return j }
        k += 1
    }
    return -1
}

/// Deterministic PRNG: a 31-bit LCG (glibc constants) using only `Int` with
/// wrapping `&*`/`&+` masked to 0x7FFFFFFF, so every value stays in [0, 2^31)
/// ⊂ Int32 range and behaves identically on host (64-bit Int) and wasm (32-bit).
struct LCG {
    private var state: Int
    init(seed: Int) {
        let s = seed & 0x7FFFFFFF
        state = s == 0 ? 0x2545F491 : s
    }
    mutating func next() -> Int {
        state = (state &* 1103515245 &+ 12345) & 0x7FFFFFFF
        return state
    }
    /// Double in [0, 1) from the top 24 bits of the 31-bit state.
    mutating func nextDouble() -> Double {
        Double(next() >> 7) / 16777216.0
    }
}

@inline(__always)
private func rand(_ rng: inout LCG, _ lo: Double, _ hi: Double) -> Double {
    lo + rng.nextDouble() * (hi - lo)
}

/// Random cannon positions for the occupied seats, spaced ≥ kMinSeparation.
/// Returns 8 doubles: x,y per seat 0..3 (NaN,NaN for an unoccupied seat).
func placePlayers(occupiedSeats: [Int], seed: Int) -> [Double] {
    var rng = LCG(seed: seed)
    var positions = [Double](repeating: Double.nan, count: 8)
    var placedX: [Double] = []
    var placedY: [Double] = []

    var si = 0
    while si < occupiedSeats.count {
        let seat = occupiedSeats[si]
        var px = 0.0
        var py = 0.0
        var guardCount = 0
        while true {
            px = rand(&rng, GradGameWorld.xMin + 1.5, GradGameWorld.xMax - 1.5)
            py = rand(&rng, GradGameWorld.yMin + 1.2, GradGameWorld.yMax - 1.2)
            guardCount += 1
            var tooClose = false
            var k = 0
            while k < placedX.count {
                let dx = placedX[k] - px
                let dy = placedY[k] - py
                if (dx * dx + dy * dy).squareRoot() < kMinSeparation { tooClose = true; break }
                k += 1
            }
            if !tooClose || guardCount >= 400 { break }
        }
        placedX.append(px)
        placedY.append(py)
        if seat >= 0 && seat < kMaxSeats {
            positions[seat * 2] = px
            positions[seat * 2 + 1] = py
        }
        si += 1
    }
    return positions
}

/// Random obstacles (3–6) avoiding cannons and each other. `positions` is the
/// 8-double seat layout from `placePlayers`. Returns flat [x,y,r,…].
func generateObstacles(positions: [Double], seed: Int) -> [Double] {
    var rng = LCG(seed: seed)
    var ptsX: [Double] = []
    var ptsY: [Double] = []
    var s = 0
    while s < kMaxSeats {
        let x = positions[s * 2]
        let y = positions[s * 2 + 1]
        if x.isFinite && y.isFinite { ptsX.append(x); ptsY.append(y) }
        s += 1
    }

    let count = 3 + Int(rng.nextDouble() * 4) // 3–6
    var out: [Double] = []
    var placedX: [Double] = []
    var placedY: [Double] = []
    var placedR: [Double] = []
    var guardCount = 0
    while placedX.count < count && guardCount < 400 {
        guardCount += 1
        let ox = rand(&rng, -5.5, 5.5)
        let oy = rand(&rng, GradGameWorld.yMin + 1, GradGameWorld.yMax - 1)
        let orr = rand(&rng, 0.55, 1.35)

        var nearPlayer = false
        var p = 0
        while p < ptsX.count {
            let dx = ptsX[p] - ox
            let dy = ptsY[p] - oy
            if (dx * dx + dy * dy).squareRoot() < orr + 2.2 { nearPlayer = true; break }
            p += 1
        }

        var overlaps = false
        var b = 0
        while b < placedX.count {
            let dx = placedX[b] - ox
            let dy = placedY[b] - oy
            if (dx * dx + dy * dy).squareRoot() < placedR[b] + orr + 0.4 { overlaps = true; break }
            b += 1
        }

        if !nearPlayer && !overlaps {
            placedX.append(ox)
            placedY.append(oy)
            placedR.append(orr)
            out.append(ox)
            out.append(oy)
            out.append(orr)
        }
    }
    return out
}
