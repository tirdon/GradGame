indirect enum Expression: Equatable {
    case number(String)
    case variable(String)
    case constant(String)
    case unary(UnaryOperator, Expression)
    case binary(BinaryOperator, Expression, Expression)
    case function(name: String, argument: Expression, exponent: Expression?, parenthesized: Bool)
    case derivative(variable: String, argument: Expression, parenthesized: Bool)
}

enum UnaryOperator: Equatable {
    case plus
    case minus
}

enum BinaryOperator: Equatable {
    case add
    case subtract
    case multiply
    case implicitMultiply
    case divide
    case power
}
