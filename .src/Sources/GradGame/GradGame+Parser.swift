#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#endif

/// Parse `(ptr,len)` as an expression, resolve derivatives, and evaluate at
/// `(x, y)` — the raw `f(x, y)` (no f(0) normalization; the engine handles that).
/// Returns `.nan` on any parse error. Used for evaluator parity tests and as the
/// building block the trajectory exports evaluate per sample.
@_expose(wasm, "gradGameEvalAt")
@_cdecl("gradGameEvalAt")
public func gradGameEvalAt(_ inputPointer: UnsafePointer<UInt8>?, _ inputLength: Int32, _ x: Double, _ y: Double) -> Double {
    guard inputLength > 0, let inputPointer else { return .nan }
    let inputBytes = UnsafeBufferPointer(start: inputPointer, count: Int(inputLength))
    let input = String(decoding: inputBytes, as: UTF8.self)
    guard let expression = try? parseAndResolveExpression(input) else { return .nan }
    return expression.evaluate(x: x, y: y)
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
