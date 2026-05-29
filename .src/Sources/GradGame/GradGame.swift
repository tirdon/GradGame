@main
struct GradGameMain {
    static func main() {
    }
}

@_expose(wasm, "add")
@_cdecl("add")
public func add(_ lhs: Int32, _ rhs: Int32) -> Int32 {
    lhs + rhs
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
