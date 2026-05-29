/// Reduces an expression tree the way a computer algebra system would. Sums and
/// products are flattened into n-ary collections, like terms are collected
/// (`x x + x x -> 2 x^2`, `3 x + 2 x -> 5 x`), like factors are merged into powers
/// (`2 x x -> 2 x^2`, `sin x sin x -> sin^2 x`), constants are folded, and the
/// standard additive/multiplicative/power identities are applied.
///
/// Numeric constants fold through `DecimalValue` (mantissa × 10^exponent):
/// multiplication multiplies mantissas and adds exponents, addition aligns
/// exponents, and an integer power repeats multiplication. Any folded value whose
/// decimal exponent exceeds 38 (the float32 range) is rejected with
/// `ExpressionParserError.numberTooLarge`, so `simplify` is throwing.
struct Simplifier {
    /// Largest decimal exponent a folded value may have (float32's ~3.4e38 range).
    private static let maximumExponent = 38

    func simplify(_ expression: Expression) throws -> Expression {
        switch expression {
        case .number:
            // Reject a too-large literal even when it is not folded (e.g. a lone
            // `3E40`, or a literal inside an unfolded division). Display is left
            // untouched — the original expression is returned unchanged.
            if case let .number(text) = expression, let value = DecimalValue(literal: text) {
                try capExponent(value)
            }
            return expression
        case .variable, .constant:
            return expression
        case let .unary(op, operand):
            return simplifyUnary(op, try simplify(operand))
        case let .binary(op, _, _):
            switch op {
            case .add, .subtract:
                return try simplifySum(expression)
            case .multiply, .implicitMultiply:
                return try simplifyProduct(expression)
            case .divide, .power:
                return try simplifyBinary(expression)
            }
        case let .function(name, argument, exponent, parenthesized):
            return .function(
                name: name,
                argument: try simplify(argument),
                exponent: try exponent.map(simplify),
                parenthesized: parenthesized
            )
        case let .derivative(variable, argument, parenthesized):
            return .derivative(
                variable: variable,
                argument: try simplify(argument),
                parenthesized: parenthesized
            )
        }
    }

    /// Throws `.numberTooLarge` when a folded value is too big for float32 (decimal
    /// exponent > 38). Rounds first, so a value that rounds up into a higher
    /// exponent (`9.99…e38 -> 1e39`) is rejected too.
    private func capExponent(_ value: DecimalValue) throws {
        if value.isZero { return }
        if value.rounded().exponent > Simplifier.maximumExponent {
            throw ExpressionParserError.numberTooLarge
        }
    }

    private func simplifyUnary(_ op: UnaryOperator, _ operand: Expression) -> Expression {
        switch op {
        case .plus:
            return operand // +e -> e
        case .minus:
            if isZeroLiteral(operand) {
                return .number("0") // -0 -> 0
            }
            if case let .unary(.minus, inner) = operand {
                return inner // -(-e) -> e
            }
            return .unary(.minus, operand)
        }
    }

    private func simplifyBinary(_ expression: Expression) throws -> Expression {
        guard case let .binary(op, rawLeft, rawRight) = expression else { return expression }
        let lhs = try simplify(rawLeft)
        let rhs = try simplify(rawRight)

        switch op {
        case .divide:
            if isZeroLiteral(lhs) { return .number("0") } // 0 / e -> 0
            if isOneLiteral(rhs) { return lhs } // e / 1 -> e
            if lhs == rhs { return .number("1") } // e / e -> 1
            if let folded = foldDivision(lhs, rhs) { return folded }
            return .binary(.divide, lhs, rhs)
        case .power:
            if isZeroLiteral(rhs) { return .number("1") } // e^0 -> 1
            if isOneLiteral(rhs) { return lhs } // e^1 -> e
            if isOneLiteral(lhs) { return .number("1") } // 1^e -> 1
            if isZeroLiteral(lhs), isPositiveLiteral(rhs) { return .number("0") } // 0^positive -> 0
            if let folded = try foldPower(lhs, rhs) { return folded }
            return .binary(.power, lhs, rhs)
        case .add, .subtract, .multiply, .implicitMultiply:
            return expression // routed through simplifySum / simplifyProduct
        }
    }

    // MARK: Products

    /// Flattens an n-ary product, folds the numeric coefficient through
    /// `DecimalValue`, and collects like factors into powers.
    private func simplifyProduct(_ expression: Expression) throws -> Expression {
        var leaves: [Expression] = []
        flattenProduct(expression, into: &leaves)

        var factors: [Expression] = []
        var index = 0
        while index < leaves.count {
            flattenProduct(try simplify(leaves[index]), into: &factors)
            index += 1
        }

        return buildProduct(try ProductForm(factors, in: self))
    }

    private func flattenProduct(_ expression: Expression, into leaves: inout [Expression]) {
        if case let .binary(op, lhs, rhs) = expression, op == .multiply || op == .implicitMultiply {
            flattenProduct(lhs, into: &leaves)
            flattenProduct(rhs, into: &leaves)
        } else {
            leaves.append(expression)
        }
    }

    /// A product as a single folded numeric coefficient and `base^exponent` factors
    /// keyed by structural equality. Every numeric literal — integer, decimal,
    /// large, or E-notation — is multiplied into `numeric`.
    private struct ProductForm {
        var numeric: DecimalValue = .one
        var factors: [(base: Expression, exponent: Int)] = []

        init(_ leaves: [Expression], in simplifier: Simplifier) throws {
            var index = 0
            while index < leaves.count {
                let leaf = leaves[index]
                index += 1
                if let value = simplifier.numericValue(leaf) {
                    numeric = numeric.multiply(by: value)
                    try simplifier.capExponent(numeric)
                    continue
                }
                let (base, exponent) = simplifier.factorBaseExponent(leaf)
                var merged = false
                var cursor = 0
                while cursor < factors.count {
                    if factors[cursor].base == base {
                        // Power exponents are Int, so two ±Int32-range exponents can
                        // overflow when summed; on overflow keep the factor unmerged.
                        let (sum, overflow) = simplifier.addChecked(factors[cursor].exponent, exponent)
                        if !overflow {
                            factors[cursor].exponent = sum
                            merged = true
                        }
                        break
                    }
                    cursor += 1
                }
                if !merged {
                    factors.append((base, exponent))
                }
            }
        }
    }

    /// Splits a factor into a `base` and integer `exponent`. A function's exponent is
    /// lifted onto its node (`sin x -> base sin·, exponent 1`); a symbolic or
    /// non-integer exponent leaves the factor atomic.
    fileprivate func factorBaseExponent(_ expression: Expression) -> (base: Expression, exponent: Int) {
        if case let .binary(.power, base, exponentExpr) = expression,
           let exponent = integerLiteralValue(exponentExpr) {
            return (base, exponent)
        }
        if case let .function(name, argument, exponentExpr, parenthesized) = expression {
            let bare = Expression.function(name: name, argument: argument, exponent: nil, parenthesized: parenthesized)
            guard let exponentExpr else { return (bare, 1) }
            if let exponent = integerLiteralValue(exponentExpr) { return (bare, exponent) }
            return (expression, 1)
        }
        return (expression, 1)
    }

    private func buildProduct(_ form: ProductForm) -> Expression {
        if form.numeric.isZero { return .number("0") }

        var factors = form.factors
        sortFactorsByBase(&factors)

        var rest: [Expression] = []
        var factorIndex = 0
        while factorIndex < factors.count {
            let entry = factors[factorIndex]
            factorIndex += 1
            if entry.exponent == 0 { continue }
            rest.append(buildPower(base: entry.base, exponent: entry.exponent))
        }

        if rest.isEmpty {
            return numberExpression(form.numeric)
        }

        let restProduct = chainProduct(rest)
        if form.numeric.isOne {
            return restProduct
        }
        if form.numeric.isMinusOne {
            return simplifyUnary(.minus, restProduct)
        }
        let coefficient = Expression.number(form.numeric.literalString())
        let term = Expression.binary(.implicitMultiply, coefficient, restProduct)
        return form.numeric.negative ? .unary(.minus, term) : term
    }

    /// A `.number` for a folded value's magnitude, wrapping negatives in a unary
    /// minus so the renderer never sees a leading '-' inside a number string.
    private func numberExpression(_ value: DecimalValue) -> Expression {
        let literal = Expression.number(value.literalString())
        return value.negative ? .unary(.minus, literal) : literal
    }

    private func buildPower(base: Expression, exponent: Int) -> Expression {
        if exponent == 1 { return base }
        if case let .function(name, argument, _, parenthesized) = base {
            return .function(name: name, argument: argument, exponent: makeInteger(exponent), parenthesized: parenthesized)
        }
        return .binary(.power, base, makeInteger(exponent))
    }

    private func chainProduct(_ factors: [Expression]) -> Expression {
        var result = factors[0]
        var index = 1
        while index < factors.count {
            result = .binary(.implicitMultiply, result, factors[index])
            index += 1
        }
        return result
    }

    // MARK: Sums

    /// Flattens an n-ary sum/difference and collects like terms by their canonical
    /// non-numeric part, summing the `DecimalValue` coefficients.
    private func simplifySum(_ expression: Expression) throws -> Expression {
        var signedTerms: [(sign: Int, term: Expression)] = []
        flattenSum(expression, sign: 1, into: &signedTerms)

        var constant: DecimalValue = .zero
        var groups: [(rest: Expression, coefficient: DecimalValue)] = []

        var index = 0
        while index < signedTerms.count {
            let entry = signedTerms[index]
            index += 1
            let split = try splitCoefficient(try simplify(entry.term))
            let signed = entry.sign < 0 ? split.numeric.negated : split.numeric
            if split.rest == .number("1") {
                constant = constant.adding(signed)
                try capExponent(constant)
                continue
            }
            var merged = false
            var cursor = 0
            while cursor < groups.count {
                if groups[cursor].rest == split.rest {
                    groups[cursor].coefficient = groups[cursor].coefficient.adding(signed)
                    try capExponent(groups[cursor].coefficient)
                    merged = true
                    break
                }
                cursor += 1
            }
            if !merged {
                groups.append((split.rest, signed))
            }
        }

        var collected: [(rest: Expression, coefficient: DecimalValue)] = []
        var groupIndex = 0
        while groupIndex < groups.count {
            if !groups[groupIndex].coefficient.isZero {
                collected.append(groups[groupIndex])
            }
            groupIndex += 1
        }
        return buildSum(groups: collected, constant: constant)
    }

    private func flattenSum(_ expression: Expression, sign: Int, into terms: inout [(sign: Int, term: Expression)]) {
        switch expression {
        case let .binary(.add, lhs, rhs):
            flattenSum(lhs, sign: sign, into: &terms)
            flattenSum(rhs, sign: sign, into: &terms)
        case let .binary(.subtract, lhs, rhs):
            flattenSum(lhs, sign: sign, into: &terms)
            flattenSum(rhs, sign: -sign, into: &terms)
        case let .unary(.plus, operand):
            flattenSum(operand, sign: sign, into: &terms)
        case let .unary(.minus, operand):
            flattenSum(operand, sign: -sign, into: &terms)
        default:
            terms.append((sign, expression))
        }
    }

    /// Splits a simplified term into its `DecimalValue` coefficient and canonical
    /// remainder, so `3 x` becomes `(3, x)` and a bare constant becomes `(value, 1)`.
    private func splitCoefficient(_ expression: Expression) throws -> (numeric: DecimalValue, rest: Expression) {
        var leaves: [Expression] = []
        flattenProduct(expression, into: &leaves)
        var form = try ProductForm(leaves, in: self)
        if form.numeric.isZero { return (.zero, .number("1")) }
        let numeric = form.numeric
        form.numeric = .one
        return (numeric, buildProduct(form))
    }

    private func buildSum(groups: [(rest: Expression, coefficient: DecimalValue)], constant: DecimalValue) -> Expression {
        var terms: [(coefficient: DecimalValue, rest: Expression?)] = []
        var index = 0
        while index < groups.count {
            terms.append((groups[index].coefficient, groups[index].rest))
            index += 1
        }
        if !constant.isZero {
            terms.append((constant, nil))
        }
        if terms.isEmpty { return .number("0") }

        var result: Expression?
        var termIndex = 0
        while termIndex < terms.count {
            let term = terms[termIndex]
            termIndex += 1
            let magnitude = term.coefficient.magnitude
            let termExpression: Expression
            if let rest = term.rest {
                termExpression = buildTerm(magnitude: magnitude, rest: rest)
            } else {
                termExpression = .number(magnitude.literalString())
            }
            if let current = result {
                result = term.coefficient.negative
                    ? .binary(.subtract, current, termExpression)
                    : .binary(.add, current, termExpression)
            } else {
                result = term.coefficient.negative ? .unary(.minus, termExpression) : termExpression
            }
        }
        return result ?? .number("0")
    }

    private func buildTerm(magnitude: DecimalValue, rest: Expression) -> Expression {
        if magnitude.isOne { return rest }
        return .binary(.implicitMultiply, .number(magnitude.literalString()), rest)
    }

    // MARK: Numeric helpers

    /// The `DecimalValue` of an expression when it is a numeric literal (optionally
    /// signed), else nil. This is the fold entry point for every numeric leaf.
    private func numericValue(_ expression: Expression) -> DecimalValue? {
        switch expression {
        case let .number(text):
            return DecimalValue(literal: text)
        case let .unary(.minus, inner):
            return numericValue(inner)?.negated
        case let .unary(.plus, inner):
            return numericValue(inner)
        default:
            return nil
        }
    }

    /// The value of an expression when it is a numeric literal (optionally signed),
    /// else nil. Used only for the zero/one/sign identity checks and division.
    private func doubleValue(_ expression: Expression) -> Double? {
        switch expression {
        case let .number(text):
            return Double(text)
        case let .unary(.minus, inner):
            return doubleValue(inner).map { -$0 }
        case let .unary(.plus, inner):
            return doubleValue(inner)
        default:
            return nil
        }
    }

    /// The value of an expression when it is an integer-valued literal within
    /// ±Int32.max, else nil. Used to read small integer power exponents (so
    /// `x^2 · x^3 -> x^5` and `10^20` fold). The ±Int32.max bound keeps host
    /// (64-bit Int) and wasm32 (32-bit Int) in agreement and negation trap-free.
    private func integerLiteralValue(_ expression: Expression) -> Int? {
        switch expression {
        case let .number(text):
            if containsExponentMarker(text) { return nil }
            if let integer = Int(text), integer >= -2_147_483_647, integer <= 2_147_483_647 {
                return integer
            }
            if let value = Double(text), value == value.rounded(),
               value >= -2_147_483_647, value <= 2_147_483_647 {
                return Int(value)
            }
            return nil
        case let .unary(.minus, inner):
            return integerLiteralValue(inner).map { -$0 }
        case let .unary(.plus, inner):
            return integerLiteralValue(inner)
        default:
            return nil
        }
    }

    // Overflow-safe Int addition for power-exponent merging. The check uses a
    // Double magnitude compare rather than the stdlib reporting-overflow methods
    // (generic FixedWidthInteger machinery this SwiftWasm toolchain mis-resolves);
    // it is exact near ±Int32.max (well below 2^53) and the result wraps, never traps.
    private static let foldLimit = 2_147_483_647.0

    private func addChecked(_ a: Int, _ b: Int) -> (value: Int, overflow: Bool) {
        let sum = Double(a) + Double(b)
        if sum > Simplifier.foldLimit || sum < -Simplifier.foldLimit {
            return (0, true)
        }
        return (a &+ b, false)
    }

    private func containsExponentMarker(_ text: String) -> Bool {
        // Index a materialized byte array rather than iterating `text.utf8` with
        // for-in: that Sequence iteration traps on this SwiftWasm toolchain.
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            if bytes[index] == 69 || bytes[index] == 101 { return true } // 'E' or 'e'
            index += 1
        }
        return false
    }

    private func isZeroLiteral(_ expression: Expression) -> Bool {
        doubleValue(expression) == 0
    }

    private func isOneLiteral(_ expression: Expression) -> Bool {
        doubleValue(expression) == 1
    }

    private func isPositiveLiteral(_ expression: Expression) -> Bool {
        (doubleValue(expression) ?? 0) > 0
    }

    private func foldDivision(_ lhs: Expression, _ rhs: Expression) -> Expression? {
        guard let left = doubleValue(lhs), let right = doubleValue(rhs), right != 0 else { return nil }
        return integerExpression(left / right)
    }

    /// Folds `base^exponent` for a numeric base and a non-negative integer exponent
    /// (bounded so the repeated multiplication cannot run away), multiplying
    /// mantissas and adding exponents through `DecimalValue`. The cap rejects a
    /// result too large for float32.
    private func foldPower(_ lhs: Expression, _ rhs: Expression) throws -> Expression? {
        guard let base = numericValue(lhs),
              let exponent = integerLiteralValue(rhs),
              exponent >= 0, exponent <= 1024 else {
            return nil
        }
        let result = base.power(exponent)
        try capExponent(result)
        return numberExpression(result)
    }

    /// Only emits literals for integer-valued division results, so the renderer
    /// never shows floating-point artifacts such as `0.30000000000000004`.
    private func integerExpression(_ value: Double) -> Expression? {
        guard value.isFinite, value == value.rounded(),
              value >= -2_147_483_647, value <= 2_147_483_647 else {
            return nil // beyond ±Int32.max: leave the operation symbolic rather than fold
        }
        return makeInteger(Int(value))
    }

    private func makeInteger(_ value: Int) -> Expression {
        // value is bounded to ±Int32.max, so `-value` cannot overflow and we avoid
        // `.magnitude` (UInt), whose `Words` conformance this toolchain can't format.
        value < 0 ? .unary(.minus, .number("\(-value)")) : .number("\(value)")
    }

    /// A deterministic structural key used to order factors so that equal products
    /// always rebuild to the same canonical tree.
    private func sortKey(_ expression: Expression) -> String {
        switch expression {
        case let .number(value):
            return "0:" + value
        case let .constant(name):
            return "1:" + name
        case let .variable(name):
            return "2:" + name
        case let .unary(op, operand):
            return "3:" + unaryKey(op) + ":" + sortKey(operand)
        case let .binary(op, lhs, rhs):
            return "4:" + binaryKey(op) + ":" + sortKey(lhs) + "|" + sortKey(rhs)
        case let .function(name, argument, exponent, _):
            let exponentKey: String
            if let exponent {
                exponentKey = sortKey(exponent)
            } else {
                exponentKey = "_"
            }
            return "5:" + name + ":" + exponentKey + ":" + sortKey(argument)
        case let .derivative(variable, argument, _):
            return "6:" + variable + ":" + sortKey(argument)
        }
    }

    private func unaryKey(_ op: UnaryOperator) -> String {
        switch op {
        case .plus: return "+"
        case .minus: return "-"
        }
    }

    private func binaryKey(_ op: BinaryOperator) -> String {
        switch op {
        case .add: return "+"
        case .subtract: return "-"
        case .multiply: return "*"
        case .implicitMultiply: return "."
        case .divide: return "/"
        case .power: return "^"
        }
    }

    /// Insertion sort of collected factors by their base's `sortKey`, so that
    /// `x^2` and `y` order as `x^2 y` (by base) rather than by the built power node.
    /// Base keys are precomputed once and moved in lockstep with their factors,
    /// avoiding the generic `sorted(by:)` runtime path the Wasm target cannot
    /// resolve for `Array<Expression>`.
    private func sortFactorsByBase(_ array: inout [(base: Expression, exponent: Int)]) {
        var keys: [String] = []
        var k = 0
        while k < array.count {
            keys.append(sortKey(array[k].base))
            k += 1
        }

        var i = 1
        while i < array.count {
            let value = array[i]
            let key = keys[i]
            var j = i - 1
            while j >= 0, keys[j] > key {
                array[j + 1] = array[j]
                keys[j + 1] = keys[j]
                j -= 1
            }
            array[j + 1] = value
            keys[j + 1] = key
            i += 1
        }
    }
}
