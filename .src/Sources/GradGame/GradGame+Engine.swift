#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#endif

// The GradGame engine FFI is wasm-only: `gradGameEmitResult` is a host import that
// has no definition on the host (a Mach-O build can't link it). The pure engine in
// GameEngine.swift/Evaluator.swift stays available everywhere for host unit tests.
#if arch(wasm32)
/// Host callback (provided by gradgame-wasm.js in the `gradgame` import module):
/// the engine pushes a finished result back in one call instead of stashing it in
/// a module-global buffer for JS to read via accessors. `pathPointer` is valid
/// only for the duration of the call, so JS must copy out synchronously. For shots
/// `outcome` is 0/1/2 (out/hit/blocked) and `pathCount` is 2·points; placements and
/// obstacles use `outcome = 0`, `hitSeat = -1`, NaN impact, with the data in `path`.
@_extern(wasm, module: "gradgame", name: "gradGameEmitResult")
func gradGameEmitResult(
    _ outcome: Int32, _ hitSeat: Int32,
    _ impactX: Double, _ impactY: Double,
    _ pathPointer: UnsafePointer<Double>?, _ pathCount: Int32
)

/// Emit a plain f64 array (placements / obstacles) through `gradGameEmitResult`.
private func emitDoubles(_ values: [Double]) {
    values.withUnsafeBufferPointer { buffer in
        gradGameEmitResult(0, -1, .nan, .nan, buffer.baseAddress, Int32(buffer.count))
    }
}

/// Allocate `count` f64 slots, 8-aligned so JS `new Float64Array(mem, ptr, count)`
/// is valid. Used for the cannon/obstacle/position input buffers.
@_expose(wasm, "gradGameAllocF64")
@_cdecl("gradGameAllocF64")
public func gradGameAllocF64(_ count: Int32) -> UnsafeMutableRawPointer? {
    guard count > 0 else { return nil }
    return UnsafeMutableRawPointer.allocate(byteCount: Int(count) * 8, alignment: 8)
}

@_expose(wasm, "gradGameFreeF64")
@_cdecl("gradGameFreeF64")
public func gradGameFreeF64(_ pointer: UnsafeMutableRawPointer?, _ count: Int32) {
    pointer?.deallocate()
}

private func parseExprArgument(_ pointer: UnsafePointer<UInt8>?, _ length: Int32) -> Expression? {
    guard length > 0, let pointer else { return nil }
    let bytes = UnsafeBufferPointer(start: pointer, count: Int(length))
    let input = String(decoding: bytes, as: UTF8.self)
    return try? parseAndResolveExpression(input)
}

/// Populate the cannon archetype from the flat f64 buffer (3 f64/cannon, seat order;
/// 3rd f64 = alive flag). Spawning in order keeps column index == seat index, which
/// the engine relies on (shooterSeat / hitSeat are seat indices).
private func populateCannons(_ world: inout World, _ pointer: UnsafePointer<Double>?, _ count: Int32) {
    guard count > 0, let pointer else { return }
    let buffer = UnsafeBufferPointer(start: pointer, count: Int(count) * 3)
    var i = 0
    while i < Int(count) {
        world.spawnCannon(
            seat: i,
            x: buffer[i * 3], y: buffer[i * 3 + 1],
            alive: buffer[i * 3 + 2] != 0
        )
        i += 1
    }
}

/// Populate the obstacle archetype from the flat f64 buffer (3 f64/obstacle: x,y,r).
private func populateObstacles(_ world: inout World, _ pointer: UnsafePointer<Double>?, _ count: Int32) {
    guard count > 0, let pointer else { return }
    let buffer = UnsafeBufferPointer(start: pointer, count: Int(count) * 3)
    var i = 0
    while i < Int(count) {
        world.spawnObstacle(x: buffer[i * 3], y: buffer[i * 3 + 1], radius: buffer[i * 3 + 2])
        i += 1
    }
}

/// Simulate a shot. Returns the outcome (0=out, 1=hit, 2=blocked), or -1 if the
/// expression fails to parse / `f(0)` is non-finite. Pushes scalars + the flat path
/// back through `gradGameEmitResult`.
@_expose(wasm, "gradGameSimulateShot")
@_cdecl("gradGameSimulateShot")
public func gradGameSimulateShot(
    _ exprPointer: UnsafePointer<UInt8>?, _ exprLength: Int32,
    _ originX: Double, _ originY: Double, _ dir: Double, _ shooterSeat: Int32,
    _ cannonsPointer: UnsafePointer<Double>?, _ cannonCount: Int32,
    _ obstaclesPointer: UnsafePointer<Double>?, _ obstacleCount: Int32
) -> Int32 {
    guard let expression = parseExprArgument(exprPointer, exprLength) else {
        gradGameEmitResult(-1, -1, .nan, .nan, nil, 0)
        return -1
    }
    var world = World()
    populateCannons(&world, cannonsPointer, cannonCount)
    populateObstacles(&world, obstaclesPointer, obstacleCount)
    guard let shot = collisionSystem(
        &world, expression: expression,
        originX: originX, originY: originY, dir: dir,
        shooterSeat: Int(shooterSeat)
    ) else {
        gradGameEmitResult(-1, -1, .nan, .nan, nil, 0)
        return -1
    }

    let outcome = world.outcome(of: shot)
    let impact = world.impact(of: shot)
    world.trajectory(of: shot).points.withUnsafeBufferPointer { buffer in
        gradGameEmitResult(
            Int32(outcome.value), Int32(impact.seat),
            impact.x, impact.y,
            buffer.baseAddress, Int32(buffer.count)
        )
    }
    return Int32(outcome.value)
}

/// Rebuild a shot's polyline. Returns the point count (path has 2·points f64),
/// or -1 on parse / non-finite `f(0)`. `hasEndX == 0` sweeps to the field edge.
/// Emits the flat path through `gradGameEmitResult`.
@_expose(wasm, "gradGameResampleArc")
@_cdecl("gradGameResampleArc")
public func gradGameResampleArc(
    _ exprPointer: UnsafePointer<UInt8>?, _ exprLength: Int32,
    _ originX: Double, _ originY: Double, _ dir: Double,
    _ endX: Double, _ hasEndX: Int32
) -> Int32 {
    guard let expression = parseExprArgument(exprPointer, exprLength) else {
        gradGameEmitResult(-1, -1, .nan, .nan, nil, 0)
        return -1
    }
    var world = World()
    guard let shot = resampleSystem(
        &world, expression: expression,
        originX: originX, originY: originY, dir: dir,
        endX: hasEndX != 0 ? endX : nil
    ) else {
        gradGameEmitResult(-1, -1, .nan, .nan, nil, 0)
        return -1
    }
    let path = world.trajectory(of: shot).points
    emitDoubles(path)
    return Int32(path.count / 2)
}

@_expose(wasm, "gradGameAimDirection")
@_cdecl("gradGameAimDirection")
public func gradGameAimDirection(
    _ originX: Double, _ originY: Double, _ shooterSeat: Int32,
    _ cannonsPointer: UnsafePointer<Double>?, _ cannonCount: Int32
) -> Int32 {
    var world = World()
    populateCannons(&world, cannonsPointer, cannonCount)
    return Int32(aimSystem(world, originX: originX, originY: originY, shooterSeat: Int(shooterSeat)))
}

/// `occMask` bit j set ⇔ seat j is occupied. Emits 8 f64 (x,y per seat; NaN for
/// empty seats) through `gradGameEmitResult`; returns the count of placed seats.
@_expose(wasm, "gradGamePlacePlayers")
@_cdecl("gradGamePlacePlayers")
public func gradGamePlacePlayers(_ occMask: Int32, _ seed: Int32) -> Int32 {
    var occupied: [Int] = []
    var s = 0
    while s < kMaxSeats {
        if (Int(occMask) >> s) & 1 == 1 { occupied.append(s) }
        s += 1
    }
    emitDoubles(placePlayers(occupiedSeats: occupied, seed: Int(seed)))
    return Int32(occupied.count)
}

/// `positionsPointer` is the 8-f64 seat layout from gradGamePlacePlayers. Emits flat
/// [x,y,r,…] obstacles through `gradGameEmitResult`; returns the obstacle count.
@_expose(wasm, "gradGameGenerateObstacles")
@_cdecl("gradGameGenerateObstacles")
public func gradGameGenerateObstacles(_ positionsPointer: UnsafePointer<Double>?, _ seed: Int32) -> Int32 {
    var positions = [Double](repeating: .nan, count: 8)
    if let positionsPointer {
        let buffer = UnsafeBufferPointer(start: positionsPointer, count: 8)
        var i = 0
        while i < 8 { positions[i] = buffer[i]; i += 1 }
    }
    let obstacles = generateObstacles(positions: positions, seed: Int(seed))
    emitDoubles(obstacles)
    return Int32(obstacles.count / 3)
}

@_expose(wasm, "gradGameNextAliveSeat")
@_cdecl("gradGameNextAliveSeat")
public func gradGameNextAliveSeat(_ aliveMask: Int32, _ fromSeat: Int32) -> Int32 {
    Int32(nextAliveSeat(aliveMask: Int(aliveMask), fromSeat: Int(fromSeat)))
}

@_expose(wasm, "gradGameAliveCount")
@_cdecl("gradGameAliveCount")
public func gradGameAliveCount(_ aliveMask: Int32) -> Int32 {
    Int32(aliveCount(aliveMask: Int(aliveMask)))
}
#endif // arch(wasm32)
