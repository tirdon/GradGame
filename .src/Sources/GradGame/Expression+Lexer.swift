enum Token: Equatable {
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

struct ExpressionLexer {
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

                    index = consumeScientificExponent(from: index)

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

    /// Consumes an uppercase `E` exponent suffix (optionally signed) when one
    /// directly follows the mantissa, so `3E6` lexes as one scientific number.
    /// A lowercase `e` is deliberately left alone — it is Euler's constant.
    private func consumeScientificExponent(from index: Int) -> Int {
        guard index < bytes.count, bytes[index] == 69 else { return index } // 'E'

        var lookahead = index + 1
        if lookahead < bytes.count, bytes[lookahead] == 43 || bytes[lookahead] == 45 { // '+' '-'
            lookahead += 1
        }
        guard lookahead < bytes.count, isDigit(bytes[lookahead]) else { return index }

        var end = lookahead
        while end < bytes.count, isDigit(bytes[end]) {
            end += 1
        }
        return end
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
