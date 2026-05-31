final class JavaScriptRenderer {
    private var derivativeIndex = 0

    func render(_ expression: Expression) -> String {
        render(expression, parentPrecedence: 0, position: .none)
    }

    private func render(_ expression: Expression, parentPrecedence: Int, position: RenderPosition) -> String {
        let rendered: String
        let precedence = expression.renderPrecedence

        switch expression {
        case let .number(value):
            rendered = value
        case let .variable(name):
            rendered = name
        case let .constant(name):
            rendered = renderConstant(name)
        case let .unary(operation, operand):
            let operandJavaScript = render(operand, parentPrecedence: precedence, position: .right)
            switch operation {
            case .plus:
                rendered = "+\(operandJavaScript)"
            case .minus:
                rendered = "-\(operandJavaScript)"
            }
        case let .binary(operation, lhs, rhs):
            rendered = renderBinary(operation, lhs, rhs)
        case let .function(name, argument, exponent, _):
            let functionCall = renderFunction(name: name, argument: argument)
            if let exponent {
                rendered = "Math.pow(\(functionCall), \(render(exponent, parentPrecedence: 0, position: .none)))"
            } else {
                rendered = functionCall
            }
        case let .derivative(variable, argument, _):
            rendered = renderDerivative(variable: variable, argument: argument)
        }

        if expression.needsParentheses(precedence: precedence, parentPrecedence: parentPrecedence, position: position) {
            return "(\(rendered))"
        }

        return rendered
    }

    private func renderBinary(_ operation: BinaryOperator, _ lhs: Expression, _ rhs: Expression) -> String {
        let precedence = operation.precedence

        switch operation {
        case .add:
            return "\(render(lhs, parentPrecedence: precedence, position: .left)) + \(render(rhs, parentPrecedence: precedence, position: .right))"
        case .subtract:
            return "\(render(lhs, parentPrecedence: precedence, position: .left)) - \(render(rhs, parentPrecedence: precedence, position: .right))"
        case .multiply, .implicitMultiply:
            return "\(render(lhs, parentPrecedence: precedence, position: .left)) * \(render(rhs, parentPrecedence: precedence, position: .right))"
        case .divide:
            // The denominator must bind tighter than `*` and `/`: `1 / (2 x)` is not
            // `1 / 2 * x` (which JS reads left-to-right as `(1/2) x`). Rendering it one
            // precedence level up wraps any multiplicative/additive denominator while
            // leaving an atom or a self-delimiting `Math.pow(...)` bare.
            let denominator = render(rhs, parentPrecedence: precedence + 1, position: .right)
            return "\(render(lhs, parentPrecedence: precedence, position: .left)) / \(denominator)"
        case .power:
            return "Math.pow(\(render(lhs, parentPrecedence: 0, position: .none)), \(render(rhs, parentPrecedence: 0, position: .none)))"
        }
    }

    private func renderConstant(_ name: String) -> String {
        switch name {
        case "pi":
            return "Math.PI"
        case "e":
            return "Math.E"
        case "phi":
            return "((1 + Math.sqrt(5)) / 2)"
        case "gamma":
            return "0.5772156649015329"
        default:
            return "NaN"
        }
    }

    private func renderFunction(name: String, argument: Expression) -> String {
        let argumentJavaScript = render(argument, parentPrecedence: 0, position: .none)

        switch name {
        case "sin", "cos", "tan", "sinh", "cosh", "tanh", "exp", "log", "sqrt":
            return "Math.\(name)(\(argumentJavaScript))"
        case "sec":
            return "(1 / Math.cos(\(argumentJavaScript)))"
        case "csc":
            return "(1 / Math.sin(\(argumentJavaScript)))"
        case "cot":
            return "(1 / Math.tan(\(argumentJavaScript)))"
        default:
            return "NaN"
        }
    }

    /// Numeric central difference, used only as a fallback for the rare derivative
    /// the symbolic `Differentiator` leaves unresolved (an exponential that would
    /// need a logarithm). The argument is evaluated inside an arrow whose `x`/`y`
    /// parameters shadow the outer variables, so the differentiation variable is
    /// perturbed by ±h without any `Dictionary`-based substitution (a non-empty
    /// Swift `Dictionary` traps on this SwiftWasm SDK — see swiftwasm-trapping-patterns).
    private func renderDerivative(variable: String, argument: Expression) -> String {
        let step = "__gradGameH\(derivativeIndex)"
        derivativeIndex += 1

        let body = render(argument, parentPrecedence: 0, position: .none)
        let evaluator = "((x, y) => (\(body)))"
        let plus = variable == "x" ? "\(evaluator)(x + \(step), y)" : "\(evaluator)(x, y + \(step))"
        let minus = variable == "x" ? "\(evaluator)(x - \(step), y)" : "\(evaluator)(x, y - \(step))"

        return "(((\(step)) => (\(plus) - \(minus)) / (2 * \(step)))(0.00001))"
    }

}
