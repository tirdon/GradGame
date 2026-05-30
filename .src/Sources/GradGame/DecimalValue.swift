/// An arbitrary-precision base-10 value used by the `Simplifier` to fold numeric
/// literals: `value = (±) d0.d1d2… × 10^exponent`. Kept as a digit array (not a
/// `Double`) so multiplication/addition are exact up to a final rounding step and
/// so formatting never goes through `Double → String`.
///
/// **wasm-safety:** all arithmetic uses `[UInt8]`/`[Int]` digit arrays with
/// `while` index loops (never `Sequence` for-in over the arrays), `Int` only
/// (never `Int32`/`Int64`/`UInt`, never `.magnitude`), and strings are built from
/// `UnicodeScalar`/`Character` appends plus `Int` interpolation — all clear of the
/// patterns that trap on this SwiftWasm toolchain (see `swiftwasm-trapping-patterns`).
struct DecimalValue {
    /// Significant digits, most-significant first, each `0...9`. Empty iff zero.
    /// No leading zeros; no trailing zeros (so `100` is `[1]` with `exponent = 2`).
    private(set) var digits: [UInt8]
    /// Power of ten of the leading digit. For `2.5` it is `0`; for `100000` it is `5`.
    private(set) var exponent: Int
    private(set) var negative: Bool
    /// Render in scientific (`E`) notation even when small enough to look plain —
    /// set for E-notation provenance, so `3E6` stays `3 × 10^6` after folding.
    private(set) var scientific: Bool

    /// Folded mantissas are rounded to this many significant figures for display.
    private static let maxSignificantDigits = 15

    private init(digits: [UInt8], exponent: Int, negative: Bool, scientific: Bool) {
        self.digits = digits
        self.exponent = exponent
        self.negative = negative
        self.scientific = scientific
    }

    static let zero = DecimalValue(digits: [], exponent: 0, negative: false, scientific: false)
    static let one = DecimalValue(digits: [1], exponent: 0, negative: false, scientific: false)

    var isZero: Bool { digits.isEmpty }
    var isOne: Bool { !negative && exponent == 0 && digits.count == 1 && digits[0] == 1 }
    var isMinusOne: Bool { negative && exponent == 0 && digits.count == 1 && digits[0] == 1 }

    var negated: DecimalValue {
        if isZero { return self }
        return DecimalValue(digits: digits, exponent: exponent, negative: !negative, scientific: scientific)
    }

    var magnitude: DecimalValue {
        DecimalValue(digits: digits, exponent: exponent, negative: false, scientific: scientific)
    }

    /// The exact `Int` value when this is an integer of at most 9 significant
    /// places, else nil. The 9-place bound keeps every accumulation step below
    /// Int32.max so the multiply-by-ten never overflows on wasm32 (where `Int` is
    /// 32-bit). Used for rational gcd reduction, which only needs small integers.
    var smallInteger: Int? {
        if isZero { return 0 }
        if exponent < digits.count - 1 { return nil } // has a fractional part
        if exponent + 1 > 9 { return nil }            // would exceed 9 digits
        var accumulator = 0
        var index = 0
        while index < digits.count {
            accumulator = accumulator * 10 + Int(digits[index])
            index += 1
        }
        var trailingZeros = exponent - (digits.count - 1)
        while trailingZeros > 0 {
            accumulator = accumulator * 10
            trailingZeros -= 1
        }
        return negative ? -accumulator : accumulator
    }

    // MARK: Parsing

    /// Parses a lexer `.number` payload (digits, optional `.`, optional uppercase
    /// `E` exponent). Mirrors `TeXRenderer.renderNumber`'s byte scan.
    init?(literal text: String) {
        let bytes = Array(text.utf8)

        var mantissaEnd = bytes.count
        var explicitExponent = 0
        var sawExponent = false
        var scan = 0
        while scan < bytes.count {
            if bytes[scan] == 69 { // 'E'
                guard let parsed = DecimalValue.parseExponent(bytes, after: scan) else { return nil }
                mantissaEnd = scan
                explicitExponent = parsed
                sawExponent = true
                break
            }
            scan += 1
        }

        var significand: [UInt8] = []
        var integerCount = 0
        var sawPoint = false
        var index = 0
        while index < mantissaEnd {
            let byte = bytes[index]
            index += 1
            if byte == 46 { // '.'
                sawPoint = true
                continue
            }
            guard byte >= 48, byte <= 57 else { return nil }
            significand.append(byte - 48)
            if !sawPoint { integerCount += 1 }
        }

        var firstNonZero = 0
        while firstNonZero < significand.count, significand[firstNonZero] == 0 {
            firstNonZero += 1
        }
        if firstNonZero == significand.count {
            self.init(digits: [], exponent: 0, negative: false, scientific: sawExponent)
            return
        }

        let leadingExponent = (integerCount - 1 - firstNonZero) + explicitExponent

        var end = significand.count
        while end - 1 > firstNonZero, significand[end - 1] == 0 {
            end -= 1
        }

        var kept: [UInt8] = []
        var k = firstNonZero
        while k < end {
            kept.append(significand[k])
            k += 1
        }
        self.init(digits: kept, exponent: leadingExponent, negative: false, scientific: sawExponent)
    }

    /// Parses the digits after an `E` into an `Int`, bounding the magnitude so the
    /// accumulation can never overflow (an absurd exponent stays > 38 and is later
    /// rejected by the exponent cap). Returns nil if malformed.
    private static func parseExponent(_ bytes: [UInt8], after eIndex: Int) -> Int? {
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
            if magnitude <= 1_000_000 {
                magnitude = magnitude * 10 + Int(byte - 48)
            }
            index += 1
        }
        if magnitude > 1_000_000 { magnitude = 1_000_001 }
        return negative ? -magnitude : magnitude
    }

    // MARK: Arithmetic (exact; rounding is deferred to `rounded()` / `literalString()`)

    func multiply(by other: DecimalValue) -> DecimalValue {
        if isZero || other.isZero { return DecimalValue.zero }
        let raw = DecimalValue.multiplyDigits(digits, other.digits)
        let low = (exponent - (digits.count - 1)) + (other.exponent - (other.digits.count - 1))
        return DecimalValue.make(
            rawMSF: raw,
            lowPlace: low,
            negative: negative != other.negative,
            scientific: scientific || other.scientific
        )
    }

    func adding(_ other: DecimalValue) -> DecimalValue {
        if isZero { return other }
        if other.isZero { return self }

        let lowSelf = exponent - (digits.count - 1)
        let lowOther = other.exponent - (other.digits.count - 1)
        let low = lowSelf < lowOther ? lowSelf : lowOther

        var a = digits
        var alignA = lowSelf
        while alignA > low { a.append(0); alignA -= 1 }
        var b = other.digits
        var alignB = lowOther
        while alignB > low { b.append(0); alignB -= 1 }
        DecimalValue.leftPadEqual(&a, &b)

        let combinedScientific = scientific || other.scientific
        if negative == other.negative {
            return DecimalValue.make(
                rawMSF: DecimalValue.addMagnitudes(a, b),
                lowPlace: low,
                negative: negative,
                scientific: combinedScientific
            )
        }

        let comparison = DecimalValue.compareMagnitudes(a, b)
        if comparison == 0 { return DecimalValue.zero }
        if comparison > 0 {
            return DecimalValue.make(rawMSF: DecimalValue.subtractMagnitudes(a, b), lowPlace: low, negative: negative, scientific: combinedScientific)
        }
        return DecimalValue.make(rawMSF: DecimalValue.subtractMagnitudes(b, a), lowPlace: low, negative: other.negative, scientific: combinedScientific)
    }

    /// `self` raised to a non-negative integer power by repeated multiplication.
    func power(_ exponent: Int) -> DecimalValue {
        if exponent <= 0 { return DecimalValue.one }
        var result = DecimalValue.one
        var remaining = exponent
        while remaining > 0 {
            result = result.multiply(by: self)
            remaining -= 1
        }
        return result
    }

    // MARK: Rounding

    /// A copy rounded (half-up) to at most `maxSignificantDigits` significant digits.
    func rounded() -> DecimalValue {
        if digits.count <= DecimalValue.maxSignificantDigits { return self }
        var copy = self
        copy.round(to: DecimalValue.maxSignificantDigits)
        return copy
    }

    private mutating func round(to maxDigits: Int) {
        if digits.count <= maxDigits { return }
        let roundUp = digits[maxDigits] >= 5
        var kept: [UInt8] = []
        var k = 0
        while k < maxDigits {
            kept.append(digits[k])
            k += 1
        }
        if roundUp {
            var index = maxDigits - 1
            var carry = 1
            while index >= 0, carry > 0 {
                let sum = Int(kept[index]) + carry
                kept[index] = UInt8(sum % 10)
                carry = sum / 10
                index -= 1
            }
            if carry > 0 {
                var grown: [UInt8] = [1]
                var j = 0
                while j < kept.count { grown.append(kept[j]); j += 1 }
                kept = grown
                exponent += 1
            }
        }
        var end = kept.count
        while end > 1, kept[end - 1] == 0 { end -= 1 }
        var trimmed: [UInt8] = []
        var j = 0
        while j < end { trimmed.append(kept[j]); j += 1 }
        digits = trimmed
    }

    // MARK: Serialization

    /// The AST `.number` payload for this value's **magnitude** (sign is applied by
    /// the caller via a unary minus). Plain digits when small and not E-flagged;
    /// otherwise `<mantissa>E<exponent>`, which `renderNumber` formats and normalizes.
    func literalString() -> String {
        let value = rounded()
        if value.isZero { return "0" }
        let count = value.digits.count
        let isIntegral = value.exponent >= count - 1
        if !value.scientific {
            if isIntegral { return value.plainIntegerString() }
            if value.exponent >= -4 && value.exponent <= 9 { return value.plainDecimalString() }
        }
        return value.scientificString()
    }

    private func plainIntegerString() -> String {
        var result = ""
        var index = 0
        while index < digits.count {
            result.append(Character(UnicodeScalar(digits[index] + 48)))
            index += 1
        }
        var zeros = exponent - (digits.count - 1)
        while zeros > 0 { result.append("0"); zeros -= 1 }
        return result
    }

    private func plainDecimalString() -> String {
        if exponent < 0 {
            var result = "0."
            var zeros = -exponent - 1
            while zeros > 0 { result.append("0"); zeros -= 1 }
            var index = 0
            while index < digits.count {
                result.append(Character(UnicodeScalar(digits[index] + 48)))
                index += 1
            }
            return result
        }
        var result = ""
        let integerDigitCount = exponent + 1
        var index = 0
        while index < digits.count {
            if index == integerDigitCount { result.append(".") }
            result.append(Character(UnicodeScalar(digits[index] + 48)))
            index += 1
        }
        return result
    }

    private func scientificString() -> String {
        var mantissa = String(Character(UnicodeScalar(digits[0] + 48)))
        if digits.count > 1 {
            mantissa.append(".")
            var index = 1
            while index < digits.count {
                mantissa.append(Character(UnicodeScalar(digits[index] + 48)))
                index += 1
            }
        }
        return mantissa + "E\(exponent)"
    }

    // MARK: Digit-array primitives (most-significant-first)

    /// Normalizes a raw most-significant-first digit array whose least-significant
    /// digit sits at place `lowPlace` into a canonical `DecimalValue`.
    private static func make(rawMSF: [UInt8], lowPlace: Int, negative: Bool, scientific: Bool) -> DecimalValue {
        var first = 0
        while first < rawMSF.count, rawMSF[first] == 0 { first += 1 }
        if first == rawMSF.count { return DecimalValue.zero }

        var end = rawMSF.count
        var low = lowPlace
        while end - 1 > first, rawMSF[end - 1] == 0 {
            end -= 1
            low += 1
        }

        var kept: [UInt8] = []
        var index = first
        while index < end {
            kept.append(rawMSF[index])
            index += 1
        }
        return DecimalValue(digits: kept, exponent: low + (kept.count - 1), negative: negative, scientific: scientific)
    }

    private static func multiplyDigits(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var result = [Int](repeating: 0, count: a.count + b.count)
        var i = a.count - 1
        while i >= 0 {
            var j = b.count - 1
            while j >= 0 {
                let product = Int(a[i]) * Int(b[j])
                let low = i + j + 1
                let sum = product + result[low]
                result[low] = sum % 10
                result[i + j] += sum / 10
                j -= 1
            }
            i -= 1
        }
        var out: [UInt8] = []
        var k = 0
        while k < result.count {
            out.append(UInt8(result[k]))
            k += 1
        }
        return out
    }

    /// Left-pads the shorter array with leading zeros so both share a length.
    private static func leftPadEqual(_ a: inout [UInt8], _ b: inout [UInt8]) {
        if a.count == b.count { return }
        if a.count < b.count {
            a = padLeading(a, to: b.count)
        } else {
            b = padLeading(b, to: a.count)
        }
    }

    private static func padLeading(_ array: [UInt8], to length: Int) -> [UInt8] {
        var padded = [UInt8](repeating: 0, count: length - array.count)
        var index = 0
        while index < array.count {
            padded.append(array[index])
            index += 1
        }
        return padded
    }

    /// Sum of two equal-length magnitudes; result is one digit longer (carry slot).
    private static func addMagnitudes(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: a.count + 1)
        var index = a.count - 1
        var carry = 0
        while index >= 0 {
            let sum = Int(a[index]) + Int(b[index]) + carry
            out[index + 1] = UInt8(sum % 10)
            carry = sum / 10
            index -= 1
        }
        out[0] = UInt8(carry)
        return out
    }

    /// Compares two equal-length magnitudes: -1, 0, or 1.
    private static func compareMagnitudes(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var index = 0
        while index < a.count {
            if a[index] != b[index] { return a[index] > b[index] ? 1 : -1 }
            index += 1
        }
        return 0
    }

    /// `a - b` for equal-length magnitudes, assuming `a >= b`.
    private static func subtractMagnitudes(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: a.count)
        var index = a.count - 1
        var borrow = 0
        while index >= 0 {
            var digit = Int(a[index]) - Int(b[index]) - borrow
            if digit < 0 {
                digit += 10
                borrow = 1
            } else {
                borrow = 0
            }
            out[index] = UInt8(digit)
            index -= 1
        }
        return out
    }
}
