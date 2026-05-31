/// Euclid's algorithm on the magnitudes of two integers, returning their greatest
/// common divisor (`gcd(0, 0)` is 0). Uses only `%` and assignment — never a
/// widening multiply — so it cannot overflow on wasm32.
func integerGCD(_ a: Int, _ b: Int) -> Int {
    var x = a < 0 ? -a : a
    var y = b < 0 ? -b : b
    while y != 0 {
        let remainder = x % y
        x = y
        y = remainder
    }
    return x
}

/// An exact rational coefficient — `numerator / denominator`, both `DecimalValue` —
/// used by the `Simplifier` so that division folds the way a computer algebra
/// system does: `2/3 · 4/5 -> 8/15`, `6/4 -> 3/2`, `4x/2 -> 2x`. The sign always
/// lives in the numerator; the denominator is kept positive and is never zero.
///
/// Reduction to lowest terms only happens when both parts are small integers
/// (`DecimalValue.smallInteger`); a huge or scientific part is left unreduced
/// rather than risk a wasm32 overflow in the gcd. Arithmetic stays exact via
/// `DecimalValue`, so the simplifier's exponent cap still applies to each part.
struct Rational {
    let numerator: DecimalValue
    let denominator: DecimalValue

    private init(rawNumerator: DecimalValue, rawDenominator: DecimalValue) {
        self.numerator = rawNumerator
        self.denominator = rawDenominator
    }

    static let zero = Rational(rawNumerator: .zero, rawDenominator: .one)
    static let one = Rational(rawNumerator: .one, rawDenominator: .one)

    /// Builds a normalized rational: zero numerator collapses to `zero`, the sign
    /// is moved into the numerator, and the fraction is reduced when both parts are
    /// small integers sharing a common factor.
    static func make(numerator: DecimalValue, denominator: DecimalValue) -> Rational {
        if numerator.isZero || denominator.isZero { return .zero }

        var num = numerator
        var den = denominator
        if den.negative {
            num = num.negated
            den = den.magnitude
        }

        if let n = num.magnitude.smallInteger, let d = den.smallInteger, d > 0 {
            let divisor = Rational.gcd(n, d)
            if divisor > 1 {
                let reducedNumerator = DecimalValue(literal: "\(n / divisor)") ?? .zero
                let reducedDenominator = DecimalValue(literal: "\(d / divisor)") ?? .one
                return Rational(
                    rawNumerator: num.negative ? reducedNumerator.negated : reducedNumerator,
                    rawDenominator: reducedDenominator
                )
            }
        }
        return Rational(rawNumerator: num, rawDenominator: den)
    }

    /// An integer rational `value / 1`.
    static func integer(_ value: Int) -> Rational {
        guard let parsed = DecimalValue(literal: "\(value)") else { return .zero }
        return Rational(rawNumerator: parsed, rawDenominator: .one)
    }

    var isZero: Bool { numerator.isZero }
    var isInteger: Bool { denominator.isOne }
    var isOne: Bool { denominator.isOne && numerator.isOne }
    var isMinusOne: Bool { denominator.isOne && numerator.isMinusOne }
    var negative: Bool { numerator.negative }

    var magnitude: Rational {
        Rational(rawNumerator: numerator.magnitude, rawDenominator: denominator)
    }

    var negated: Rational {
        if isZero { return self }
        return Rational(rawNumerator: numerator.negated, rawDenominator: denominator)
    }

    func multiply(by other: Rational) -> Rational {
        Rational.make(
            numerator: numerator.multiply(by: other.numerator),
            denominator: denominator.multiply(by: other.denominator)
        )
    }

    /// `self / other`, i.e. `(num · oDen) / (den · oNum)`.
    func divide(by other: Rational) -> Rational {
        Rational.make(
            numerator: numerator.multiply(by: other.denominator),
            denominator: denominator.multiply(by: other.numerator)
        )
    }

    func adding(_ other: Rational) -> Rational {
        if isZero { return other }
        if other.isZero { return self }
        let crossSelf = numerator.multiply(by: other.denominator)
        let crossOther = other.numerator.multiply(by: denominator)
        return Rational.make(
            numerator: crossSelf.adding(crossOther),
            denominator: denominator.multiply(by: other.denominator)
        )
    }

    /// `self` raised to an integer power (negative powers take the reciprocal).
    /// The caller guarantees a non-zero base for negative exponents.
    func power(_ exponent: Int) -> Rational {
        if exponent == 0 { return .one }
        let magnitudeExponent = exponent < 0 ? -exponent : exponent
        var result = Rational.one
        var remaining = magnitudeExponent
        while remaining > 0 {
            result = result.multiply(by: self)
            remaining -= 1
        }
        if exponent < 0 {
            return Rational.make(numerator: result.denominator, denominator: result.numerator)
        }
        return result
    }

    /// Divisor used to reduce a fraction to lowest terms: the gcd of numerator and
    /// denominator, falling back to 1 for the degenerate all-zero case so a divide
    /// is always safe.
    private static func gcd(_ a: Int, _ b: Int) -> Int {
        let divisor = integerGCD(a, b)
        return divisor == 0 ? 1 : divisor
    }
}
