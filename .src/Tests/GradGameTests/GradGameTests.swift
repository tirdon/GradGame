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
        // A radical braces its argument; log renders like the trig functions.
        ("sqrt(x)", "\\sqrt{x}"),
        ("sqrt x", "\\sqrt{x}"),
        ("sqrt(x + y)", "\\sqrt{x + y}"),
        ("log(x)", "\\log(x)"),
        ("log x", "\\log x"),
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
        ("x ^ 2 + x + x ^ 2", "x \\left(2 x + 1\\right)"),
        ("2 x + 3 x + 1", "5 x + 1"),
        ("x ^ 2 + x", "x \\left(x + 1\\right)"),
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
        ("sqrt(x)", "Math.sqrt(x)"),
        ("log(x)", "Math.log(x)"),
        // A multiplicative denominator is parenthesized so JS does not read
        // `1 / (2 x)` as the left-associative `(1 / 2) * x`.
        ("1 / (2 x)", "1 / (2 * x)"),
        ("1 / (x y)", "1 / (x * y)"),
    ]

    for (input, expected) in cases {
        #expect(try parseExpressionToJavaScript(input) == expected)
    }
}

@Test func parserDifferentiatesSymbolically() throws {
    // Each `dx`/`dy` node is replaced by the actual derivative (then simplified),
    // so the output is plain algebra rather than `\partial` notation.
    let cases = [
        ("dx(x^2 + y)", "2 x"),                          // power + sum (y is held constant)
        ("dy x", "0"),                                   // x is constant w.r.t. y
        ("dx x", "1"),
        ("dx(x^3)", "3 x^{2}"),
        ("dx(x^2)", "2 x"),
        ("dx(sin x)", "\\cos x"),
        ("dx(cos x)", "-\\sin x"),
        ("dx(e^x)", "e^{x}"),
        ("dx(x y)", "y"),                                // partial: ∂/∂x (x y) = y
        ("dy(x y)", "x"),
        ("dx(x^y)", "y x^{y - 1}"),                      // y is a constant exponent
        ("dx(sin(x^2))", "2 x \\cos(x^{2})"),            // chain rule
        ("dx(dx(x^3))", "6 x"),                          // higher-order
        ("dx(log x)", "\\frac{1}{x}"),                   // d/dx ln(x) = 1/x
        ("dx(sqrt x)", "\\frac{1}{2 \\sqrt{x}}"),        // d/dx √x = 1/(2√x)
    ]

    for (input, expected) in cases {
        #expect(try parseExpressionToTeX(input, simplify: true) == expected)
    }
}

@Test func parserRendersDifferentiatedJavaScript() throws {
    // A resolvable derivative becomes ordinary evaluable JS (no central difference).
    #expect(try parseExpressionToJavaScript("dx(x^2 + y)") == "2 * x")

    // A derivative that would need a logarithm (`2^x`) stays symbolic, so the JS
    // renderer falls back to a numeric central difference that still evaluates.
    let fallback = try parseExpressionToJavaScript("dx(2^x)")
    #expect(fallback.contains("=>"))
    #expect(fallback.contains("/ (2 * __gradGameH0)"))
}

@Test func rendersLargeNumbers() throws {
    // Numbers beyond Int32.max render in scientific notation (no overflow/crash).
    // Rendering is independent of simplify.
    let cases = [
        ("9999999999", "9.999999999 \\times 10^{9}"),
        ("3000000000", "3 \\times 10^{9}"),
        ("2147483647", "2147483647"),           // Int32.max: verbatim
        ("2147483648", "2.147483648 \\times 10^{9}"),
        ("12 + 3", "12 + 3"),                    // small numbers untouched
    ]

    for (input, expected) in cases {
        #expect(try parseExpressionToTeX(input) == expected)
    }

    // A product whose result exceeds Int32 folds into one scientific value
    // (mantissa × mantissa, exponent + exponent) rather than staying symbolic.
    #expect(try parseExpressionToTeX("100000 * 100000", simplify: true) == "1 \\times 10^{10}")
    // A lone large literal times 1 folds the 1 away and renders scientifically.
    #expect(try parseExpressionToTeX("3333333333 * 1", simplify: true) == "3.333333333 \\times 10^{9}")
}

@Test func parserRejectsScientificNotationInput() {
    // E-notation is no longer accepted; write the power of ten explicitly (`2 10^3`).
    expectParseFailure("2E3")
    expectParseFailure("1.5E-3")
    expectParseFailure("E")
    // The intended replacement parses and renders as a product.
    #expect(throws: Never.self) {
        _ = try parseExpressionToTeX("2 10^3")
    }
}

@Test func simplifierFoldsLargeNumbersScientifically() throws {
    // Products of large literals fold into one scientific value, with the mantissa
    // rounded to 15 significant figures. None of this traps on overflow.
    let cases = [
        // Two huge factors fold into a single 15-sig-fig value (exact product is
        // 23478248339673670237071080558745, rounded up at the 16th digit).
        ("135347859346579365 * 173465974659813", "2.34782483396737 \\times 10^{31}"),
        // 999999999^3 = 999999997000000002999999999, rounded to 15 sig figs.
        ("999999999 * 999999999 * 999999999", "9.99999997 \\times 10^{26}"),
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

@Test func simplifierFoldsSumsAndPowersScientifically() throws {
    // Sums/differences of numbers combine (aligning exponents), and integer powers
    // fold by repeated multiplication — all subject to the same scientific model.
    let cases = [
        ("3000000000 + 3000000000", "6 \\times 10^{9}"),
        ("2 10^30 + 3 10^30", "5 \\times 10^{30}"),
        ("10 ^ 20", "1 \\times 10^{20}"),
        ("2 ^ 10", "1024"),          // small power stays a plain integer
        ("2 ^ 3", "8"),
        ("2.5 * 2", "5"),            // decimals fold too
    ]

    for (input, expected) in cases {
        #expect(try parseExpressionToTeX(input, simplify: true) == expected)
    }
}

@Test func simplifierMergesRepeatedSumBasesIntoPowers() throws {
    // `(x+1)` and `(1+x)` canonicalize to the same base, so a repeated factor's
    // exponents merge into one power: (x+1)^2 (1+x) -> (x+1)^3 (a true identity,
    // since this is multiplication). Written with `+` it is a different, unequal
    // expression — (x+1)^2 + 1 + x = x^2+3x+2, not (x+1)^3 — and is left as such.
    let cube = "\\left(x + 1\\right)^{3}"
    #expect(try parseExpressionToTeX("(x+1)^2 (1+x)", simplify: true) == cube)
    #expect(try parseExpressionToTeX("(1+x)(x+1)^2", simplify: true) == cube)
    #expect(try parseExpressionToTeX("(x+1)(x+1)(x+1)", simplify: true) == cube)
    // The additive form is *not* the cube (x^2+3x+2, not x^3+3x+1); it factors by
    // the shared (x+1) into (x+1)(x+2), since the leftover 1 + x is itself (x+1).
    #expect(try parseExpressionToTeX("(x+1)^2 + 1+x", simplify: true) == "\\left(x + 1\\right) \\left(x + 2\\right)")
}

@Test func simplifierCollectsLikeTermsOverCompoundBases() throws {
    // Like-term collection treats a compound base like (x+1)^2 the same as a bare
    // variable: 1·(x+1)^2 + 2·(x+1)^2 -> 3 (x+1)^2 (a true identity).
    let square = "\\left(x + 1\\right)^{2}"
    #expect(try parseExpressionToTeX("(x+1)^2 + 2(x+1)^2", simplify: true) == "3 " + square)
    #expect(try parseExpressionToTeX("(x+1)^2 + 2 (1+x)^2", simplify: true) == "3 " + square)
    #expect(try parseExpressionToTeX("3(x+1)^2 - (x+1)^2", simplify: true) == "2 " + square)
}

@Test func simplifierFoldsRationalCoefficients() throws {
    // A numeric denominator becomes a reduced rational coefficient pulled to the
    // front (coefficient-first, never \frac{2 x}{3}); fractions multiply and add
    // exactly rather than turning into a rounded decimal.
    let cases = [
        ("x (2)/(3)", "\\frac{2}{3} x"),
        ("2 x / 3", "\\frac{2}{3} x"),
        ("4 x / 2", "2 x"),                       // reduces to an integer coefficient
        ("6 x / 4", "\\frac{3}{2} x"),
        ("x / 4", "\\frac{1}{4} x"),
        ("-2 x / 3", "\\frac{-2}{3} x"),          // the sign rides in the numerator
        ("2/3", "\\frac{2}{3}"),
        ("6/4", "\\frac{3}{2}"),
        ("(2)/(3) * (4)/(5)", "\\frac{8}{15}"),   // 2/3 · 4/5
        ("x/2 + x/3", "\\frac{5}{6} x"),          // like terms add as fractions
        ("(2/3)^2", "\\frac{4}{9}"),
        ("2^-1", "\\frac{1}{2}"),
        ("(x)/(y)", "\\frac{x}{y}"),              // a symbolic denominator stays a fraction
        ("10 / 2", "5"),                          // exact integer division still folds
    ]

    for (input, expected) in cases {
        #expect(try parseExpressionToTeX(input, simplify: true) == expected)
    }
}

@Test func simplifierFactorsCommonTerms() throws {
    // Common-factor-only factoring: a numeric and/or symbolic factor shared by
    // every term is pulled out of the sum.
    let monomial = [
        ("2 x + 2 y", "2 \\left(x + y\\right)"),
        ("x ^ 2 + x", "x \\left(x + 1\\right)"),
        ("4 x ^ 2 + 6 x", "2 x \\left(2 x + 3\\right)"),
        ("2 x + 4", "2 \\left(x + 2\\right)"),
        ("3 x + 6 y + 9", "3 \\left(x + 2 y + 3\\right)"),
    ]
    // A compound base (a sum like x+1) is pulled out even when it is not literally a
    // factor of every term, provided the leftover terms sum to a multiple of it.
    let compound = [
        ("(x+1)^2 + 1 + x", "\\left(x + 1\\right) \\left(x + 2\\right)"),
        ("(x+1)^2 + 2 + 2 x", "\\left(x + 1\\right) \\left(x + 3\\right)"),
        ("x (x+1) + (x+1)", "\\left(x + 1\\right)^{2}"),
        ("(x+y)^2 + x + y", "\\left(x + y\\right) \\left(x + y + 1\\right)"),
    ]
    // No shared factor: left expanded (this is not quadratic/general factoring).
    let unfactored = [
        ("x ^ 2 + 2 x + 1", "x^{2} + 2 x + 1"),
        ("5 x + 1", "5 x + 1"),
        ("x ^ 2 - 1", "x^{2} - 1"),
    ]

    for (input, expected) in monomial + compound + unfactored {
        #expect(try parseExpressionToTeX(input, simplify: true) == expected)
    }
}

@Test func simplifierRejectsNumbersTooLargeForFloat32() throws {
    // With simplify on, any value whose exponent exceeds 38 is rejected cleanly
    // (a thrown error, never a trap), so the page never folds an unrepresentable
    // number — whether folded from an operation or typed as a lone literal.
    let tooLarge = [
        "10 ^ 40",              // power
        "1 10^20 * 1 10^20",    // product -> 1e40
        "5 10^38 + 5 10^38",    // sum -> 1e39
        "3 10^40",              // a lone power of ten beyond the cap
    ]
    for input in tooLarge {
        #expect(throws: ExpressionParserError.numberTooLarge) {
            try parseExpressionToTeX(input, simplify: true)
        }
    }

    // The cap is simplify-only: without simplification the expression still renders.
    #expect(try parseExpressionToTeX("3 10^40") == "3 10^{40}")
}

@Test func simplifierUnderflowsTinyValuesToZero() throws {
    // A folded magnitude below 10^-39 (under float32's smallest normalized positive,
    // ~1.18e-38) collapses to exact zero rather than being kept or rejected.
    let cases = [
        ("10 ^ -40", "0"),
        ("10 ^ -50", "0"),
        ("1 / 10^20 * 1 / 10^20", "0"),  // 1e-40
        ("10^-50 x", "0"),               // a tiny coefficient zeroes the whole term
        ("1 + 10^-40", "1"),             // a tiny addend vanishes
    ]
    for (input, expected) in cases {
        #expect(try parseExpressionToTeX(input, simplify: true) == expected)
    }

    // 10^-39 itself is the boundary ("less than 10^-39"), so it is kept, not zeroed.
    #expect(try parseExpressionToTeX("10 ^ -39", simplify: true) == "\\frac{1}{1 \\times 10^{39}}")
}

@Test func simplifierHandlesDivisionByZero() throws {
    // A non-zero numerator over a literal zero is signed infinity (an internal
    // `\infty` constant the parser never emits); 0 / 0 is the indeterminate form.
    #expect(try parseExpressionToTeX("1 / 0", simplify: true) == "\\infty")
    #expect(try parseExpressionToTeX("-1 / 0", simplify: true) == "-\\infty")
    #expect(try parseExpressionToTeX("5 / (x - x)", simplify: true) == "\\infty")  // denominator folds to 0
    #expect(try parseExpressionToTeX("x / 0", simplify: true) == "\\infty")

    #expect(throws: ExpressionParserError.notANumber) {
        try parseExpressionToTeX("0 / 0", simplify: true)
    }

    // The JS form is a literal translation (not simplified); `1 / 0` evaluates to
    // Infinity and `0 / 0` to NaN at runtime, so both stay as written here.
    #expect(try parseExpressionToJavaScript("1 / 0") == "1 / 0")
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
    expectParseFailure("floor(x)")
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
