/// Reduces an expression tree the way a computer algebra system would. Sums and
/// products are flattened into n-ary collections, like terms are collected
/// (`x x + x x -> 2 x^2`, `3 x + 2 x -> 5 x`), like factors are merged into powers
/// (`2 x x -> 2 x^2`, `sin x sin x -> sin^2 x`), constants are folded, and the
/// standard additive/multiplicative/power identities are applied.
struct Simplifier {
    func simplify(_ expression: Expression) -> Expression {
        switch expression {
        case .number, .variable, .constant:
            return expression
        case let .unary(op, operand):
            return simplifyUnary(op, simplify(operand))
        case let .binary(op, _, _):
            switch op {
            case .add, .subtract:
                return simplifySum(expression)
            case .multiply, .implicitMultiply:
                return simplifyProduct(expression)
            case .divide, .power:
                return simplifyBinary(expression)
            }
        case let .function(name, argument, exponent, parenthesized):
            return .function(
                name: name,
                argument: simplify(argument),
                exponent: exponent.map(simplify),
                parenthesized: parenthesized
            )
        case let .derivative(variable, argument, parenthesized):
            return .derivative(
                variable: variable,
                argument: simplify(argument),
                parenthesized: parenthesized
            )
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

    private func simplifyBinary(_ expression: Expression) -> Expression {
        guard case let .binary(op, rawLeft, rawRight) = expression else { return expression }
        let lhs = simplify(rawLeft)
        let rhs = simplify(rawRight)

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
            if let folded = foldPower(lhs, rhs) { return folded }
            return .binary(.power, lhs, rhs)
        case .add, .subtract, .multiply, .implicitMultiply:
            return expression // routed through simplifySum / simplifyProduct
        }
    }

    // MARK: Products

    /// Flattens an n-ary product, folds the numeric coefficient, and collects
    /// like factors into powers.
    private func simplifyProduct(_ expression: Expression) -> Expression {
        var leaves: [Expression] = []
        flattenProduct(expression, into: &leaves)

        var factors: [Expression] = []
        var index = 0
        while index < leaves.count {
            flattenProduct(simplify(leaves[index]), into: &factors)
            index += 1
        }

        return buildProduct(ProductForm(factors, in: self))
    }

    private func flattenProduct(_ expression: Expression, into leaves: inout [Expression]) {
        if case let .binary(op, lhs, rhs) = expression, op == .multiply || op == .implicitMultiply {
            flattenProduct(lhs, into: &leaves)
            flattenProduct(rhs, into: &leaves)
        } else {
            leaves.append(expression)
        }
    }

    /// A product as a signed integer coefficient, untouched non-integer numeric
    /// literals, and `base^exponent` factors keyed by structural equality.
    private struct ProductForm {
        var coefficient = 1
        var literals: [Expression] = []
        var factors: [(base: Expression, exponent: Int)] = []

        init(_ leaves: [Expression], in simplifier: Simplifier) {
            var index = 0
            while index < leaves.count {
                let leaf = leaves[index]
                index += 1
                if let value = simplifier.integerLiteralValue(leaf) {
                    coefficient *= value
                    continue
                }
                if case .number = leaf {
                    literals.append(leaf) // non-integer literal, kept verbatim
                    continue
                }
                let (base, exponent) = simplifier.factorBaseExponent(leaf)
                var merged = false
                var cursor = 0
                while cursor < factors.count {
                    if factors[cursor].base == base {
                        factors[cursor].exponent += exponent
                        merged = true
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
        if form.coefficient == 0 { return .number("0") }

        var literals = form.literals
        sortBySortKey(&literals)
        var factors = form.factors
        sortFactorsByBase(&factors)

        var rest: [Expression] = []
        var literalIndex = 0
        while literalIndex < literals.count {
            rest.append(literals[literalIndex])
            literalIndex += 1
        }
        var factorIndex = 0
        while factorIndex < factors.count {
            let entry = factors[factorIndex]
            factorIndex += 1
            if entry.exponent == 0 { continue }
            rest.append(buildPower(base: entry.base, exponent: entry.exponent))
        }

        if rest.isEmpty {
            return makeInteger(form.coefficient)
        }

        let restProduct = chainProduct(rest)
        switch form.coefficient {
        case 1:
            return restProduct
        case -1:
            return simplifyUnary(.minus, restProduct)
        default:
            return .binary(.implicitMultiply, makeInteger(form.coefficient), restProduct)
        }
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
    /// non-numeric part, summing the integer coefficients.
    private func simplifySum(_ expression: Expression) -> Expression {
        var signedTerms: [(sign: Int, term: Expression)] = []
        flattenSum(expression, sign: 1, into: &signedTerms)

        var constant = 0
        var groups: [(rest: Expression, coefficient: Int)] = []

        var index = 0
        while index < signedTerms.count {
            let entry = signedTerms[index]
            index += 1
            let split = splitCoefficient(simplify(entry.term))
            let signed = entry.sign * split.coefficient
            if split.rest == .number("1") {
                constant += signed
                continue
            }
            var merged = false
            var cursor = 0
            while cursor < groups.count {
                if groups[cursor].rest == split.rest {
                    groups[cursor].coefficient += signed
                    merged = true
                    break
                }
                cursor += 1
            }
            if !merged {
                groups.append((split.rest, signed))
            }
        }

        var collected: [(rest: Expression, coefficient: Int)] = []
        var groupIndex = 0
        while groupIndex < groups.count {
            if groups[groupIndex].coefficient != 0 {
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

    /// Splits a simplified term into its integer coefficient and canonical remainder,
    /// so `3 x` becomes `(3, x)` and a bare constant becomes `(value, 1)`.
    private func splitCoefficient(_ expression: Expression) -> (coefficient: Int, rest: Expression) {
        var leaves: [Expression] = []
        flattenProduct(expression, into: &leaves)
        var form = ProductForm(leaves, in: self)
        if form.coefficient == 0 { return (0, .number("1")) }
        let coefficient = form.coefficient
        form.coefficient = 1
        return (coefficient, buildProduct(form))
    }

    private func buildSum(groups: [(rest: Expression, coefficient: Int)], constant: Int) -> Expression {
        var terms: [(coefficient: Int, rest: Expression?)] = []
        var index = 0
        while index < groups.count {
            terms.append((groups[index].coefficient, groups[index].rest))
            index += 1
        }
        if constant != 0 {
            terms.append((constant, nil))
        }
        if terms.isEmpty { return .number("0") }

        var result: Expression?
        var termIndex = 0
        while termIndex < terms.count {
            let term = terms[termIndex]
            termIndex += 1
            let magnitude = abs(term.coefficient)
            let termExpression: Expression
            if let rest = term.rest {
                termExpression = buildTerm(magnitude: magnitude, rest: rest)
            } else {
                termExpression = .number("\(magnitude)")
            }
            if let current = result {
                result = term.coefficient < 0
                    ? .binary(.subtract, current, termExpression)
                    : .binary(.add, current, termExpression)
            } else {
                result = term.coefficient < 0 ? .unary(.minus, termExpression) : termExpression
            }
        }
        return result ?? .number("0")
    }

    private func buildTerm(magnitude: Int, rest: Expression) -> Expression {
        if magnitude == 1 { return rest }
        return .binary(.implicitMultiply, .number("\(magnitude)"), rest)
    }

    // MARK: Numeric helpers

    /// The value of an expression when it is a numeric literal (optionally signed), else `nil`.
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

    /// The value of an expression when it is an integer-valued numeric literal, else `nil`.
    fileprivate func integerLiteralValue(_ expression: Expression) -> Int? {
        switch expression {
        case let .number(text):
            if let integer = Int(text) { return integer }
            if let value = Double(text), value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
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

    private func foldPower(_ lhs: Expression, _ rhs: Expression) -> Expression? {
        guard let base = doubleValue(lhs), let exponent = doubleValue(rhs) else { return nil }
        // Fold only small, non-negative integer exponents to keep the result exact.
        guard exponent >= 0, exponent <= 64, exponent == exponent.rounded() else { return nil }
        var result = 1.0
        for _ in 0..<Int(exponent) {
            result *= base
        }
        return integerExpression(result)
    }

    /// Only emits literals for integer-valued results, so the renderer never shows
    /// floating-point artifacts such as `0.30000000000000004`.
    private func integerExpression(_ value: Double) -> Expression? {
        guard value.isFinite, value == value.rounded(), abs(value) < 9_007_199_254_740_992 else {
            return nil
        }
        return makeInteger(Int(value))
    }

    private func makeInteger(_ value: Int) -> Expression {
        value < 0 ? .unary(.minus, .number("\(-value)")) : .number("\(value)")
    }

    /// A deterministic structural key used to order factors and terms so that
    /// equal products/sums always rebuild to the same canonical tree.
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

    /// Insertion sort by `sortKey`. Avoids the generic `sorted(by:)` runtime path,
    /// which the Wasm target cannot resolve for `Array<Expression>`.
    private func sortBySortKey(_ array: inout [Expression]) {
        var i = 1
        while i < array.count {
            let value = array[i]
            let key = sortKey(value)
            var j = i - 1
            while j >= 0, sortKey(array[j]) > key {
                array[j + 1] = array[j]
                j -= 1
            }
            array[j + 1] = value
            i += 1
        }
    }

    /// Insertion sort of collected factors by their base's `sortKey`, so that
    /// `x^2` and `y` order as `x^2 y` (by base) rather than by the built power node.
    private func sortFactorsByBase(_ array: inout [(base: Expression, exponent: Int)]) {
        var i = 1
        while i < array.count {
            let value = array[i]
            let key = sortKey(value.base)
            var j = i - 1
            while j >= 0, sortKey(array[j].base) > key {
                array[j + 1] = array[j]
                j -= 1
            }
            array[j + 1] = value
            i += 1
        }
    }
}
