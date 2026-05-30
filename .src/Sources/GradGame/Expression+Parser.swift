public func parseExpressionToTeX(_ input: String, simplify: Bool = false) throws -> String {
    var expression = try Differentiator().resolve(parseExpression(input))
    if simplify {
        expression = try Simplifier().simplify(expression)
    }
    return TeXRenderer().render(expression)
}

public func parseExpressionToJavaScript(_ input: String) throws -> String {
    try JavaScriptRenderer().render(Differentiator().resolve(parseExpression(input)))
}

/// Parse `input` and resolve every `dx`/`dy` node to its symbolic derivative,
/// yielding an AST ready for `evaluate(x:y:)`. Shared by the Graph War engine
/// exports so the trajectory sweep evaluates the same tree the renderers would.
func parseAndResolveExpression(_ input: String) throws -> Expression {
    try Differentiator().resolve(parseExpression(input))
}

private func parseExpression(_ input: String) throws -> Expression {
    let tokens = try ExpressionLexer(input).tokens()
    return try ExpressionParser(tokens: tokens).parse()
}

private final class ExpressionParser {
    private let tokens: [Token]
    private var index = 0

    /// Caps the input so parsing, simplification, and TeX/JS rendering — all of
    /// which recurse over the expression tree — cannot overflow the small Wasm
    /// stack. A flat chain of N nodes recurses N deep, and a nesting of depth D
    /// needs at least D tokens, so bounding the token count bounds every
    /// recursion depth. Without this guard a long input traps (and on Wasm can
    /// hard-crash the instance) instead of failing cleanly.
    private static let maximumTokenCount = 256

    init(tokens: [Token]) {
        self.tokens = tokens
    }

    func parse() throws -> Expression {
        if tokens.count > ExpressionParser.maximumTokenCount {
            throw ExpressionParserError.expressionTooComplex
        }

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
            || name == "log"
            || name == "sqrt"
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
