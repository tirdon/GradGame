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
    case expressionTooComplex
    case numberTooLarge
    case notANumber
    case divisionByZero

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
        case .expressionTooComplex:
            return "Expression is too complex. Try a shorter one."
        case .numberTooLarge:
            return "Number is too large (exponent exceeds 38)."
        case .notANumber:
            return "Result is not a number (0 / 0 is undefined)."
        case .divisionByZero:
            return "Result is infinite (division by zero)."
        }
    }
}
