// Operator precedence and parenthesization rules shared by the TeX and
// JavaScript renderers. Both targets parenthesize on the same binding strengths
// and the same right-associativity exception; only the delimiters and operator
// spellings differ, so this decision layer lives in one place.

/// Which side of its parent a subexpression is being rendered on, used to apply
/// the right-associativity wrapping exception for `-`, `/`, and `^`.
enum RenderPosition {
    case none
    case left
    case right
}

extension BinaryOperator {
    /// Binding strength used to decide parenthesization (higher binds tighter).
    /// A binary node's precedence depends only on its operator, so callers that
    /// already hold the operator read it here without allocating a throwaway
    /// `.binary` node (an `indirect` enum, hence heap-boxed) just to read it back.
    var precedence: Int {
        switch self {
        case .add, .subtract:
            return 1
        case .multiply, .implicitMultiply, .divide:
            return 2
        case .power:
            return 4
        }
    }
}

extension Expression {
    /// Binding strength of this node when rendered: atoms bind tightest, then
    /// unary, then binary operators by their operator precedence.
    var renderPrecedence: Int {
        switch self {
        case .number, .variable, .constant, .function, .derivative:
            return 5
        case .unary:
            return 3
        case let .binary(operation, _, _):
            return operation.precedence
        }
    }

    /// Whether this node needs wrapping in parentheses given its rendered
    /// precedence, its parent's precedence, and the side it sits on. A node binding
    /// looser than its parent always wraps; an equal-precedence right operand wraps
    /// only for the non-associative operators (`-`, `/`, `^`).
    func needsParentheses(precedence: Int, parentPrecedence: Int, position: RenderPosition) -> Bool {
        if precedence < parentPrecedence {
            return true
        }

        if position == .right,
           precedence == parentPrecedence,
           case let .binary(operation, _, _) = self {
            return operation == .subtract || operation == .divide || operation == .power
        }

        return false
    }
}
