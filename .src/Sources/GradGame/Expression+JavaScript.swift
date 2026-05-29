final class JavaScriptRenderer {
    private var derivativeIndex = 0

    func render(_ expression: Expression) -> String {
        render(expression, parentPrecedence: 0, position: .none, variableOverrides: [:])
    }

    private enum Position {
        case none
        case left
        case right
    }

    private func render(
        _ expression: Expression,
        parentPrecedence: Int,
        position: Position,
        variableOverrides: [String: String]
    ) -> String {
        let rendered: String
        let precedence = self.precedence(of: expression)

        switch expression {
        case let .number(value):
            rendered = value
        case let .variable(name):
            rendered = variableOverrides[name] ?? name
        case let .constant(name):
            rendered = renderConstant(name)
        case let .unary(operation, operand):
            let operandJavaScript = render(
                operand,
                parentPrecedence: precedence,
                position: .right,
                variableOverrides: variableOverrides
            )
            switch operation {
            case .plus:
                rendered = "+\(operandJavaScript)"
            case .minus:
                rendered = "-\(operandJavaScript)"
            }
        case let .binary(operation, lhs, rhs):
            rendered = renderBinary(operation, lhs, rhs, variableOverrides: variableOverrides)
        case let .function(name, argument, exponent, _):
            let functionCall = renderFunction(name: name, argument: argument, variableOverrides: variableOverrides)
            if let exponent {
                rendered = "Math.pow(\(functionCall), \(render(exponent, parentPrecedence: 0, position: .none, variableOverrides: variableOverrides)))"
            } else {
                rendered = functionCall
            }
        case let .derivative(variable, argument, _):
            rendered = renderDerivative(variable: variable, argument: argument, variableOverrides: variableOverrides)
        }

        if shouldWrap(expression, precedence: precedence, parentPrecedence: parentPrecedence, position: position) {
            return "(\(rendered))"
        }

        return rendered
    }

    private func renderBinary(
        _ operation: BinaryOperator,
        _ lhs: Expression,
        _ rhs: Expression,
        variableOverrides: [String: String]
    ) -> String {
        let precedence = precedence(of: .binary(operation, lhs, rhs))

        switch operation {
        case .add:
            return "\(render(lhs, parentPrecedence: precedence, position: .left, variableOverrides: variableOverrides)) + \(render(rhs, parentPrecedence: precedence, position: .right, variableOverrides: variableOverrides))"
        case .subtract:
            return "\(render(lhs, parentPrecedence: precedence, position: .left, variableOverrides: variableOverrides)) - \(render(rhs, parentPrecedence: precedence, position: .right, variableOverrides: variableOverrides))"
        case .multiply, .implicitMultiply:
            return "\(render(lhs, parentPrecedence: precedence, position: .left, variableOverrides: variableOverrides)) * \(render(rhs, parentPrecedence: precedence, position: .right, variableOverrides: variableOverrides))"
        case .divide:
            return "\(render(lhs, parentPrecedence: precedence, position: .left, variableOverrides: variableOverrides)) / \(render(rhs, parentPrecedence: precedence, position: .right, variableOverrides: variableOverrides))"
        case .power:
            return "Math.pow(\(render(lhs, parentPrecedence: 0, position: .none, variableOverrides: variableOverrides)), \(render(rhs, parentPrecedence: 0, position: .none, variableOverrides: variableOverrides)))"
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

    private func renderFunction(
        name: String,
        argument: Expression,
        variableOverrides: [String: String]
    ) -> String {
        let argumentJavaScript = render(argument, parentPrecedence: 0, position: .none, variableOverrides: variableOverrides)

        switch name {
        case "sin", "cos", "tan", "sinh", "cosh", "tanh", "exp":
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

    private func renderDerivative(
        variable: String,
        argument: Expression,
        variableOverrides: [String: String]
    ) -> String {
        let hName = "__gradGameH\(derivativeIndex)"
        derivativeIndex += 1

        let baseValue = variableOverrides[variable] ?? variable
        var positiveOverrides = variableOverrides
        positiveOverrides[variable] = "(\(baseValue) + \(hName))"

        var negativeOverrides = variableOverrides
        negativeOverrides[variable] = "(\(baseValue) - \(hName))"

        let positive = render(argument, parentPrecedence: 0, position: .none, variableOverrides: positiveOverrides)
        let negative = render(argument, parentPrecedence: 0, position: .none, variableOverrides: negativeOverrides)

        return "(((\(hName)) => ((\(positive)) - (\(negative))) / (2 * \(hName)))(0.00001))"
    }

    private func shouldWrap(_ expression: Expression, precedence: Int, parentPrecedence: Int, position: Position) -> Bool {
        if precedence < parentPrecedence {
            return true
        }

        if position == .right,
           precedence == parentPrecedence,
           case let .binary(operation, _, _) = expression {
            return operation == .subtract || operation == .divide || operation == .power
        }

        return false
    }

    private func precedence(of expression: Expression) -> Int {
        switch expression {
        case .number, .variable, .constant, .function, .derivative:
            return 5
        case .unary:
            return 3
        case let .binary(operation, _, _):
            switch operation {
            case .add, .subtract:
                return 1
            case .multiply, .implicitMultiply, .divide:
                return 2
            case .power:
                return 4
            }
        }
    }
}
