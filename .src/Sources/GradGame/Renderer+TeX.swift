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
            rendered = renderNumber(value)
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
        let precedence = precedence(ofBinary: operation)

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

        // Two adjacent numerals must be separated, or they read as one number.
        if isNumeric(trailing) && isNumeric(leading) {
            return " \\times "
        }

        return " "
    }

    private func isNumeric(_ expression: Expression) -> Bool {
        if case .number = expression {
            return true
        }
        return false
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

    // MARK: Numeric formatting

    /// Renders a numeric literal as `mantissa \times 10^{exponent}` when it is
    /// written in E-notation or its integer part exceeds Int32.max; otherwise the
    /// literal is shown verbatim. Works on the raw digit bytes, so arbitrarily
    /// large values are formatted exactly and never overflow a fixed-width integer.
    private func renderNumber(_ value: String) -> String {
        let bytes = Array(value.utf8)

        // Split off an explicit (uppercase E) exponent, if present.
        var mantissaEnd = bytes.count
        var explicitExponent = 0
        var hasExponent = false
        var scan = 0
        while scan < bytes.count {
            if bytes[scan] == 69 { // 'E'
                guard let parsed = parseExponent(bytes, after: scan) else {
                    return value // malformed exponent: render verbatim
                }
                mantissaEnd = scan
                explicitExponent = parsed
                hasExponent = true
                break
            }
            scan += 1
        }

        // Separate the mantissa's integer and fraction digits.
        var integerDigits: [UInt8] = []
        var fractionDigits: [UInt8] = []
        var sawPoint = false
        var m = 0
        while m < mantissaEnd {
            let byte = bytes[m]
            m += 1
            if byte == 46 { // '.'
                sawPoint = true
            } else if sawPoint {
                fractionDigits.append(byte)
            } else {
                integerDigits.append(byte)
            }
        }

        if !hasExponent && !integerExceedsInt32Max(integerDigits) {
            return value // small, plain number: leave it alone
        }

        // Significand = every digit; the leading integer digit's place value is
        // 10^(integerDigits.count - 1 + explicitExponent).
        var significand = integerDigits
        var f = 0
        while f < fractionDigits.count {
            significand.append(fractionDigits[f])
            f += 1
        }

        var firstNonZero = 0
        while firstNonZero < significand.count, significand[firstNonZero] == 48 { // '0'
            firstNonZero += 1
        }
        if firstNonZero == significand.count {
            return "0" // the value is exactly zero
        }

        let exponent = integerDigits.count - 1 - firstNonZero + explicitExponent

        // Trim trailing zeros from the significand (down to one leading digit).
        var end = significand.count
        while end > firstNonZero + 1, significand[end - 1] == 48 {
            end -= 1
        }

        var mantissa = String(UnicodeScalar(significand[firstNonZero]))
        if end - firstNonZero > 1 {
            var fraction = ""
            var d = firstNonZero + 1
            while d < end {
                fraction.append(Character(UnicodeScalar(significand[d])))
                d += 1
            }
            mantissa += "." + fraction
        }

        if exponent == 0 {
            return mantissa // e.g. 3E0 -> 3, no need for "\times 10^{0}"
        }
        return "\(mantissa) \\times 10^{\(exponent)}"
    }

    /// Parses the digits after an `E` into an `Int`, returning nil if malformed.
    /// The magnitude is bounded so the accumulation cannot overflow.
    private func parseExponent(_ bytes: [UInt8], after eIndex: Int) -> Int? {
        var index = eIndex + 1
        var negative = false
        if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 {
            negative = bytes[index] == 45
            index += 1
        }
        guard index < bytes.count else { return nil }

        var magnitude = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte >= 48, byte <= 57 else { return nil }
            if magnitude > 1_000_000 { return nil } // absurd exponent: bail out
            magnitude = magnitude * 10 + Int(byte - 48)
            index += 1
        }
        return negative ? -magnitude : magnitude
    }

    /// Whether the integer formed by `digits` is greater than Int32.max
    /// (2147483647), decided by digit count and lexicographic compare so no
    /// integer conversion (which would overflow) is needed.
    private func integerExceedsInt32Max(_ digits: [UInt8]) -> Bool {
        var start = 0
        while start + 1 < digits.count, digits[start] == 48 {
            start += 1
        }
        let significant = digits.count - start
        if significant > 10 { return true }
        if significant < 10 { return false }

        let maxDigits: [UInt8] = [50, 49, 52, 55, 52, 56, 51, 54, 52, 55] // "2147483647"
        var d = 0
        while d < 10 {
            if digits[start + d] != maxDigits[d] {
                return digits[start + d] > maxDigits[d]
            }
            d += 1
        }
        return false // equal to Int32.max is not "exceeds"
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
            return render(expression, parentPrecedence: precedence(ofBinary: .power), position: .left)
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
            return precedence(ofBinary: operation)
        }
    }

    /// A binary node's precedence depends only on its operator, so callers that
    /// already hold the operator avoid allocating a throwaway `.binary` node
    /// (an `indirect` enum, hence heap-boxed) just to read it back.
    private func precedence(ofBinary operation: BinaryOperator) -> Int {
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
