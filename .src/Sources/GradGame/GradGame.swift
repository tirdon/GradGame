// Platform math (libm). Needed by the native expression evaluator + game engine
// (sin/cos/tan/exp/log/sinh/cosh/tanh/pow). Not used anywhere else in `.src`, so
// it is verified on the actual wasm via `mathSmoke` before anything depends on it
// (this SwiftWasm SDK can fail to resolve runtime metadata — see CLAUDE.md).
#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#endif

@main
struct GradGameMain {
    static func main() {
    }
}
// infinity must be thrown not constant
@_expose(wasm, "add")
@_cdecl("add")
public func test_add(_ lhs: Int32, _ rhs: Int32) -> Int32 {
    lhs + rhs
}

// The Graph War engine FFI is wasm-only: `graphEmitResult` is a host import that
// has no definition on the host (a Mach-O build can't link it). The pure engine in
// GameEngine.swift/Evaluator.swift stays available everywhere for host unit tests.
#if arch(wasm32)
/// Host callback (provided by gradgame-wasm.js in the `gradgame` import module):
/// the engine pushes a finished result back in one call instead of stashing it in
/// a module-global buffer for JS to read via accessors. `pathPointer` is valid
/// only for the duration of the call, so JS must copy out synchronously. For shots
/// `outcome` is 0/1/2 (out/hit/blocked) and `pathCount` is 2·points; placements and
/// obstacles use `outcome = 0`, `hitSeat = -1`, NaN impact, with the data in `path`.
@_extern(wasm, module: "gradgame", name: "graphEmitResult")
func graphEmitResult(
    _ outcome: Int32, _ hitSeat: Int32,
    _ impactX: Double, _ impactY: Double,
    _ pathPointer: UnsafePointer<Double>?, _ pathCount: Int32
)

/// Emit a plain f64 array (placements / obstacles) through `graphEmitResult`.
private func emitDoubles(_ values: [Double]) {
    values.withUnsafeBufferPointer { buffer in
        graphEmitResult(0, -1, .nan, .nan, buffer.baseAddress, Int32(buffer.count))
    }
}
#endif

/// libm smoke test: exercises every transcendental the evaluator relies on so a
/// metadata/link trap surfaces here (a clean numeric return) rather than mid-game.
/// At x = 0 the exact value is sin0+cos0+exp0+log1+pow(0,2)+tanh0+sinh0+cosh0 = 3.
@_expose(wasm, "mathSmoke")
@_cdecl("mathSmoke")
public func mathSmoke(_ x: Double) -> Double {
    sin(x) + cos(x) + exp(0) + log(1) + pow(x, 2) + tanh(x) + sinh(0) + cosh(0)
}

/// Parse `(ptr,len)` as an expression, resolve derivatives, and evaluate at
/// `(x, y)` — the raw `f(x, y)` (no f(0) normalization; the engine handles that).
/// Returns `.nan` on any parse error. Used for evaluator parity tests and as the
/// building block the trajectory exports evaluate per sample.
@_expose(wasm, "graphEvalAt")
@_cdecl("graphEvalAt")
public func graphEvalAt(_ inputPointer: UnsafePointer<UInt8>?, _ inputLength: Int32, _ x: Double, _ y: Double) -> Double {
    guard inputLength > 0, let inputPointer else { return .nan }
    let inputBytes = UnsafeBufferPointer(start: inputPointer, count: Int(inputLength))
    let input = String(decoding: inputBytes, as: UTF8.self)
    guard let expression = try? parseAndResolveExpression(input) else { return .nan }
    return expression.evaluate(x: x, y: y)
}

private nonisolated(unsafe) var lastResultPointer: UnsafeMutableRawPointer?
private nonisolated(unsafe) var lastResultLength: Int32 = 0
private nonisolated(unsafe) var lastParseSucceeded: Int32 = 0

@_expose(wasm, "gradGameAllocate")
@_cdecl("gradGameAllocate")
public func gradGameAllocate(_ byteCount: Int32) -> UnsafeMutableRawPointer? {
    guard byteCount > 0 else {
        return nil
    }

    return UnsafeMutableRawPointer.allocate(byteCount: Int(byteCount), alignment: 1)
}

@_expose(wasm, "gradGameDeallocate")
@_cdecl("gradGameDeallocate")
public func gradGameDeallocate(_ pointer: UnsafeMutableRawPointer?, _ byteCount: Int32) {
    pointer?.deallocate()
}

@_expose(wasm, "parseExpressionToTex")
@_cdecl("parseExpressionToTex")
public func parseExpressionToTex(_ inputPointer: UnsafePointer<UInt8>?, _ inputLength: Int32, _ simplify: Int32) -> UnsafePointer<UInt8>? {
    parseExpressionInput(inputPointer, inputLength) { input in
        try parseExpressionToTeX(input, simplify: simplify != 0)
    }
}

@_expose(wasm, "parseExpressionToJavaScript")
@_cdecl("parseExpressionToJavaScript")
public func parseExpressionToJavaScript(_ inputPointer: UnsafePointer<UInt8>?, _ inputLength: Int32) -> UnsafePointer<UInt8>? {
    parseExpressionInput(inputPointer, inputLength) { input in
        try parseExpressionToJavaScript(input)
    }
}

private func parseExpressionInput(
    _ inputPointer: UnsafePointer<UInt8>?,
    _ inputLength: Int32,
    _ parse: (String) throws -> String
) -> UnsafePointer<UInt8>? {
    guard inputLength >= 0 else {
        return storeParserResult("Input length must be non-negative.", succeeded: false)
    }

    let input: String
    if inputLength == 0 {
        input = ""
    } else if let inputPointer {
        let inputBytes = UnsafeBufferPointer(start: inputPointer, count: Int(inputLength))
        input = String(decoding: inputBytes, as: UTF8.self)
    } else {
        return storeParserResult("Input pointer is missing.", succeeded: false)
    }

    do {
        return storeParserResult(try parse(input), succeeded: true)
    } catch let error as ExpressionParserError {
        return storeParserResult(error.description, succeeded: false)
    } catch {
        return storeParserResult("Unable to parse expression.", succeeded: false)
    }
}

@_expose(wasm, "gradGameLastResultLength")
@_cdecl("gradGameLastResultLength")
public func gradGameLastResultLength() -> Int32 {
    lastResultLength
}

@_expose(wasm, "gradGameLastParseSucceeded")
@_cdecl("gradGameLastParseSucceeded")
public func gradGameLastParseSucceeded() -> Int32 {
    lastParseSucceeded
}

@_expose(wasm, "gradGameFreeLastResult")
@_cdecl("gradGameFreeLastResult")
public func gradGameFreeLastResult() {
    lastResultPointer?.deallocate()
    lastResultPointer = nil
    lastResultLength = 0
}

private func storeParserResult(_ value: String, succeeded: Bool) -> UnsafePointer<UInt8>? {
    gradGameFreeLastResult()

    let bytes = Array(value.utf8)
    lastResultLength = Int32(bytes.count)
    lastParseSucceeded = succeeded ? 1 : 0

    guard !bytes.isEmpty else {
        return nil
    }

    let pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
    bytes.withUnsafeBytes { source in
        if let baseAddress = source.baseAddress {
            pointer.copyMemory(from: baseAddress, byteCount: bytes.count)
        }
    }

    lastResultPointer = pointer
    return UnsafePointer(pointer.assumingMemoryBound(to: UInt8.self))
}

// ════════════════════════════════════════════════════════════════════════════
// Graph War engine FFI (wasm-only — see the #if arch(wasm32) note above)
//
// Inputs (cannons/obstacles/positions) cross JS→wasm through 8-aligned f64 buffers
// (`graphAllocF64`, so JS can write a `Float64Array` view). Outputs come back the
// other way through the `graphEmitResult` host callback — no result-buffer global,
// no accessor exports, no free dance on the JS side.
// ════════════════════════════════════════════════════════════════════════════
#if arch(wasm32)

/// Allocate `count` f64 slots, 8-aligned so JS `new Float64Array(mem, ptr, count)`
/// is valid. Used for the cannon/obstacle/position input buffers.
@_expose(wasm, "graphAllocF64")
@_cdecl("graphAllocF64")
public func graphAllocF64(_ count: Int32) -> UnsafeMutableRawPointer? {
    guard count > 0 else { return nil }
    return UnsafeMutableRawPointer.allocate(byteCount: Int(count) * 8, alignment: 8)
}

@_expose(wasm, "graphFreeF64")
@_cdecl("graphFreeF64")
public func graphFreeF64(_ pointer: UnsafeMutableRawPointer?, _ count: Int32) {
    pointer?.deallocate()
}

private func parseExprArgument(_ pointer: UnsafePointer<UInt8>?, _ length: Int32) -> Expression? {
    guard length > 0, let pointer else { return nil }
    let bytes = UnsafeBufferPointer(start: pointer, count: Int(length))
    let input = String(decoding: bytes, as: UTF8.self)
    return try? parseAndResolveExpression(input)
}

private func readCannons(_ pointer: UnsafePointer<Double>?, _ count: Int32) -> [Cannon] {
    var out: [Cannon] = []
    guard count > 0, let pointer else { return out }
    let buffer = UnsafeBufferPointer(start: pointer, count: Int(count) * 3)
    var i = 0
    while i < Int(count) {
        out.append(Cannon(x: buffer[i * 3], y: buffer[i * 3 + 1], alive: buffer[i * 3 + 2] != 0))
        i += 1
    }
    return out
}

private func readObstacles(_ pointer: UnsafePointer<Double>?, _ count: Int32) -> [Obstacle] {
    var out: [Obstacle] = []
    guard count > 0, let pointer else { return out }
    let buffer = UnsafeBufferPointer(start: pointer, count: Int(count) * 3)
    var i = 0
    while i < Int(count) {
        out.append(Obstacle(x: buffer[i * 3], y: buffer[i * 3 + 1], r: buffer[i * 3 + 2]))
        i += 1
    }
    return out
}

/// Simulate a shot. Returns the outcome (0=out, 1=hit, 2=blocked), or -1 if the
/// expression fails to parse / `f(0)` is non-finite. Pushes scalars + the flat path
/// back through `graphEmitResult`.
@_expose(wasm, "graphSimulateShot")
@_cdecl("graphSimulateShot")
public func graphSimulateShot(
    _ exprPointer: UnsafePointer<UInt8>?, _ exprLength: Int32,
    _ originX: Double, _ originY: Double, _ dir: Double, _ shooterSeat: Int32,
    _ cannonsPointer: UnsafePointer<Double>?, _ cannonCount: Int32,
    _ obstaclesPointer: UnsafePointer<Double>?, _ obstacleCount: Int32
) -> Int32 {
    guard let expression = parseExprArgument(exprPointer, exprLength) else {
        graphEmitResult(-1, -1, .nan, .nan, nil, 0)
        return -1
    }
    let cannons = readCannons(cannonsPointer, cannonCount)
    let obstacles = readObstacles(obstaclesPointer, obstacleCount)
    guard let result = simulateShot(
        expression: expression,
        originX: originX, originY: originY, dir: dir,
        shooterSeat: Int(shooterSeat), cannons: cannons, obstacles: obstacles
    ) else {
        graphEmitResult(-1, -1, .nan, .nan, nil, 0)
        return -1
    }

    result.path.withUnsafeBufferPointer { buffer in
        graphEmitResult(
            Int32(result.outcome), Int32(result.hitSeat),
            result.impactX, result.impactY,
            buffer.baseAddress, Int32(buffer.count)
        )
    }
    return Int32(result.outcome)
}

/// Rebuild a shot's polyline. Returns the point count (path has 2·points f64),
/// or -1 on parse / non-finite `f(0)`. `hasEndX == 0` sweeps to the field edge.
/// Emits the flat path through `graphEmitResult`.
@_expose(wasm, "graphResampleArc")
@_cdecl("graphResampleArc")
public func graphResampleArc(
    _ exprPointer: UnsafePointer<UInt8>?, _ exprLength: Int32,
    _ originX: Double, _ originY: Double, _ dir: Double,
    _ endX: Double, _ hasEndX: Int32
) -> Int32 {
    guard let expression = parseExprArgument(exprPointer, exprLength) else {
        graphEmitResult(-1, -1, .nan, .nan, nil, 0)
        return -1
    }
    guard let path = resampleArc(
        expression: expression,
        originX: originX, originY: originY, dir: dir,
        endX: hasEndX != 0 ? endX : nil
    ) else {
        graphEmitResult(-1, -1, .nan, .nan, nil, 0)
        return -1
    }
    emitDoubles(path)
    return Int32(path.count / 2)
}

@_expose(wasm, "graphAimDirection")
@_cdecl("graphAimDirection")
public func graphAimDirection(
    _ originX: Double, _ originY: Double, _ shooterSeat: Int32,
    _ cannonsPointer: UnsafePointer<Double>?, _ cannonCount: Int32
) -> Int32 {
    let cannons = readCannons(cannonsPointer, cannonCount)
    return Int32(aimDirection(originX: originX, originY: originY, shooterSeat: Int(shooterSeat), cannons: cannons))
}

/// `occMask` bit j set ⇔ seat j is occupied. Emits 8 f64 (x,y per seat; NaN for
/// empty seats) through `graphEmitResult`; returns the count of placed seats.
@_expose(wasm, "graphPlacePlayers")
@_cdecl("graphPlacePlayers")
public func graphPlacePlayers(_ occMask: Int32, _ seed: Int32) -> Int32 {
    var occupied: [Int] = []
    var s = 0
    while s < kMaxSeats {
        if (Int(occMask) >> s) & 1 == 1 { occupied.append(s) }
        s += 1
    }
    emitDoubles(placePlayers(occupiedSeats: occupied, seed: Int(seed)))
    return Int32(occupied.count)
}

/// `positionsPointer` is the 8-f64 seat layout from graphPlacePlayers. Emits flat
/// [x,y,r,…] obstacles through `graphEmitResult`; returns the obstacle count.
@_expose(wasm, "graphGenerateObstacles")
@_cdecl("graphGenerateObstacles")
public func graphGenerateObstacles(_ positionsPointer: UnsafePointer<Double>?, _ seed: Int32) -> Int32 {
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

@_expose(wasm, "graphNextAliveSeat")
@_cdecl("graphNextAliveSeat")
public func graphNextAliveSeat(_ aliveMask: Int32, _ fromSeat: Int32) -> Int32 {
    Int32(nextAliveSeat(aliveMask: Int(aliveMask), fromSeat: Int(fromSeat)))
}

@_expose(wasm, "graphAliveCount")
@_cdecl("graphAliveCount")
public func graphAliveCount(_ aliveMask: Int32) -> Int32 {
    Int32(aliveCount(aliveMask: Int(aliveMask)))
}

#endif // arch(wasm32)

// ── firebaseConfig (kept out of the HTML source; read from the binary at boot) ──

private let firebaseConfigJSON = """
{"apiKey":"AIzaSyBwl5fs3MEQh5_AIWVsc9rzfOUH70ypncw","authDomain":"webdata-26edf.firebaseapp.com","databaseURL":"https://webdata-26edf-default-rtdb.asia-southeast1.firebasedatabase.app","projectId":"webdata-26edf","storageBucket":"webdata-26edf.firebasestorage.app","messagingSenderId":"411882405034","appId":"1:411882405034:web:5e98982af98fb49ca024d3"}
"""

private nonisolated(unsafe) var firebaseConfigPointer: UnsafeMutableRawPointer?
private nonisolated(unsafe) var firebaseConfigByteCount: Int32 = 0

@_expose(wasm, "gradGameFirebaseConfig")
@_cdecl("gradGameFirebaseConfig")
public func gradGameFirebaseConfig() -> UnsafePointer<UInt8>? {
    if let firebaseConfigPointer {
        return UnsafePointer(firebaseConfigPointer.assumingMemoryBound(to: UInt8.self))
    }
    let bytes = Array(firebaseConfigJSON.utf8)
    firebaseConfigByteCount = Int32(bytes.count)
    guard !bytes.isEmpty else { return nil }
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
    bytes.withUnsafeBytes { source in
        if let baseAddress = source.baseAddress {
            pointer.copyMemory(from: baseAddress, byteCount: bytes.count)
        }
    }
    firebaseConfigPointer = pointer
    return UnsafePointer(pointer.assumingMemoryBound(to: UInt8.self))
}

@_expose(wasm, "gradGameFirebaseConfigLength")
@_cdecl("gradGameFirebaseConfigLength")
public func gradGameFirebaseConfigLength() -> Int32 {
    firebaseConfigByteCount
}
