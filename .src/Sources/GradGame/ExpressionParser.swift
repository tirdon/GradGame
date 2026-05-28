enum ExpressionParserError: Error, Equatable, CustomStringConvertible {
    case emptyExpression
    case unexpectedCharacter(Character, Int)
    case expectedExpression(String)
    case expectedClosingParenthesis(String)
    case expectedComma(String)
    case unsupportedIdentifier(String)
    case unsupportedFunction(String)
    case missingFunctionArgument(String)
    case wrongArgumentCount(String, expected: Int, received: Int)
    case trailingInput(String)

    var description: String {
        switch self {
        case .emptyExpression:
            return "Expected an expression."
        case let .unexpectedCharacter(character, offset):
            return "Unexpected character '\(character)' at offset \(offset)."
        case let .expectedExpression(found):
            return "Expected an expression before \(found)."
        case let .expectedClosingParenthesis(found):
            return "Expected ')' before \(found)."
        case let .expectedComma(found):
            return "Expected ',' before \(found)."
        case let .unsupportedIdentifier(name):
            return "Unsupported identifier '\(name)'. Use only x, y, e, pi, phi, gamma, and supported functions."
        case let .unsupportedFunction(name):
            return "Unsupported function '\(name)'."
        case let .missingFunctionArgument(name):
            return "Missing argument for function '\(name)'."
        case let .wrongArgumentCount(name, expected, received):
            return "Function '\(name)' expects \(expected) argument(s), got \(received)."
        case let .trailingInput(found):
            return "Unexpected input after expression: \(found)."
        }
    }
}

public func parseExpressionToTeX(_ input: String) throws -> String {
    try TeXRenderer().render(parseExpression(input))
}

public func parseExpressionToJavaScript(_ input: String) throws -> String {
    try JavaScriptRenderer().render(parseExpression(input))
}

private func parseExpression(_ input: String) throws -> Expression {
    let tokens = try ExpressionLexer(input).tokens()
    return try ExpressionParser(tokens: tokens).parse()
}

private enum Token: Equatable {
    case number(String)
    case identifier(String)
    case plus
    case minus
    case star
    case slash
    case caret
    case comma
    case leftParenthesis
    case rightParenthesis
    case end

    var description: String {
        switch self {
        case let .number(value):
            return "'\(value)'"
        case let .identifier(name):
            return "'\(name)'"
        case .plus:
            return "'+'"
        case .minus:
            return "'-'"
        case .star:
            return "'*'"
        case .slash:
            return "'/'"
        case .caret:
            return "'^'"
        case .comma:
            return "','"
        case .leftParenthesis:
            return "'('"
        case .rightParenthesis:
            return "')'"
        case .end:
            return "end of input"
        }
    }
}

private struct ExpressionLexer {
    private let bytes: [UInt8]

    init(_ input: String) {
        bytes = Array(input.utf8)
    }

    func tokens() throws -> [Token] {
        var tokens: [Token] = []
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]

            if isWhitespace(byte) {
                index += 1
                continue
            }

            switch byte {
            case 43:
                tokens.append(.plus)
                index += 1
            case 45:
                tokens.append(.minus)
                index += 1
            case 42:
                tokens.append(.star)
                index += 1
            case 47:
                tokens.append(.slash)
                index += 1
            case 94:
                tokens.append(.caret)
                index += 1
            case 44:
                tokens.append(.comma)
                index += 1
            case 40:
                tokens.append(.leftParenthesis)
                index += 1
            case 41:
                tokens.append(.rightParenthesis)
                index += 1
            default:
                if isDigit(byte) || byte == 46 {
                    let start = index
                    var sawDigit = false
                    var sawDecimalPoint = false

                    while index < bytes.count {
                        let current = bytes[index]
                        if isDigit(current) {
                            sawDigit = true
                            index += 1
                        } else if current == 46 && !sawDecimalPoint {
                            sawDecimalPoint = true
                            index += 1
                        } else {
                            break
                        }
                    }

                    guard sawDigit else {
                        throw ExpressionParserError.unexpectedCharacter(".", start)
                    }

                    tokens.append(.number(String(decoding: bytes[start..<index], as: UTF8.self)))
                } else if isLetter(byte) {
                    let start = index
                    while index < bytes.count, isLetter(bytes[index]) {
                        index += 1
                    }
                    tokens.append(.identifier(String(decoding: bytes[start..<index], as: UTF8.self)))
                } else {
                    throw ExpressionParserError.unexpectedCharacter(Character(UnicodeScalar(byte)), index)
                }
            }
        }

        tokens.append(.end)
        return tokens
    }

    private func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    private func isLetter(_ byte: UInt8) -> Bool {
        byte >= 65 && byte <= 90 || byte >= 97 && byte <= 122
    }
}

private indirect enum Expression: Equatable {
    case number(String)
    case variable(String)
    case constant(String)
    case unary(UnaryOperator, Expression)
    case binary(BinaryOperator, Expression, Expression)
    case function(name: String, argument: Expression, exponent: Expression?, parenthesized: Bool)
    case derivative(variable: String, argument: Expression, parenthesized: Bool)
}

private enum UnaryOperator: Equatable {
    case plus
    case minus
}

private enum BinaryOperator: Equatable {
    case add
    case subtract
    case multiply
    case implicitMultiply
    case divide
    case power
}

private final class ExpressionParser {
    private let tokens: [Token]
    private var index = 0

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    func parse() throws -> Expression {
        guard current != .end else {
            throw ExpressionParserError.emptyExpression
        }

        let expression = try parseAddition()
        guard current == .end else {
            throw ExpressionParserError.trailingInput(current.description)
        }
        return expression
    }

    private var current: Token {
        tokens[index]
    }

    private func advance() {
        index += 1
    }

    private func match(_ token: Token) -> Bool {
        guard current == token else {
            return false
        }
        advance()
        return true
    }

    private func parseAddition() throws -> Expression {
        var expression = try parseMultiplication()

        while true {
            if match(.plus) {
                expression = .binary(.add, expression, try parseMultiplication())
            } else if match(.minus) {
                expression = .binary(.subtract, expression, try parseMultiplication())
            } else {
                return expression
            }
        }
    }

    private func parseMultiplication() throws -> Expression {
        var expression = try parseUnary()

        while true {
            if match(.star) {
                expression = .binary(.multiply, expression, try parseUnary())
            } else if match(.slash) {
                expression = .binary(.divide, expression, try parseUnary())
            } else if startsImplicitFactor(current) {
                expression = .binary(.implicitMultiply, expression, try parseUnary())
            } else {
                return expression
            }
        }
    }

    private func parseUnary() throws -> Expression {
        if match(.plus) {
            return .unary(.plus, try parseUnary())
        }
        if match(.minus) {
            return .unary(.minus, try parseUnary())
        }
        return try parsePower()
    }

    private func parsePower() throws -> Expression {
        var expression = try parsePrimary()

        if match(.caret) {
            expression = .binary(.power, expression, try parseUnary())
        }

        return expression
    }

    private func parsePrimary() throws -> Expression {
        switch current {
        case let .number(value):
            advance()
            return .number(value)
        case let .identifier(name):
            advance()
            return try parseIdentifier(name)
        case .leftParenthesis:
            advance()
            let expression = try parseAddition()
            guard match(.rightParenthesis) else {
                throw ExpressionParserError.expectedClosingParenthesis(current.description)
            }
            return expression
        case .end:
            throw ExpressionParserError.expectedExpression(current.description)
        default:
            throw ExpressionParserError.expectedExpression(current.description)
        }
    }

    private func parseIdentifier(_ name: String) throws -> Expression {
        if isVariable(name) {
            return .variable(name)
        }

        if isConstant(name) {
            return .constant(name)
        }

        if name == "pow" {
            return try parsePowFunction()
        }

        if name == "dx" || name == "dy" {
            return try parseDerivative(name)
        }

        if isUnaryFunction(name) {
            return try parseUnaryFunction(name)
        }

        if current == .leftParenthesis {
            throw ExpressionParserError.unsupportedFunction(name)
        }

        throw ExpressionParserError.unsupportedIdentifier(name)
    }

    private func isVariable(_ name: String) -> Bool {
        name == "x" || name == "y"
    }

    private func isConstant(_ name: String) -> Bool {
        name == "pi" || name == "e" || name == "phi" || name == "gamma"
    }

    private func isUnaryFunction(_ name: String) -> Bool {
        name == "sin"
            || name == "cos"
            || name == "tan"
            || name == "sec"
            || name == "csc"
            || name == "cot"
            || name == "sinh"
            || name == "cosh"
            || name == "tanh"
            || name == "exp"
    }

    private func parsePowFunction() throws -> Expression {
        guard current == .leftParenthesis else {
            throw ExpressionParserError.missingFunctionArgument("pow")
        }

        let arguments = try parseParenthesizedArguments(for: "pow")
        guard arguments.count == 2 else {
            throw ExpressionParserError.wrongArgumentCount("pow", expected: 2, received: arguments.count)
        }

        return .binary(.power, arguments[0], arguments[1])
    }

    private func parseDerivative(_ name: String) throws -> Expression {
        let variable = name == "dx" ? "x" : "y"

        if current == .leftParenthesis {
            let arguments = try parseParenthesizedArguments(for: name)
            guard arguments.count == 1 else {
                throw ExpressionParserError.wrongArgumentCount(name, expected: 1, received: arguments.count)
            }
            return .derivative(variable: variable, argument: arguments[0], parenthesized: true)
        }

        guard startsBareFunctionArgument(current) else {
            throw ExpressionParserError.missingFunctionArgument(name)
        }

        return .derivative(variable: variable, argument: try parseUnary(), parenthesized: false)
    }

    private func parseUnaryFunction(_ name: String) throws -> Expression {
        let exponent: Expression?
        if match(.caret) {
            exponent = try parseUnary()
        } else {
            exponent = nil
        }

        if current == .leftParenthesis {
            let arguments = try parseParenthesizedArguments(for: name)
            guard arguments.count == 1 else {
                throw ExpressionParserError.wrongArgumentCount(name, expected: 1, received: arguments.count)
            }
            return .function(name: name, argument: arguments[0], exponent: exponent, parenthesized: true)
        }

        guard startsBareFunctionArgument(current) else {
            throw ExpressionParserError.missingFunctionArgument(name)
        }

        return .function(name: name, argument: try parseUnary(), exponent: exponent, parenthesized: false)
    }

    private func parseParenthesizedArguments(for name: String) throws -> [Expression] {
        guard match(.leftParenthesis) else {
            throw ExpressionParserError.missingFunctionArgument(name)
        }

        guard current != .rightParenthesis else {
            advance()
            return []
        }

        var arguments: [Expression] = [try parseAddition()]
        while match(.comma) {
            arguments.append(try parseAddition())
        }

        guard match(.rightParenthesis) else {
            throw ExpressionParserError.expectedClosingParenthesis(current.description)
        }

        return arguments
    }

    private func startsImplicitFactor(_ token: Token) -> Bool {
        switch token {
        case .number, .identifier, .leftParenthesis:
            return true
        default:
            return false
        }
    }

    private func startsBareFunctionArgument(_ token: Token) -> Bool {
        switch token {
        case .number, .identifier, .leftParenthesis, .plus, .minus:
            return true
        default:
            return false
        }
    }
}

private struct TeXRenderer {
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

private final class JavaScriptRenderer {
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
