/// Computes symbolic derivatives — the differentiation counterpart to `Simplifier`.
/// Where the `Simplifier` *canonicalizes* an expression, the `Differentiator`
/// *transforms* it: every `dx(...)` / `dy(...)` node is replaced by the actual
/// derivative of its argument, computed by the standard rules and then run back
/// through the `Simplifier` so the result comes out clean.
///
/// Those rules are exactly the core algebraic properties applied to d/dv — the same
/// properties the `Simplifier` is built on (commutative ordering, associative
/// flattening, distributive factoring):
///   • **Distributive / linearity:** `d(f ± g) = df ± dg` — the derivative distributes over a sum.
///   • **Commutative / associative (scalars):** constant factors ride along, `d(c·f) = c·df`.
///   • **Product rule:** `d(f·g) = df·g + f·dg`.
///   • **Quotient rule:** `d(f/g) = (df·g − f·dg) / g²`.
///   • **Power / chain rule:** `d(f^n) = n·f^(n−1)·df`, `d(e^u) = e^u·du`, `d(F(u)) = F'(u)·du`.
///
/// A partial derivative holds the *other* variable constant: `dx` treats `y` (and
/// every symbolic constant — e, pi, phi, gamma) as a constant whose derivative is 0,
/// and `dy` treats `x` likewise. The one rule that needs a logarithm — a non-`e`
/// constant base raised to a variable exponent (`2^x`), or a variable base with a
/// variable exponent (`x^x`) — is deliberately left symbolic: the TeX renderer shows
/// ∂-notation and the JavaScript renderer falls back to a numeric central difference.
///
/// **wasm-safety:** pure enum recursion with `Optional.map`; no `Array` higher-order
/// methods, no `Int32`/`UInt` interpolation, no `Sequence` for-in — every pattern
/// here is among the ones known to be safe on this SwiftWasm SDK (see
/// `swiftwasm-trapping-patterns`).
struct Differentiator {
    private let simplifier = Simplifier()

    /// Replaces every derivative node in the tree with its computed derivative
    /// (canonicalized), leaving the rest of the structure untouched so a
    /// derivative-free expression resolves to an identical tree.
    func resolve(_ expression: Expression) throws -> Expression {
        switch expression {
        case .number, .variable, .constant:
            return expression
        case let .unary(op, operand):
            return .unary(op, try resolve(operand))
        case let .binary(op, lhs, rhs):
            return .binary(op, try resolve(lhs), try resolve(rhs))
        case let .function(name, argument, exponent, parenthesized):
            return .function(
                name: name,
                argument: try resolve(argument),
                exponent: try exponent.map(resolve),
                parenthesized: parenthesized
            )
        case let .derivative(variable, argument, _):
            // Resolve nested derivatives first (higher-order: `dx(dx(...))`), then
            // differentiate and canonicalize the raw result.
            let inner = try resolve(argument)
            return try simplifier.simplify(differentiate(inner, withRespectTo: variable))
        }
    }

    /// `d/d variable` of `expression`. Pure: it builds a raw tree (with `0`/`1`
    /// literals and `n − 1` exponents) and leaves the cleanup to the `Simplifier`.
    /// Returns the original `.derivative` form for the few cases that need a logarithm.
    private func differentiate(_ expression: Expression, withRespectTo variable: String) -> Expression {
        switch expression {
        case .number, .constant:
            return .number("0")
        case let .variable(name):
            return name == variable ? .number("1") : .number("0")
        case let .unary(op, operand):
            return .unary(op, differentiate(operand, withRespectTo: variable))
        case let .binary(op, lhs, rhs):
            return differentiateBinary(op, lhs, rhs, withRespectTo: variable)
        case let .function(name, argument, exponent, parenthesized):
            if let exponent {
                // `F(u)^n`: differentiate as a power of the bare function.
                let base = Expression.function(name: name, argument: argument, exponent: nil, parenthesized: parenthesized)
                return differentiatePower(base: base, exponent: exponent, withRespectTo: variable)
            }
            guard let outer = functionDerivative(name: name, argument: argument) else {
                // Unreachable for parser output; stay symbolic with the right variable.
                return .derivative(variable: variable, argument: expression, parenthesized: true)
            }
            // Chain rule: `F'(u) · u'`.
            return product(outer, differentiate(argument, withRespectTo: variable))
        case .derivative:
            // An unresolved derivative (a logarithm-needing fallback) is opaque, so
            // its own derivative stays symbolic too.
            return .derivative(variable: variable, argument: expression, parenthesized: true)
        }
    }

    private func differentiateBinary(_ op: BinaryOperator, _ lhs: Expression, _ rhs: Expression, withRespectTo variable: String) -> Expression {
        switch op {
        case .add:
            return .binary(.add, differentiate(lhs, withRespectTo: variable), differentiate(rhs, withRespectTo: variable))
        case .subtract:
            return .binary(.subtract, differentiate(lhs, withRespectTo: variable), differentiate(rhs, withRespectTo: variable))
        case .multiply, .implicitMultiply:
            // Product rule: `l'·r + l·r'`.
            return .binary(
                .add,
                product(differentiate(lhs, withRespectTo: variable), rhs),
                product(lhs, differentiate(rhs, withRespectTo: variable))
            )
        case .divide:
            // Quotient rule: `(l'·r − l·r') / r²`.
            let numerator = Expression.binary(
                .subtract,
                product(differentiate(lhs, withRespectTo: variable), rhs),
                product(lhs, differentiate(rhs, withRespectTo: variable))
            )
            let denominator = Expression.binary(.power, rhs, .number("2"))
            return .binary(.divide, numerator, denominator)
        case .power:
            return differentiatePower(base: lhs, exponent: rhs, withRespectTo: variable)
        }
    }

    /// `d/dv` of `base^exponent`. The general power rule applies whenever the exponent
    /// is constant in `v` (covers `x^2`, `x^y`, `x^(2y+1)`); a base of `e` uses the
    /// exponential rule; anything else would need a logarithm, so it stays symbolic.
    private func differentiatePower(base: Expression, exponent: Expression, withRespectTo variable: String) -> Expression {
        let baseVaries = dependsOn(base, on: variable)
        let exponentVaries = dependsOn(exponent, on: variable)

        if !exponentVaries {
            if !baseVaries { return .number("0") }
            // `n · base^(n−1) · base'`
            let reducedExponent = Expression.binary(.subtract, exponent, .number("1"))
            let poweredDown = Expression.binary(.power, base, reducedExponent)
            return product(product(exponent, poweredDown), differentiate(base, withRespectTo: variable))
        }

        if !baseVaries, base == .constant("e") {
            // `d/dv e^u = e^u · u'`
            let original = Expression.binary(.power, base, exponent)
            return product(original, differentiate(exponent, withRespectTo: variable))
        }

        // A logarithm-requiring derivative (`2^x`, `x^x`): left symbolic by design.
        return .derivative(variable: variable, argument: .binary(.power, base, exponent), parenthesized: true)
    }

    /// The "outer" derivative `F'(u)` of a supported function, as a function of the
    /// same argument; the caller multiplies by `u'` for the chain rule. Returns nil
    /// for an unknown name (which the parser never produces).
    private func functionDerivative(name: String, argument: Expression) -> Expression? {
        switch name {
        case "sin":
            return makeFunction("cos", argument)
        case "cos":
            return .unary(.minus, makeFunction("sin", argument))
        case "tan":
            return functionSquared("sec", argument)                 // sec²u
        case "sec":
            return product(makeFunction("sec", argument), makeFunction("tan", argument))
        case "csc":
            return .unary(.minus, product(makeFunction("csc", argument), makeFunction("cot", argument)))
        case "cot":
            return .unary(.minus, functionSquared("csc", argument))  // −csc²u
        case "sinh":
            return makeFunction("cosh", argument)
        case "cosh":
            return makeFunction("sinh", argument)
        case "tanh":
            // sech²u = 1 − tanh²u (there is no `sech` in the grammar).
            return .binary(.subtract, .number("1"), functionSquared("tanh", argument))
        case "exp":
            return makeFunction("exp", argument)
        case "log":
            // d/du log(u) = 1/u (natural log, matching JS `Math.log`).
            return .binary(.divide, .number("1"), argument)
        case "sqrt":
            // d/du √u = 1 / (2 √u).
            return .binary(.divide, .number("1"), product(.number("2"), makeFunction("sqrt", argument)))
        default:
            return nil
        }
    }

    // MARK: Builders

    private func product(_ lhs: Expression, _ rhs: Expression) -> Expression {
        .binary(.implicitMultiply, lhs, rhs)
    }

    /// A bare function node, parenthesized unless its argument is a simple atom, so a
    /// compound argument never renders ambiguously (`\cos(x^2)`, not `\cos x^2`).
    private func makeFunction(_ name: String, _ argument: Expression) -> Expression {
        .function(name: name, argument: argument, exponent: nil, parenthesized: !isAtom(argument))
    }

    private func functionSquared(_ name: String, _ argument: Expression) -> Expression {
        .function(name: name, argument: argument, exponent: .number("2"), parenthesized: !isAtom(argument))
    }

    private func isAtom(_ expression: Expression) -> Bool {
        switch expression {
        case .number, .variable, .constant:
            return true
        default:
            return false
        }
    }

    /// Whether `expression` contains the differentiation `variable`, so the partial
    /// treats the other variable and every symbolic constant as constant.
    private func dependsOn(_ expression: Expression, on variable: String) -> Bool {
        switch expression {
        case let .variable(name):
            return name == variable
        case .number, .constant:
            return false
        case let .unary(_, operand):
            return dependsOn(operand, on: variable)
        case let .binary(_, lhs, rhs):
            return dependsOn(lhs, on: variable) || dependsOn(rhs, on: variable)
        case let .function(_, argument, exponent, _):
            if dependsOn(argument, on: variable) { return true }
            if let exponent { return dependsOn(exponent, on: variable) }
            return false
        case let .derivative(_, argument, _):
            return dependsOn(argument, on: variable)
        }
    }
}
