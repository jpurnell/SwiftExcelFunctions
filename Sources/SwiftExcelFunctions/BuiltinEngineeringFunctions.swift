import Foundation
import SwiftExcelCore

/// The engineering primitives — base conversion, bitwise operations, step functions, and
/// the error function.
///
/// Seventeen of the forty-eight engineering rows. The remainder are recorded honestly
/// rather than left unreviewed: the `IM*` complex family needs a complex type, `BESSEL*`
/// needs special functions, and `CONVERT` is a unit table rather than a computation.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinEngineeringFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinEngineeringFunctions {

    /// All engineering primitives for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        bin2hex, bin2oct, hex2bin, hex2oct, oct2bin, oct2hex,
        bitAnd, bitOr, bitXor, bitLShift, bitRShift,
        delta, geStep,
        erf, erfPrecise, erfc, erfcPrecise
    ]

    // MARK: - Base conversion

    /// How wide a representation is, and therefore where its sign bit sits.
    ///
    /// Excel gives each base ten characters, so the value a string denotes depends on the
    /// base it is written in: ten binary digits is 10 bits, ten octal digits is 30, ten
    /// hexadecimal digits is 40. The top bit of that width is the sign.
    struct Base {
        let radix: Int
        let bits: Int
        let digits = 10

        static let binary = Base(radix: 2, bits: 10)
        static let octal = Base(radix: 8, bits: 30)
        static let hexadecimal = Base(radix: 16, bits: 40)

        /// The two's-complement range this width represents.
        var range: ClosedRange<Int> { -(1 << (bits - 1))...((1 << (bits - 1)) - 1) }
    }

    /// Reads a string in the given base as a signed value.
    ///
    /// **The top bit is a sign bit**, which is the part that is easy to get wrong and
    /// silently: `BIN2HEX(1111111111)` is `FFFFFFFFFF` because the input is −1, not 1023.
    /// Reading it as unsigned produces a plausible number wrong by 1024.
    static func value(of digits: String, in base: Base) -> Int? {
        let trimmed = digits.uppercased()
        guard !trimmed.isEmpty, trimmed.count <= base.digits,
              let magnitude = Int(trimmed, radix: base.radix) else { return nil }
        // Only a full-width string can be negative: a shorter one has no sign bit set.
        guard trimmed.count == base.digits, magnitude >= (1 << (base.bits - 1)) else {
            return magnitude
        }
        return magnitude - (1 << base.bits)
    }

    /// Writes a value in the given base, padded to `places` if asked.
    ///
    /// A negative value ignores `places` entirely and occupies the full width, because
    /// two's complement has no shorter form — Excel does the same.
    static func string(_ value: Int, in base: Base, places: Int?) -> CellValue {
        guard base.range.contains(value) else { return .error(.num) }

        if value < 0 {
            let complement = value + (1 << base.bits)
            return .text(String(complement, radix: base.radix, uppercase: true))
        }

        let digits = String(value, radix: base.radix, uppercase: true)
        guard let places else { return .text(digits) }
        guard places >= 0, places <= base.digits else { return .error(.num) }
        guard digits.count <= places else { return .error(.num) }
        return .text(String(repeating: "0", count: places - digits.count) + digits)
    }

    /// Builds a base-conversion function.
    static func conversion(_ name: String, from source: Base, to target: Base) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 1, maxArgs: 2) { values in
            if let error = firstError(values) { return error }
            guard let digits = string(values.first) else { return .error(.value) }
            guard let number = value(of: digits, in: source) else { return .error(.num) }

            var places: Int?
            if values.count > 1, case .number(let p) = values[1] {
                guard p >= 0, p.rounded(.towardZero) == p else { return .error(.num) }
                places = Int(p)
            }
            return string(number, in: target, places: places)
        }
    }

    /// `BIN2HEX(number, [places])` — binary to hexadecimal.
    public static let bin2hex = conversion("BIN2HEX", from: .binary, to: .hexadecimal)
    /// `BIN2OCT(number, [places])` — binary to octal.
    public static let bin2oct = conversion("BIN2OCT", from: .binary, to: .octal)
    /// `HEX2BIN(number, [places])` — hexadecimal to binary.
    public static let hex2bin = conversion("HEX2BIN", from: .hexadecimal, to: .binary)
    /// `HEX2OCT(number, [places])` — hexadecimal to octal.
    public static let hex2oct = conversion("HEX2OCT", from: .hexadecimal, to: .octal)
    /// `OCT2BIN(number, [places])` — octal to binary.
    public static let oct2bin = conversion("OCT2BIN", from: .octal, to: .binary)
    /// `OCT2HEX(number, [places])` — octal to hexadecimal.
    public static let oct2hex = conversion("OCT2HEX", from: .octal, to: .hexadecimal)

    // MARK: - Bitwise

    /// The bitwise family's domain: non-negative integers below 2⁴⁸.
    ///
    /// Excel refuses anything else with `#NUM!` rather than reinterpreting it — there is no
    /// two's complement here, so a negative is not a very large positive.
    static func bitOperand(_ value: CellValue?) -> Int? {
        guard case .number(let d)? = value, d >= 0, d < 281_474_976_710_656,
              d.rounded(.towardZero) == d else { return nil }
        return Int(d)
    }

    /// Builds a two-operand bitwise function.
    static func bitwise(_ name: String, _ body: @escaping @Sendable (Int, Int) -> Int) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 2, maxArgs: 2) { values in
            if let error = firstError(values) { return error }
            guard let lhs = bitOperand(values.first),
                  let rhs = bitOperand(values.dropFirst().first) else { return .error(.num) }
            return .number(Double(body(lhs, rhs)))
        }
    }

    /// `BITAND(number1, number2)`. Microsoft: `BITAND(13, 25)` is 9.
    public static let bitAnd = bitwise("BITAND") { $0 & $1 }
    /// `BITOR(number1, number2)`. Microsoft: `BITOR(23, 10)` is 31.
    public static let bitOr = bitwise("BITOR") { $0 | $1 }
    /// `BITXOR(number1, number2)`. Microsoft: `BITXOR(5, 3)` is 6.
    public static let bitXor = bitwise("BITXOR") { $0 ^ $1 }

    /// Builds a shift, where a negative amount reverses direction.
    static func shift(_ name: String, rightward: Bool) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 2, maxArgs: 2) { values in
            if let error = firstError(values) { return error }
            guard let number = bitOperand(values.first),
                  case .number(let rawAmount)? = values.dropFirst().first,
                  rawAmount.rounded(.towardZero) == rawAmount,
                  abs(rawAmount) <= 53 else { return .error(.num) }

            // A negative shift shifts the other way, which is why BITLSHIFT(4, -2) is 1.
            let amount = Int(rawAmount) * (rightward ? -1 : 1)
            let result = amount >= 0 ? number << amount : number >> (-amount)
            guard result >= 0, result < 281_474_976_710_656 else { return .error(.num) }
            return .number(Double(result))
        }
    }

    /// `BITLSHIFT(number, shift_amount)`. Microsoft: `BITLSHIFT(4, 2)` is 16.
    public static let bitLShift = shift("BITLSHIFT", rightward: false)
    /// `BITRSHIFT(number, shift_amount)`. Microsoft: `BITRSHIFT(13, 2)` is 3.
    public static let bitRShift = shift("BITRSHIFT", rightward: true)

    // MARK: - Step functions

    /// `DELTA(number1, [number2])` — 1 when the two are equal, 0 otherwise.
    ///
    /// The Kronecker delta. `number2` defaults to 0, so `DELTA(0)` is 1.
    public static let delta = ExcelFunction(name: "DELTA", minArgs: 1, maxArgs: 2) { values in
        if let error = firstError(values) { return error }
        guard let lhs = real(values.first) else { return .error(.value) }
        let rhs = values.count > 1 ? real(values[1]) : 0
        guard let rhs else { return .error(.value) }
        return .number(lhs == rhs ? 1 : 0)
    }

    /// `GESTEP(number, [step])` — 1 when `number ≥ step`, 0 otherwise.
    ///
    /// Microsoft: `GESTEP(-4, -5)` is 1 — the comparison is signed, so a less-negative
    /// number is greater.
    public static let geStep = ExcelFunction(name: "GESTEP", minArgs: 1, maxArgs: 2) { values in
        if let error = firstError(values) { return error }
        guard let number = real(values.first) else { return .error(.value) }
        let step = values.count > 1 ? real(values[1]) : 0
        guard let step else { return .error(.value) }
        return .number(number >= step ? 1 : 0)
    }

    // MARK: - The error function

    /// `ERF(lower_limit, [upper_limit])` — the error function integrated between limits.
    ///
    /// With one argument it integrates from zero. With two it is the difference of the
    /// one-argument forms, which is the definition rather than an implementation choice.
    public static let erf = ExcelFunction(name: "ERF", minArgs: 1, maxArgs: 2) { values in
        if let error = firstError(values) { return error }
        guard let lower = real(values.first) else { return .error(.value) }
        guard values.count > 1 else { return .number(Foundation.erf(lower)) }
        guard let upper = real(values[1]) else { return .error(.value) }
        return .number(Foundation.erf(upper) - Foundation.erf(lower))
    }

    /// `ERF.PRECISE(x)` — the error function from zero to `x`.
    public static let erfPrecise = ExcelFunction(name: "ERF.PRECISE", minArgs: 1, maxArgs: 1) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first) else { return .error(.value) }
        return .number(Foundation.erf(x))
    }

    /// `ERFC(x)` — the complementary error function, `1 − ERF(x)`.
    public static let erfc = ExcelFunction(name: "ERFC", minArgs: 1, maxArgs: 1) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first) else { return .error(.value) }
        return .number(Foundation.erfc(x))
    }

    /// `ERFC.PRECISE(x)` — the same function under the newer spelling.
    public static let erfcPrecise = ExcelFunction(name: "ERFC.PRECISE", minArgs: 1, maxArgs: 1) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first) else { return .error(.value) }
        return .number(Foundation.erfc(x))
    }

    // MARK: - Shared

    /// The first error among the arguments, propagated rather than absorbed.
    static func firstError(_ values: [CellValue]) -> CellValue? {
        values.first { if case .error = $0 { return true } else { return false } }
    }

    /// A finite number from a cell value.
    static func real(_ value: CellValue?) -> Double? {
        switch value {
        case .number(let d): return d.isFinite ? d : nil
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// The digits a value denotes, whether written as text or as a number.
    ///
    /// `BIN2HEX(1110)` passes a *number* whose decimal digits are the binary string, which
    /// is how a spreadsheet writes it without quotes. Formatting it back is what recovers
    /// the intent.
    static func string(_ value: CellValue?) -> String? {
        switch value {
        case .text(let t): return t
        case .number(let d):
            guard d.rounded(.towardZero) == d, abs(d) < 1e15 else { return nil }
            return String(Int(d))
        default: return nil
        }
    }
}
