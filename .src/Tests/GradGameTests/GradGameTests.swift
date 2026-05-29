import Testing
@testable import GradGame

@Test func addReturnsSum() {
    #expect(add(2, 3) == 5)
}

@Test func parserRendersReferenceExamples() throws {
    let cases = [
        ("sin x + 4", "\\sin x + 4"),
        ("sin x y + x ^ 2 + 3", "\\sin x y + x^{2} + 3"),
        ("cos(2 pi x)", "\\cos(2 \\pi x)"),
        ("x y ^ 2 + 3 x + 2 x ^ 3", "x y^{2} + 3 x + 2 x^{3}"),
        ("x^ (5 pi + 4) x", "x^{5 \\pi + 4} x"),
        ("e ^ x y + 7", "e^{x} y + 7"),
        ("(x)/(y)", "\\frac{x}{y}"),
        ("tan^2 x", "\\tan^{2} x"),
        ("tan^2 x y", "\\tan^{2} x y"),
        ("tan^2 (x y)", "\\tan^{2}(x y)"),
        ("3 tan x x y", "3 \\tan x x y"),
    ]

    for (input, expected) in cases {
        #expect(try parseExpressionToTeX(input) == expected)
    }
}

@Test func parserSupportsConfiguredFunctions() throws {
    let cases = [
        ("sec x + csc y + cot x", "\\sec x + \\csc y + \\cot x"),
        ("sinh x + cosh y + tanh x", "\\sinh x + \\cosh y + \\tanh x"),
        ("exp(x + y)", "\\exp(x + y)"),
        ("pow(x + y, 2)", "\\left(x + y\\right)^{2}"),
        ("dx(x^2 + y)", "\\frac{\\partial}{\\partial x}\\left(x^{2} + y\\right)"),
        ("dy x", "\\frac{\\partial}{\\partial y}\\left(x\\right)"),
    ]

    for (input, expected) in cases {
        #expect(try parseExpressionToTeX(input) == expected)
    }
}

@Test func parserSimplifiesExpressions() throws {
    let cases = [
        ("x + 0", "x"),
        ("0 + x", "x"),
        ("x - 0", "x"),
        ("x - x", "0"),
        ("x * 1", "x"),
        ("1 x", "x"),
        ("0 x", "0"),
        ("x ^ 1", "x"),
        ("x ^ 0", "1"),
        ("2 + 3", "5"),
        ("2 * 3", "6"),
        ("2 ^ 3", "8"),
        ("10 / 2", "5"),
        ("3 - 5", "-2"),
        ("2 + 3 + x", "x + 5"),
        ("(x + 0) * 1", "x"),
        ("x x", "x^{2}"),
        ("x x x", "x^{3}"),
        ("x ^ 2 x", "x^{3}"),
        ("x x ^ 2", "x^{3}"),
        ("x * x", "x^{2}"),
        ("(x + 1)(x + 1)", "\\left(x + 1\\right)^{2}"),
        ("sin x sin x", "\\sin^{2} x"),
        ("tan^2 x tan x", "\\tan^{3} x"),
        // Flattening n-ary products and collecting like factors.
        ("2 x x", "2 x^{2}"),
        ("2 x 3 x", "6 x^{2}"),
        ("x y x", "x^{2} y"),
        // Flattening n-ary sums and collecting like terms.
        ("x + x", "2 x"),
        ("3 x + 2 x", "5 x"),
        ("x - 2 x", "-x"),
        ("x y + y x", "2 x y"),
        ("x x + x x", "2 x^{2}"),
        ("x ^ 2 + x + x ^ 2", "2 x^{2} + x"),
        ("2 x + 3 x + 1", "5 x + 1"),
        ("x ^ 2 + x", "x^{2} + x"),
        // Canonical ordering places algebraic factors before functions.
        ("sin x y + x ^ 2 + 3", "y \\sin x + x^{2} + 3"),
    ]

    for (input, expected) in cases {
        #expect(try parseExpressionToTeX(input, simplify: true) == expected)
    }
}

@Test func parserDoesNotSimplifyWhenDisabled() throws {
    #expect(try parseExpressionToTeX("x + 0") == "x + 0")
    #expect(try parseExpressionToTeX("2 + 3") == "2 + 3")
}

@Test func parserSupportsNamedConstants() throws {
    #expect(try parseExpressionToTeX("phi + gamma + pi + e") == "\\phi + \\gamma + \\pi + e")
    #expect(try parseExpressionToJavaScript("phi + gamma + pi + e") == "((1 + Math.sqrt(5)) / 2) + 0.5772156649015329 + Math.PI + Math.E")
}

@Test func parserRendersJavaScriptExpressions() throws {
    let cases = [
        ("sin x y + x ^ 2 + 3", "Math.sin(x) * y + Math.pow(x, 2) + 3"),
        ("cos(2 pi x)", "Math.cos(2 * Math.PI * x)"),
        ("e ^ x y + 7", "Math.pow(Math.E, x) * y + 7"),
        ("(x)/(y)", "x / y"),
        ("tan^2 x", "Math.pow(Math.tan(x), 2)"),
        ("pow(x + y, 2)", "Math.pow(x + y, 2)"),
        ("sec x + csc y + cot x", "(1 / Math.cos(x)) + (1 / Math.sin(y)) + (1 / Math.tan(x))"),
    ]

    for (input, expected) in cases {
        #expect(try parseExpressionToJavaScript(input) == expected)
    }
}

@Test func parserRendersDerivativeAsEvaluableJavaScript() throws {
    let rendered = try parseExpressionToJavaScript("dx(x^2 + y)")

    #expect(rendered.contains("=>"))
    #expect(rendered.contains("Math.pow((x + __gradGameH0), 2) + y"))
    #expect(rendered.contains("Math.pow((x - __gradGameH0), 2) + y"))
    #expect(rendered.contains("/ (2 * __gradGameH0)"))
}

@Test func parserReportsInvalidInput() {
    expectParseFailure("")
    expectParseFailure("z + 1")
    expectParseFailure("log(x)")
    expectParseFailure("(x + y")
    expectParseFailure("x +")
    expectParseFailure("pow(x)")
    expectParseFailure("sin()")
}

private func expectParseFailure(_ input: String) {
    do {
        _ = try parseExpressionToTeX(input)
        Issue.record("Expected parse failure for '\(input)'")
    } catch {
    }
}
