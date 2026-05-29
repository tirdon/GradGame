import Testing
@testable import GradGame

@Test func addReturnsSum() {
    #expect(test_add(2, 3) == 5)
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

@Test func rendersLargeAndScientificNumbers() throws {
    // Numbers beyond Int32.max render in scientific notation (no overflow/crash);
    // typed E-notation renders the same way. Rendering is independent of simplify.
    let cases = [
        ("9999999999", "9.999999999 \\times 10^{9}"),
        ("3000000000", "3 \\times 10^{9}"),
        ("2147483647", "2147483647"),           // Int32.max: verbatim
        ("2147483648", "2.147483648 \\times 10^{9}"),
        ("3E6", "3 \\times 10^{6}"),
        ("1.5E-3", "1.5 \\times 10^{-3}"),
        ("3E0", "3"),
        ("12 + 3", "12 + 3"),                    // small numbers untouched
    ]

    for (input, expected) in cases {
        #expect(try parseExpressionToTeX(input) == expected)
    }

    // A product that overflows Int32 is left unfolded (no trap) rather than folded.
    #expect(try parseExpressionToTeX("100000 * 100000", simplify: true) == "100000 \\times 100000")
    // A lone large literal times 1 folds the 1 away and renders scientifically.
    #expect(try parseExpressionToTeX("3333333333 * 1", simplify: true) == "3.333333333 \\times 10^{9}")
    // E-notation survives simplification rather than being folded to a plain integer.
    #expect(try parseExpressionToTeX("3E6", simplify: true) == "3 \\times 10^{6}")
}

@Test func simplifierHandlesIntegerOverflowWithoutTrapping() throws {
    // Each literal fits in Int64, but the products/sums overflow it. Folding must
    // fall back to keeping the value symbolic rather than trapping on overflow.
    let cases = [
        // Two huge factors (beyond Int32): kept as a product, each shown scientifically.
        ("135347859346579365 * 173465974659813", "1.35347859346579365 \\times 10^{17} \\times 1.73465974659813 \\times 10^{14}"),
        // Factors within Int32 whose product overflows Int32 stay unfolded (no trap).
        ("999999999 * 999999999 * 999999999", "999999999 \\times 999999999 \\times 999999999"),
        // A lone large literal with an implicit ·1: the 1 folds away, scientific render.
        ("3333333333 1", "3.333333333 \\times 10^{9}"),
        // Small values still fold normally.
        ("2 x x", "2 x^{2}"),
        ("3 x + 2 x", "5 x"),
    ]

    for (input, expected) in cases {
        #expect(try parseExpressionToTeX(input, simplify: true) == expected)
    }
}

@Test func parserRejectsOverlyComplexInput() throws {
    // A long flat sum builds a deep tree; parsing/simplifying/rendering recurse
    // over it, so the parser must reject it cleanly rather than overflow the stack.
    var terms: [String] = []
    for _ in 0..<400 {
        terms.append("x")
    }
    let input = terms.joined(separator: " + ")

    #expect(throws: ExpressionParserError.expressionTooComplex) {
        try parseExpressionToTeX(input)
    }
    #expect(throws: ExpressionParserError.expressionTooComplex) {
        try parseExpressionToTeX(input, simplify: true)
    }

    // A realistic expression stays well under the cap and parses normally.
    #expect(try parseExpressionToTeX("sin x y + x ^ 2 + 3") == "\\sin x y + x^{2} + 3")
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
