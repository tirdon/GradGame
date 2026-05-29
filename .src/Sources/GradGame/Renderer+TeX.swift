struct TeXRenderer {
    func render(_ expression: Expression) -> String {
        render(expression, parentPrecedence: 0, position: .none)
    }

    private enum Position {
        case none
        case left
        case right
    }

    private func render(_ expression: Expression, parentPrecedence: Int, position: Position) -> String {
        let rendered: String
        let precedence = self.precedence(of: expression)

        switch expression {
        case let .number(value):
            rendered = value
        case let .variable(name):
            rendered = name
        case let .constant(name):
            rendered = renderConstant(name)
        case let .unary(operation, operand):
            let operandTeX = render(operand, parentPrecedence: precedence, position: .right)
            switch operation {
            case .plus:
                rendered = "+\(operandTeX)"
            case .minus:
                rendered = "-\(operandTeX)"
            }
        case let .binary(operation, lhs, rhs):
            rendered = renderBinary(operation, lhs, rhs)
        case let .function(name, argument, exponent, parenthesized):
            rendered = renderFunction(name: name, argument: argument, exponent: exponent, parenthesized: parenthesized)
        case let .derivative(variable, argument, _):
            rendered = "\\frac{\\partial}{\\partial \(variable)}\\left(\(render(argument, parentPrecedence: 0, position: .none))\\right)"
        }

        if shouldWrap(expression, precedence: precedence, parentPrecedence: parentPrecedence, position: position) {
            return "\\left(\(rendered)\\right)"
        }

        return rendered
    }

    private func renderBinary(_ operation: BinaryOperator, _ lhs: Expression, _ rhs: Expression) -> String {
        let precedence = precedence(of: .binary(operation, lhs, rhs))

        switch operation {
        case .add:
            return "\(render(lhs, parentPrecedence: precedence, position: .left)) + \(render(rhs, parentPrecedence: precedence, position: .right))"
        case .subtract:
            return "\(render(lhs, parentPrecedence: precedence, position: .left)) - \(render(rhs, parentPrecedence: precedence, position: .right))"
        case .multiply:
            return "\(render(lhs, parentPrecedence: precedence, position: .left)) \\times \(render(rhs, parentPrecedence: precedence, position: .right))"
        case .implicitMultiply:
            let separator = implicitMultiplicationSeparator(lhs: lhs, rhs: rhs)
            return "\(render(lhs, parentPrecedence: precedence, position: .left))\(separator)\(render(rhs, parentPrecedence: precedence, position: .right))"
        case .divide:
            return "\\frac{\(render(lhs, parentPrecedence: 0, position: .none))}{\(render(rhs, parentPrecedence: 0, position: .none))}"
        case .power:
            let base = renderPowerBase(lhs)
            let exponent = render(rhs, parentPrecedence: 0, position: .none)
            return "\(base)^{\(exponent)}"
        }
    }

    private func implicitMultiplicationSeparator(lhs: Expression, rhs: Expression) -> String {
        let trailing = trailingFactor(lhs)
        let leading = leadingFactor(rhs)

        if isFunctionLike(trailing) && isFunctionLike(leading) {
            return " \\times "
        }

        return " "
    }

    private func trailingFactor(_ expression: Expression) -> Expression {
        switch expression {
        case let .binary(.implicitMultiply, _, rhs), let .binary(.multiply, _, rhs):
            return trailingFactor(rhs)
        default:
            return expression
        }
    }

    private func leadingFactor(_ expression: Expression) -> Expression {
        switch expression {
        case let .binary(.implicitMultiply, lhs, _), let .binary(.multiply, lhs, _):
            return leadingFactor(lhs)
        default:
            return expression
        }
    }

    private func renderConstant(_ name: String) -> String {
        switch name {
        case "pi":
            return "\\pi"
        case "phi":
            return "\\phi"
        case "gamma":
            return "\\gamma"
        default:
            return name
        }
    }

    private func renderFunction(name: String, argument: Expression, exponent: Expression?, parenthesized: Bool) -> String {
        let macro = name == "exp" ? "\\exp" : "\\\(name)"
        let exponentTeX = exponent.map { "^{\(render($0, parentPrecedence: 0, position: .none))}" } ?? ""
        let argumentTeX = render(argument, parentPrecedence: 0, position: .none)

        if parenthesized || !canRenderAsBareFunctionArgument(argument) {
            return "\(macro)\(exponentTeX)(\(argumentTeX))"
        }

        return "\(macro)\(exponentTeX) \(argumentTeX)"
    }

    private func renderPowerBase(_ expression: Expression) -> String {
        switch expression {
        case .number, .variable, .constant, .function, .derivative:
            return render(expression, parentPrecedence: precedence(of: .binary(.power, expression, expression)), position: .left)
        default:
            return "\\left(\(render(expression, parentPrecedence: 0, position: .none))\\right)"
        }
    }

    private func canRenderAsBareFunctionArgument(_ expression: Expression) -> Bool {
        switch expression {
        case .number, .variable, .constant:
            return true
        case let .binary(.power, lhs, rhs):
            return canRenderAsBareFunctionArgument(lhs) && canRenderAsBareFunctionArgument(rhs)
        default:
            return false
        }
    }

    private func isFunctionLike(_ expression: Expression) -> Bool {
        switch expression {
        case .function, .derivative:
            return true
        case let .binary(.implicitMultiply, lhs, rhs), let .binary(.multiply, lhs, rhs):
            return isFunctionLike(lhs) || isFunctionLike(rhs)
        case let .binary(.power, lhs, _):
            return isFunctionLike(lhs)
        default:
            return false
        }
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
