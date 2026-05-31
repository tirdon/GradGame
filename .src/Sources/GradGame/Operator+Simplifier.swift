/// Reduces an expression tree the way a computer algebra system would, applying the
/// core algebraic properties:
///   • **Commutative:** operands are reordered into a canonical order (parallel
///     `[String]` sort keys + insertion sort), so `x y` and `y x` collapse together.
///   • **Associative:** sums and products are flattened into n-ary collections, so
///     `(a + b) + c` and `a + (b + c)` are the same shape.
///   • **Distributive:** a factor shared by every term is pulled out
///     (`a b + a c -> a (b + c)`; common-factor factoring only, not general expansion).
/// On top of these, like terms are collected (`x x + x x -> 2 x^2`, `3 x + 2 x -> 5 x`),
/// like factors are merged into powers (`2 x x -> 2 x^2`, `sin x sin x -> sin^2 x`),
/// constants are folded, and the standard additive/multiplicative/power identities
/// are applied. (Differentiation is the separate `Differentiator` engine; it leans on
/// these same properties and feeds its result back through here.)
///
/// Numeric constants fold through `DecimalValue` (mantissa × 10^exponent):
/// multiplication multiplies mantissas and adds exponents, addition aligns
/// exponents, and an integer power repeats multiplication. Folded values are held
/// to float32's range: a magnitude whose decimal exponent exceeds 38 is rejected
/// with `ExpressionParserError.numberTooLarge` (so `simplify` is throwing), and a
/// magnitude below 10^-39 underflows to exact zero (smaller than float32's smallest
/// normalized positive value, ~1.18e-38). Division by a literal zero throws:
/// `.divisionByZero` for a non-zero numerator and `.notANumber` for the
/// indeterminate `0 / 0`.
struct Simplifier {
    /// Largest decimal exponent a folded magnitude may have (float32's ~3.4e38
    /// range); a value above this is rejected as too large.
    private static let maximumExponent = 38

    /// Smallest decimal exponent a folded magnitude may have: a value whose exponent
    /// is below this (magnitude under 10^-39) is smaller than float32's smallest
    /// normalized positive value (~1.18e-38) and underflows to exact zero.
    private static let minimumExponent = -39

    /// Where a folded magnitude falls relative to float32's representable range.
    private enum Magnitude {
        case normal
        case tooLarge
        case underflow
    }

    func simplify(_ expression: Expression) throws -> Expression {
        switch expression {
        case .number:
            // Bound a literal even when it is not folded (e.g. a lone `3E40`, or a
            // literal inside an unfolded division): too-large throws, too-small
            // collapses to 0. An in-range literal is returned untouched.
            if case let .number(text) = expression, let value = DecimalValue(literal: text) {
                switch classify(value) {
                case .tooLarge:
                    throw ExpressionParserError.numberTooLarge
                case .underflow:
                    return .number("0")
                case .normal:
                    break
                }
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

    /// Classifies a `DecimalValue` magnitude against float32's range. Rounds first,
    /// so a value that rounds up into a higher exponent (`9.99…e38 -> 1e39`) is
    /// rejected, and a value that rounds up out of underflow is kept.
    private func classify(_ value: DecimalValue) -> Magnitude {
        if value.isZero { return .normal }
        let exponent = value.rounded().exponent
        if exponent > Simplifier.maximumExponent { return .tooLarge }
        if exponent < Simplifier.minimumExponent { return .underflow }
        return .normal
    }

    /// Classifies a rational by its overall magnitude (`numeratorExp − denominatorExp`),
    /// not its parts: `1 / 10^40` underflows to zero even though its denominator alone
    /// would exceed the cap, while `10^40` (denominator 1) is genuinely too large.
    private func classify(_ value: Rational) -> Magnitude {
        if value.isZero { return .normal }
        let exponent = value.numerator.rounded().exponent - value.denominator.rounded().exponent
        if exponent > Simplifier.maximumExponent { return .tooLarge }
        if exponent < Simplifier.minimumExponent { return .underflow }
        return .normal
    }

    /// Throws `.numberTooLarge` on overflow and collapses an underflowing value to
    /// exact zero; otherwise returns the value unchanged. Used after every fold so a
    /// coefficient that grows past or shrinks below float32's range is handled before
    /// it is built back into an expression.
    private func capped(_ value: Rational) throws -> Rational {
        switch classify(value) {
        case .tooLarge:
            throw ExpressionParserError.numberTooLarge
        case .underflow:
            return .zero
        case .normal:
            return value
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
            // Division by a literal zero always throws: `0 / 0` is the indeterminate
            // form, and `c / 0` is infinite. Both are surfaced as errors rather than
            // an internal infinity value — that value used to be swallowed by the
            // `0 * e -> 0` product rule, so `1 / 0 * 0` wrongly folded to 0. Checked
            // before `0 / e -> 0` so `0 / 0` does not collapse to 0.
            if isZeroLiteral(rhs) {
                if isZeroLiteral(lhs) { throw ExpressionParserError.notANumber }
                throw ExpressionParserError.divisionByZero
            }
            if isZeroLiteral(lhs) { return .number("0") } // 0 / e -> 0
            if isOneLiteral(rhs) { return lhs } // e / 1 -> e
            if lhs == rhs { return .number("1") } // e / e -> 1
            if let folded = foldDivision(lhs, rhs) { return folded } // exact integer quotient
            // A numeric denominator becomes a reduced rational coefficient pulled to
            // the front: `2 x / 3 -> (2/3) x`, `6 x / 4 -> (3/2) x`, `2/3 · 4/5 -> 8/15`.
            // A symbolic denominator (`x / y`) is left as a fraction.
            if let denominator = rationalValue(rhs), !denominator.isZero {
                let (coefficient, rest) = try splitCoefficient(lhs)
                let combined = try capped(coefficient.divide(by: denominator))
                return buildRationalTimesRest(combined, rest)
            }
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
        var coefficient: Rational = .one
        var factors: [(base: Expression, exponent: Int)] = []

        init(_ leaves: [Expression], in simplifier: Simplifier) throws {
            var worklist = leaves
            var index = 0
            while index < worklist.count {
                let leaf = worklist[index]
                index += 1
                if let value = simplifier.rationalValue(leaf) {
                    coefficient = try simplifier.capped(coefficient.multiply(by: value))
                    continue
                }
                // A leading sign on a non-numeric factor (the canonical `-(2 x)`)
                // contributes -1 to the coefficient; re-flatten its inner product so
                // the `2` folds in and `x` stays a factor (`-2 x / 3 -> (-2/3) x`).
                if case let .unary(.minus, inner) = leaf {
                    coefficient = coefficient.negated
                    simplifier.flattenProduct(inner, into: &worklist)
                    continue
                }
                if case let .unary(.plus, inner) = leaf {
                    simplifier.flattenProduct(inner, into: &worklist)
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
        if form.coefficient.isZero { return .number("0") }

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
            return buildRational(form.coefficient)
        }
        return buildRationalTimesRest(form.coefficient, chainProduct(rest))
    }

    /// A `.number` for a folded value's magnitude, wrapping negatives in a unary
    /// minus so the renderer never sees a leading '-' inside a number string.
    private func numberExpression(_ value: DecimalValue) -> Expression {
        let literal = Expression.number(value.literalString())
        return value.negative ? .unary(.minus, literal) : literal
    }

    /// A standalone rational: an integer renders as a plain number, a proper
    /// fraction as `\frac{numerator}{denominator}` with the sign in the numerator
    /// (so `-2/3` is `\frac{-2}{3}`, never a wrapped `-\left(\frac{2}{3}\right)`).
    private func buildRational(_ value: Rational) -> Expression {
        if value.isZero { return .number("0") }
        if value.isInteger { return numberExpression(value.numerator) }
        let numerator = numberExpression(value.numerator)
        let denominator = Expression.number(value.denominator.literalString())
        return .binary(.divide, numerator, denominator)
    }

    /// A rational coefficient times a non-numeric remainder, coefficient-first:
    /// `2 -> 2 x`, `2/3 -> \frac{2}{3} x`, `-2/3 -> \frac{-2}{3} x`, `-1 -> -x`.
    private func buildRationalTimesRest(_ value: Rational, _ rest: Expression) -> Expression {
        if value.isZero { return .number("0") }
        if rest == .number("1") { return buildRational(value) }
        if value.isOne { return rest }
        if value.isMinusOne { return simplifyUnary(.minus, rest) }
        if value.isInteger {
            let coefficient = Expression.number(value.numerator.magnitude.literalString())
            let term = Expression.binary(.implicitMultiply, coefficient, rest)
            return value.negative ? .unary(.minus, term) : term
        }
        // Proper fraction: the fraction (sign included) leads the product.
        return .binary(.implicitMultiply, buildRational(value), rest)
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

        var constant: Rational = .zero
        var groups: [(rest: Expression, coefficient: Rational)] = []

        var index = 0
        while index < signedTerms.count {
            let entry = signedTerms[index]
            index += 1
            let split = try splitCoefficient(try simplify(entry.term))
            let signed = entry.sign < 0 ? split.coefficient.negated : split.coefficient
            if split.rest == .number("1") {
                constant = try capped(constant.adding(signed))
                continue
            }
            var merged = false
            var cursor = 0
            while cursor < groups.count {
                if groups[cursor].rest == split.rest {
                    groups[cursor].coefficient = try capped(groups[cursor].coefficient.adding(signed))
                    merged = true
                    break
                }
                cursor += 1
            }
            if !merged {
                groups.append((split.rest, signed))
            }
        }

        var collected: [(rest: Expression, coefficient: Rational)] = []
        var groupIndex = 0
        while groupIndex < groups.count {
            if !groups[groupIndex].coefficient.isZero {
                collected.append(groups[groupIndex])
            }
            groupIndex += 1
        }

        if let factored = try factorCommonTerms(collected, constant: constant) {
            return factored
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

    /// Splits a simplified term into its `Rational` coefficient and canonical
    /// remainder, so `3 x` becomes `(3, x)` and a bare constant becomes `(value, 1)`.
    private func splitCoefficient(_ expression: Expression) throws -> (coefficient: Rational, rest: Expression) {
        var leaves: [Expression] = []
        flattenProduct(expression, into: &leaves)
        var form = try ProductForm(leaves, in: self)
        if form.coefficient.isZero { return (.zero, .number("1")) }
        let coefficient = form.coefficient
        form.coefficient = .one
        return (coefficient, buildProduct(form))
    }

    private func buildSum(groups: [(rest: Expression, coefficient: Rational)], constant: Rational) -> Expression {
        var terms: [(coefficient: Rational, rest: Expression?)] = []
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
                termExpression = buildRationalTimesRest(magnitude, rest)
            } else {
                termExpression = buildRational(magnitude)
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

    // MARK: Factoring

    /// A collected sum term as an integer-or-rational coefficient and its symbolic
    /// factors (`2 x^2 -> coefficient 2, factors [(x, 2)]`). The constant bucket has
    /// an empty factor list.
    private typealias FactorTerm = (coefficient: Rational, factors: [(base: Expression, exponent: Int)])

    /// Pulls a single common factor out of a collected sum (common-factor-only
    /// factoring): `2 x + 2 y -> 2 (x + y)`, `x^2 + x -> x (x + 1)`,
    /// `4 x^2 + 6 x -> 2 x (2 x + 3)`. Returns nil when the terms share no factor
    /// (so the sum renders expanded as before).
    private func factorCommonTerms(_ groups: [(rest: Expression, coefficient: Rational)], constant: Rational) throws -> Expression? {
        // Only integer-coefficient sums are factored; a fractional coefficient
        // would make the common-factor arithmetic ambiguous, so leave it expanded.
        var terms: [FactorTerm] = []
        var index = 0
        while index < groups.count {
            if !groups[index].coefficient.isInteger { return nil }
            terms.append((groups[index].coefficient, factorList(of: groups[index].rest)))
            index += 1
        }
        if !constant.isZero {
            if !constant.isInteger { return nil }
            terms.append((constant, []))
        }
        if terms.count < 2 { return nil }

        if let factored = try factorMonomial(terms) { return factored }
        if let factored = try factorCompoundBase(terms) { return factored }
        return nil
    }

    /// Common-factor-only factoring across *all* terms: a numeric gcd and/or bases
    /// shared by every term. `2 x + 2 y -> 2 (x + y)`, `x^2 + x -> x (x + 1)`.
    private func factorMonomial(_ terms: [FactorTerm]) throws -> Expression? {
        let numericFactor = commonNumericFactor(terms)
        let commonFactors = commonSymbolicFactors(terms)
        if numericFactor <= 1 && commonFactors.isEmpty { return nil }

        let divisor = Rational.integer(numericFactor)
        var quotientTerms: [Expression] = []
        var t = 0
        while t < terms.count {
            let quotientCoefficient = numericFactor > 1 ? terms[t].coefficient.divide(by: divisor) : terms[t].coefficient
            var quotientFactors = terms[t].factors
            var c = 0
            while c < commonFactors.count {
                reduceExponent(&quotientFactors, base: commonFactors[c].base, by: commonFactors[c].exponent)
                c += 1
            }
            quotientTerms.append(buildTermFromFactors(coefficient: quotientCoefficient, factors: quotientFactors))
            t += 1
        }
        return try combineFactor(buildCommonFactor(numeric: numericFactor, factors: commonFactors), quotientTerms)
    }

    /// Pulls out a compound base `f` (a sum like `x + 1`) that divides the whole
    /// sum even though it is not literally a factor of every term: the terms that
    /// lack `f` must themselves sum to a multiple `c · f`. This is what turns
    /// `(x+1)^2 + 1 + x` into `(x+1)(x+2)` (here the leftover `1 + x` *is* `x + 1`).
    private func factorCompoundBase(_ terms: [FactorTerm]) throws -> Expression? {
        let candidates = compoundBaseCandidates(terms)
        var candidateIndex = 0
        while candidateIndex < candidates.count {
            let base = candidates[candidateIndex]
            candidateIndex += 1

            var withBase: [Int] = []
            var withoutBaseTerms: [Expression] = []
            var index = 0
            while index < terms.count {
                if let exponent = exponentOfBase(base, in: terms[index].factors), exponent >= 1 {
                    withBase.append(index)
                } else {
                    withoutBaseTerms.append(buildTermFromFactors(coefficient: terms[index].coefficient, factors: terms[index].factors))
                }
                index += 1
            }
            if withBase.isEmpty || withoutBaseTerms.isEmpty { continue }

            // The leftover terms must reduce to `coefficient · base`.
            let leftover = try simplify(chainSum(withoutBaseTerms))
            let split = try splitCoefficient(leftover)
            if split.rest != base { continue }

            var quotientTerms: [Expression] = []
            var k = 0
            while k < withBase.count {
                let term = terms[withBase[k]]
                var quotientFactors = term.factors
                reduceExponent(&quotientFactors, base: base, by: 1)
                quotientTerms.append(buildTermFromFactors(coefficient: term.coefficient, factors: quotientFactors))
                k += 1
            }
            quotientTerms.append(buildRational(split.coefficient))
            return try combineFactor(base, quotientTerms)
        }
        return nil
    }

    /// Builds `common · (sum of quotient terms)` and re-runs product simplification
    /// so equal factors merge into a power (`(x+1)(x+1) -> (x+1)^2`).
    private func combineFactor(_ common: Expression, _ quotientTerms: [Expression]) throws -> Expression {
        let inner = try simplify(chainSum(quotientTerms))
        return try simplifyProduct(.binary(.implicitMultiply, common, inner))
    }

    /// Distinct sum-valued factor bases (e.g. `x + 1`) appearing in any term, in
    /// order of first appearance — the candidate compound factors.
    private func compoundBaseCandidates(_ terms: [FactorTerm]) -> [Expression] {
        var result: [Expression] = []
        var termIndex = 0
        while termIndex < terms.count {
            var factorIndex = 0
            while factorIndex < terms[termIndex].factors.count {
                let base = terms[termIndex].factors[factorIndex].base
                factorIndex += 1
                if !isSumBase(base) { continue }
                var seen = false
                var r = 0
                while r < result.count {
                    if result[r] == base { seen = true; break }
                    r += 1
                }
                if !seen { result.append(base) }
            }
            termIndex += 1
        }
        return result
    }

    private func isSumBase(_ expression: Expression) -> Bool {
        if case let .binary(operation, _, _) = expression {
            return operation == .add || operation == .subtract
        }
        return false
    }

    /// The gcd of every term's integer coefficient magnitude (1 if any coefficient
    /// is too large to read as a small `Int`, so no numeric factor is pulled).
    private func commonNumericFactor(_ terms: [FactorTerm]) -> Int {
        var result = 0
        var index = 0
        while index < terms.count {
            guard let value = terms[index].coefficient.numerator.magnitude.smallInteger else { return 1 }
            result = integerGCD(result, value)
            index += 1
        }
        return result == 0 ? 1 : result
    }

    /// Bases present in *every* term, each at its minimum exponent — the symbolic
    /// part of the common factor.
    private func commonSymbolicFactors(_ terms: [FactorTerm]) -> [(base: Expression, exponent: Int)] {
        var common: [(base: Expression, exponent: Int)] = []
        let first = terms[0].factors
        var candidate = 0
        while candidate < first.count {
            let base = first[candidate].base
            var minimum = first[candidate].exponent
            candidate += 1
            var inAll = true
            var t = 1
            while t < terms.count {
                if let exponent = exponentOfBase(base, in: terms[t].factors) {
                    if exponent < minimum { minimum = exponent }
                } else {
                    inAll = false
                    break
                }
                t += 1
            }
            if inAll && minimum >= 1 {
                common.append((base, minimum))
            }
        }
        return common
    }

    private func buildCommonFactor(numeric: Int, factors: [(base: Expression, exponent: Int)]) -> Expression {
        var parts: [Expression] = []
        if numeric > 1 {
            parts.append(makeInteger(numeric))
        }
        var sorted = factors
        sortFactorsByBase(&sorted)
        var index = 0
        while index < sorted.count {
            parts.append(buildPower(base: sorted[index].base, exponent: sorted[index].exponent))
            index += 1
        }
        return chainProduct(parts)
    }

    private func buildTermFromFactors(coefficient: Rational, factors: [(base: Expression, exponent: Int)]) -> Expression {
        var sorted = factors
        sortFactorsByBase(&sorted)
        var rest: [Expression] = []
        var index = 0
        while index < sorted.count {
            if sorted[index].exponent != 0 {
                rest.append(buildPower(base: sorted[index].base, exponent: sorted[index].exponent))
            }
            index += 1
        }
        if rest.isEmpty {
            return buildRational(coefficient)
        }
        return buildRationalTimesRest(coefficient, chainProduct(rest))
    }

    /// Decomposes a canonical product into `base^exponent` factors (the inverse of
    /// `buildProduct`'s factor handling), used to compare terms for a common factor.
    private func factorList(of expression: Expression) -> [(base: Expression, exponent: Int)] {
        var leaves: [Expression] = []
        flattenProduct(expression, into: &leaves)
        var result: [(base: Expression, exponent: Int)] = []
        var index = 0
        while index < leaves.count {
            let (base, exponent) = factorBaseExponent(leaves[index])
            index += 1
            var merged = false
            var cursor = 0
            while cursor < result.count {
                if result[cursor].base == base {
                    result[cursor].exponent += exponent
                    merged = true
                    break
                }
                cursor += 1
            }
            if !merged {
                result.append((base, exponent))
            }
        }
        return result
    }

    private func exponentOfBase(_ base: Expression, in list: [(base: Expression, exponent: Int)]) -> Int? {
        var index = 0
        while index < list.count {
            if list[index].base == base { return list[index].exponent }
            index += 1
        }
        return nil
    }

    private func reduceExponent(_ list: inout [(base: Expression, exponent: Int)], base: Expression, by amount: Int) {
        var index = 0
        while index < list.count {
            if list[index].base == base {
                list[index].exponent -= amount
                return
            }
            index += 1
        }
    }

    private func chainSum(_ terms: [Expression]) -> Expression {
        var result = terms[0]
        var index = 1
        while index < terms.count {
            result = .binary(.add, result, terms[index])
            index += 1
        }
        return result
    }

    // MARK: Numeric helpers

    /// The exact `Rational` of an expression built only from numeric literals and
    /// `+ - * / ^` (no variables, constants, or functions), else nil. This is the
    /// fold entry point for every numeric leaf and folds whole numeric fractions —
    /// `2/3`, `2/3 · 4/5`, `(2/3)^2` — into one reduced coefficient.
    private func rationalValue(_ expression: Expression) -> Rational? {
        switch expression {
        case let .number(text):
            guard let value = DecimalValue(literal: text) else { return nil }
            return Rational.make(numerator: value, denominator: .one)
        case let .unary(.minus, inner):
            return rationalValue(inner)?.negated
        case let .unary(.plus, inner):
            return rationalValue(inner)
        case let .binary(.multiply, lhs, rhs), let .binary(.implicitMultiply, lhs, rhs):
            guard let left = rationalValue(lhs), let right = rationalValue(rhs) else { return nil }
            return left.multiply(by: right)
        case let .binary(.divide, lhs, rhs):
            guard let left = rationalValue(lhs), let right = rationalValue(rhs), !right.isZero else { return nil }
            return left.divide(by: right)
        case let .binary(.add, lhs, rhs):
            guard let left = rationalValue(lhs), let right = rationalValue(rhs) else { return nil }
            return left.adding(right)
        case let .binary(.subtract, lhs, rhs):
            guard let left = rationalValue(lhs), let right = rationalValue(rhs) else { return nil }
            return left.adding(right.negated)
        case let .binary(.power, lhs, rhs):
            guard let left = rationalValue(lhs), let exponent = integerLiteralValue(rhs),
                  exponent >= -1024, exponent <= 1024 else { return nil }
            if left.isZero && exponent < 0 { return nil }
            return left.power(exponent)
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
        guard let base = rationalValue(lhs),
              let exponent = integerLiteralValue(rhs),
              exponent >= -1024, exponent <= 1024 else {
            return nil
        }
        if base.isZero && exponent < 0 { return nil } // 0^negative is undefined: leave symbolic
        let result = try capped(base.power(exponent))
        return buildRational(result)
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
