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

// simple test FFI
@_expose(wasm, "add")
@_cdecl("add")
public func test_add(_ lhs: Int32, _ rhs: Int32) -> Int32 {
    lhs + rhs
}

/// libm smoke test: exercises every transcendental the evaluator relies on so a
/// metadata/link trap surfaces here (a clean numeric return) rather than mid-game.
/// At x = 0 the exact value is sin0+cos0+exp0+log1+pow(0,2)+tanh0+sinh0+cosh0 = 3.
@_expose(wasm, "mathSmoke")
@_cdecl("mathSmoke")
public func mathSmoke(_ x: Double) -> Double {
    sin(x) + cos(x) + exp(0) + log(1) + pow(x, 2) + tanh(x) + sinh(0) + cosh(0)
}

nonisolated(unsafe) var lastResultPointer: UnsafeMutableRawPointer?
nonisolated(unsafe) var lastResultLength: Int32 = 0
nonisolated(unsafe) var lastParseSucceeded: Int32 = 0

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

func storeParserResult(_ value: String, succeeded: Bool) -> UnsafePointer<UInt8>? {
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
