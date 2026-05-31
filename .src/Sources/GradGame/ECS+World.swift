// ECS+World.swift
// ──────────────────────────────────────────────────────────────────────────
// The World registry: concrete per-archetype struct-of-arrays storage plus
// non-generic spawn/get/set/query methods. Three archetypes:
//   • cannon   — seat-indexed columns (Position, Alive, Seat); column index == seat
//   • obstacle — append-ordered columns (Position, Shape)
//   • shot     — at most one entity carrying Outcome / Impact / Trajectory
//
// All storage is `[Double]`/`[Int]`/`[Bool]` over plain values plus one flat
// `[Double]` path: entirely within the wasm-safe array subset. No `Dictionary`,
// no generics, no metatypes (see ECS+Core.swift header).
// ──────────────────────────────────────────────────────────────────────────

struct World {
    // ── Cannon archetype (seat order preserved: column index == seat == Entity.id) ──
    private var cnX: [Double] = []
    private var cnY: [Double] = []
    private var cnAlive: [Bool] = []
    private var cnSeat: [Int] = []

    // ── Obstacle archetype (append order) ──
    private var obX: [Double] = []
    private var obY: [Double] = []
    private var obR: [Double] = []

    // ── Shot archetype (at most one; shId < 0 ⇒ none spawned) ──
    private var shOutcome: Int = -1
    private var shImpactX: Double = .nan
    private var shImpactY: Double = .nan
    private var shHitSeat: Int = -1
    private var shPath: [Double] = []
    private var shId: Int = -1

    init() {}

    // ── Spawn (concrete, NOT generic) ──────────────────────────────────────────
    /// Cannons spawn in seat order so the column index equals the seat index — the
    /// FFI contract that `shooterSeat`/`hitSeat` are seat indices depends on this.
    @discardableResult
    mutating func spawnCannon(seat: Int, x: Double, y: Double, alive: Bool) -> Entity {
        let id = cnX.count
        cnX.append(x)
        cnY.append(y)
        cnAlive.append(alive)
        cnSeat.append(seat)
        return Entity(id: id)
    }

    @discardableResult
    mutating func spawnObstacle(x: Double, y: Double, radius: Double) -> Entity {
        let id = obX.count
        obX.append(x)
        obY.append(y)
        obR.append(radius)
        return Entity(id: id)
    }

    /// Spawn (or overwrite) the single shot entity with its result components.
    @discardableResult
    mutating func spawnShot(outcome: Outcome, impact: Impact, trajectory: Trajectory) -> Entity {
        shOutcome = outcome.value
        shImpactX = impact.x
        shImpactY = impact.y
        shHitSeat = impact.seat
        shPath = trajectory.points
        shId = 0
        return Entity(id: 0)
    }

    // ── Counts / entity handles ────────────────────────────────────────────────
    var cannonCount: Int { cnX.count }
    var obstacleCount: Int { obX.count }
    func cannonEntity(at index: Int) -> Entity { Entity(id: index) }
    func obstacleEntity(at index: Int) -> Entity { Entity(id: index) }

    // ── Get (concrete accessors) ───────────────────────────────────────────────
    func position(ofCannon e: Entity) -> Position { Position(x: cnX[e.id], y: cnY[e.id]) }
    func alive(ofCannon e: Entity) -> Bool { cnAlive[e.id] }
    func seat(ofCannon e: Entity) -> Int { cnSeat[e.id] }
    func position(ofObstacle e: Entity) -> Position { Position(x: obX[e.id], y: obY[e.id]) }
    func shape(ofObstacle e: Entity) -> Shape { Shape(radius: obR[e.id]) }

    /// Raw column reads for the hot collision/aim loops — keep them allocation-free
    /// and in the exact same order as the legacy engine.
    func cnXAt(_ i: Int) -> Double { cnX[i] }
    func cnYAt(_ i: Int) -> Double { cnY[i] }
    func cnAliveAt(_ i: Int) -> Bool { cnAlive[i] }
    func obXAt(_ i: Int) -> Double { obX[i] }
    func obYAt(_ i: Int) -> Double { obY[i] }
    func obRAt(_ i: Int) -> Double { obR[i] }

    // ── Set ────────────────────────────────────────────────────────────────────
    mutating func setAlive(_ e: Entity, _ value: Bool) { cnAlive[e.id] = value }

    // ── Shot read-back (consumed by FFI / tests) ───────────────────────────────
    var hasShot: Bool { shId >= 0 }
    var shotEntity: Entity? { shId >= 0 ? Entity(id: shId) : nil }
    func outcome(of e: Entity) -> Outcome { Outcome(value: shOutcome) }
    func impact(of e: Entity) -> Impact { Impact(x: shImpactX, y: shImpactY, seat: shHitSeat) }
    func trajectory(of e: Entity) -> Trajectory { Trajectory(points: shPath) }

    // ── Query (the wasm-safe spelling: an `append`-built id list, never `filter`) ──
    /// Seat indices of living cannons that are not the shooter, in seat order.
    func aliveOpponents(of shooterSeat: Int) -> [Int] {
        var out: [Int] = []
        var c = 0
        while c < cnX.count {
            if c != shooterSeat && cnAlive[c] { out.append(c) }
            c += 1
        }
        return out
    }
}
