// Platform math (libm) — see GradGame.swift / mathSmoke for the wasm verification.
#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#endif

extension Expression {
    /// Numerically evaluate the AST at `(x, y)`. Mirrors `JavaScriptRenderer`'s
    /// semantics exactly (constants, function set, `pow`-based powers, numeric
    /// central-difference derivative) so the native game engine matches the old
    /// `new Function()` pipeline bit-for-bit. Unsupported names or undefined
    /// results yield `.nan`/`.infinity` per IEEE — this never traps.
    ///
    /// wasm-safety: pure recursion + `switch`; no `Int*` interpolation, no
    /// `Sequence` for-in, no generic `Array` higher-order methods.
    func evaluate(x: Double, y: Double) -> Double {
        switch self {
        case let .number(text):
            return Expression.parseNumber(text)
        case let .variable(name):
            if name == "x" { return x }
            if name == "y" { return y }
            return .nan
        case let .constant(name):
            return Expression.constantValue(name)
        case let .unary(op, operand):
            let value = operand.evaluate(x: x, y: y)
            return op == .minus ? -value : value
        case let .binary(op, lhs, rhs):
            let l = lhs.evaluate(x: x, y: y)
            let r = rhs.evaluate(x: x, y: y)
            switch op {
            case .add: return l + r
            case .subtract: return l - r
            case .multiply, .implicitMultiply: return l * r
            case .divide: return l / r
            case .power: return pow(l, r)
            }
        case let .function(name, argument, exponent, _):
            let base = Expression.applyFunction(name, argument.evaluate(x: x, y: y))
            if let exponent {
                return pow(base, exponent.evaluate(x: x, y: y))
            }
            return base
        case let .derivative(variable, argument, _):
            // Central difference (h = 1e-5), matching JavaScriptRenderer.renderDerivative.
            // The symbolic Differentiator runs first and leaves only the rare
            // log-needing cases (e.g. 2^x) as `.derivative` nodes for this fallback.
            let h = 0.00001
            if variable == "x" {
                return (argument.evaluate(x: x + h, y: y) - argument.evaluate(x: x - h, y: y)) / (2 * h)
            }
            return (argument.evaluate(x: x, y: y + h) - argument.evaluate(x: x, y: y - h)) / (2 * h)
        }
    }

    /// Parse a lexer `.number` payload (plain digits with an optional decimal
    /// point — no E-notation; the lexer rejects it). A bare leading dot like
    /// `.5` is normalized so it parses the same as JavaScript's `Number(".5")`.
    private static func parseNumber(_ text: String) -> Double {
        if let value = Double(text) { return value }
        if text.first == "." { return Double("0" + text) ?? .nan }
        return .nan
    }

    private static func constantValue(_ name: String) -> Double {
        switch name {
        case "pi": return Double.pi
        case "e": return 2.718281828459045        // Math.E
        case "phi": return (1 + 5.0.squareRoot()) / 2
        case "gamma": return 0.5772156649015329
        case "infinity": return .infinity
        default: return .nan
        }
    }

    private static func applyFunction(_ name: String, _ a: Double) -> Double {
        switch name {
        case "sin": return sin(a)
        case "cos": return cos(a)
        case "tan": return tan(a)
        case "sinh": return sinh(a)
        case "cosh": return cosh(a)
        case "tanh": return tanh(a)
        case "exp": return exp(a)
        case "log": return log(a)            // natural log (matches Math.log)
        case "sqrt": return a.squareRoot()   // stdlib, not libm
        case "sec": return 1 / cos(a)
        case "csc": return 1 / sin(a)
        case "cot": return 1 / tan(a)
        default: return .nan
        }
    }
}
