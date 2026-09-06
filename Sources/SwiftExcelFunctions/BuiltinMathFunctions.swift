import Foundation
import SwiftExcelCore

/// Math category built-in Excel functions.
///
/// Provides implementations of 15 standard Excel math functions:
/// `ABS`, `ROUND`, `ROUNDUP`, `ROUNDDOWN`, `SQRT`, `LN`, `LOG`, `EXP`,
/// `POWER`, `MOD`, `INT`, `CEILING`, `FLOOR`, `SIGN`, and `PI`.
///
/// Register all functions at once via ``all``:
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinMathFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinMathFunctions {

    /// All math functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        abs, round, roundUp, roundDown, sqrt, ln, log, exp,
        power, mod, intFunc, ceiling, floor, sign, pi,
        rand, randbetween,
        sin, cos, tan, asin, acos, atan, atan2, log10, trunc, product, gcd, lcm,
        dec2hex, dec2bin, dec2oct, hex2dec, bin2dec, oct2dec, baseFunc, decimalFunc,
    ]

    // MARK: - Randomness

    /// `RAND()` — a uniform value in `[0, 1)`.
    ///
    /// The value comes from the caller's ``RandomSource``; this package has none
    /// of its own. With no source the answer is `#VALUE!`, on the same principle
    /// as `COLUMN()` outside a sheet: report rather than invent.
    ///
    /// Excel is not imitated, because it cannot be — it exposes no seed, so there
    /// is no sequence to match. Only the contract is observable, and only the
    /// contract is promised. With a seeded source `RAND()` also stops being
    /// volatile, which is a real difference from Excel and the better behaviour
    /// for a translation layer.
    public static let rand = ExcelFunction(name: "RAND", minArgs: 0, maxArgs: 0) { context, _ in
        guard let random = context.random else { return .error(.value) }
        return .number(random.nextUniform())
    }

    /// `RANDBETWEEN(bottom, top)` — a uniform integer, both bounds inclusive.
    ///
    /// Inclusive at both ends is the part worth testing: scaling a draw from
    /// `[0, 1)` across `top - bottom + 1` values reaches `top` exactly when the
    /// draw approaches one, and never overshoots because the interval is
    /// half-open.
    public static let randbetween = ExcelFunction(
        name: "RANDBETWEEN", minArgs: 2, maxArgs: 2
    ) { context, args in
        guard let random = context.random else { return .error(.value) }
        guard case .number(let bottomValue) = args[0],
              case .number(let topValue) = args[1] else { return .error(.value) }

        let bottom = Int(bottomValue.rounded(.up))
        let top = Int(topValue.rounded(.down))
        guard bottom <= top else { return .error(.num) }

        // An integer draw rather than a scaled double. Scaling is modulo bias in
        // another form — some outcomes would come from a wider band of doubles
        // than others, and a range that does not divide evenly would lean.
        let span = top - bottom + 1
        return .number(Double(bottom + random.nextInteger(below: span)))
    }

    // MARK: - Type coercion

    /// Extracts a `Double` from a `CellValue`, applying Excel-style type coercion.
    ///
    /// - Parameter value: The cell value to convert.
    /// - Returns: The numeric representation.
    /// - Throws: ``EvalError/typeMismatch`` if the value cannot be converted,
    ///   or ``EvalError/excelError(_:)`` if the value is an Excel error.
    private static func toNumber(_ value: CellValue) throws -> Double {
        switch value {
        case .number(let n):
            return n
        case .text(let s):
            guard let n = Double(s) else {
                throw EvalError.typeMismatch
            }
            return n
        case .bool(let b):
            return b ? 1.0 : 0.0
        case .blank:
            return 0.0
        case .error(let e):
            throw EvalError.excelError(e)
        case .date(let d):
            // Excel serial date: days since 1900-01-01
            return d.timeIntervalSinceReferenceDate / 86_400.0
        case .formula(_, let cached):
            return try toNumber(cached ?? .blank)
        case .array:
            throw EvalError.typeMismatch
        }
    }

    /// Wraps function body so that ``EvalError`` maps to the correct ``CellValue/error(_:)``.
    private static func catching(_ body: () throws -> CellValue) -> CellValue {
        do {
            return try body()
        } catch EvalError.excelError(let e) {
            return .error(e)
        } catch EvalError.numError {
            return .error(.num)
        } catch EvalError.div0Error {
            return .error(.div0)
        } catch {
            // typeMismatch and anything else
            return .error(.value)
        }
    }

    // MARK: - ABS

    /// `ABS(number)` -- returns the absolute value of a number.
    static let abs = ExcelFunction(name: "ABS", minArgs: 1, maxArgs: 1) { args in
        catching {
            let n = try toNumber(args[0])
            return .number(Swift.abs(n))
        }
    }

    // MARK: - ROUND

    /// `ROUND(number, num_digits)` -- rounds a number to a specified number of digits.
    ///
    /// Negative `num_digits` rounds to the left of the decimal point
    /// (e.g., `ROUND(1234, -2)` = 1200).
    static let round = ExcelFunction(name: "ROUND", minArgs: 2, maxArgs: 2) { args in
        catching {
            let number = try toNumber(args[0])
            let digits = try toNumber(args[1])
            let d = Foundation.round(digits)
            let factor = Foundation.pow(10.0, d)
            return .number(Foundation.round(number * factor) / factor)
        }
    }

    // MARK: - ROUNDUP

    /// `ROUNDUP(number, num_digits)` -- rounds a number away from zero.
    static let roundUp = ExcelFunction(name: "ROUNDUP", minArgs: 2, maxArgs: 2) { args in
        catching {
            let number = try toNumber(args[0])
            let digits = try toNumber(args[1])
            let d = Foundation.round(digits)
            let factor = Foundation.pow(10.0, d)
            // Away from zero: positive numbers ceiling, negative numbers floor
            if number >= 0 {
                return .number(Foundation.ceil(number * factor) / factor)
            } else {
                return .number(Foundation.floor(number * factor) / factor)
            }
        }
    }

    // MARK: - ROUNDDOWN

    /// `ROUNDDOWN(number, num_digits)` -- rounds a number toward zero (truncates).
    static let roundDown = ExcelFunction(name: "ROUNDDOWN", minArgs: 2, maxArgs: 2) { args in
        catching {
            let number = try toNumber(args[0])
            let digits = try toNumber(args[1])
            let d = Foundation.round(digits)
            let factor = Foundation.pow(10.0, d)
            // Toward zero: positive numbers floor, negative numbers ceiling
            if number >= 0 {
                return .number(Foundation.floor(number * factor) / factor)
            } else {
                return .number(Foundation.ceil(number * factor) / factor)
            }
        }
    }

    // MARK: - SQRT

    /// `SQRT(number)` -- returns the square root of a number.
    ///
    /// Returns `#NUM!` if the argument is negative.
    static let sqrt = ExcelFunction(name: "SQRT", minArgs: 1, maxArgs: 1) { args in
        catching {
            let n = try toNumber(args[0])
            guard n >= 0 else { throw EvalError.numError }
            return .number(Foundation.sqrt(n))
        }
    }

    // MARK: - LN

    /// `LN(number)` -- returns the natural logarithm of a number.
    ///
    /// Returns `#NUM!` if the argument is zero or negative.
    static let ln = ExcelFunction(name: "LN", minArgs: 1, maxArgs: 1) { args in
        catching {
            let n = try toNumber(args[0])
            guard n > 0 else { throw EvalError.numError }
            return .number(Foundation.log(n))
        }
    }

    // MARK: - LOG

    /// `LOG(number [, base])` -- returns the logarithm of a number to a specified base.
    ///
    /// With one argument, returns the base-10 logarithm.
    /// Returns `#NUM!` if `number` is non-positive.
    static let log = ExcelFunction(name: "LOG", minArgs: 1, maxArgs: 2) { args in
        catching {
            let number = try toNumber(args[0])
            guard number > 0 else { throw EvalError.numError }
            if args.count == 1 {
                return .number(Foundation.log10(number))
            }
            let base = try toNumber(args[1])
            // Exact IEEE 754 comparison, deliberately: only base 1.0 makes log(base) exactly
            // zero and the division below undefined. Excel likewise rejects 1 alone, returning
            // very large values for bases merely near it, so an epsilon band would be wrong.
            guard base > 0, !base.isEqual(to: 1) else { throw EvalError.numError }
            return .number(Foundation.log(number) / Foundation.log(base))
        }
    }

    // MARK: - EXP

    /// `EXP(number)` -- returns *e* raised to the power of the given number.
    static let exp = ExcelFunction(name: "EXP", minArgs: 1, maxArgs: 1) { args in
        catching {
            let n = try toNumber(args[0])
            return .number(Foundation.exp(n))
        }
    }

    // MARK: - POWER

    /// `POWER(number, power)` -- returns a number raised to a power.
    static let power = ExcelFunction(name: "POWER", minArgs: 2, maxArgs: 2) { args in
        catching {
            let base = try toNumber(args[0])
            let exponent = try toNumber(args[1])
            let result = Foundation.pow(base, exponent)
            guard result.isFinite else { throw EvalError.numError }
            return .number(result)
        }
    }

    // MARK: - MOD

    /// `MOD(number, divisor)` -- returns the remainder after division.
    ///
    /// Unlike Swift's `%` operator, Excel's `MOD` always returns a result
    /// with the same sign as the divisor:
    /// `MOD(-7, 3) = 2` (not `-1`).
    ///
    /// Returns `#DIV/0!` when the divisor is zero.
    static let mod = ExcelFunction(name: "MOD", minArgs: 2, maxArgs: 2) { args in
        catching {
            let number = try toNumber(args[0])
            let divisor = try toNumber(args[1])
            guard divisor != 0 else { throw EvalError.div0Error }
            // Excel MOD: number - divisor * INT(number / divisor)
            let result = number - divisor * Foundation.floor(number / divisor)
            return .number(result)
        }
    }

    // MARK: - INT

    /// `INT(number)` -- rounds a number down to the nearest integer (toward negative infinity).
    ///
    /// `INT(3.7) = 3`, `INT(-3.7) = -4`.
    static let intFunc = ExcelFunction(name: "INT", minArgs: 1, maxArgs: 1) { args in
        catching {
            let n = try toNumber(args[0])
            return .number(Foundation.floor(n))
        }
    }

    // MARK: - CEILING

    /// `CEILING(number, significance)` -- rounds a number up to the nearest multiple of significance.
    ///
    /// When significance is zero, returns zero.
    static let ceiling = ExcelFunction(name: "CEILING", minArgs: 2, maxArgs: 2) { args in
        catching {
            let number = try toNumber(args[0])
            let significance = try toNumber(args[1])
            guard significance != 0 else { return .number(0) }
            return .number(Foundation.ceil(number / significance) * significance)
        }
    }

    // MARK: - FLOOR

    /// `FLOOR(number, significance)` -- rounds a number down to the nearest multiple of significance.
    ///
    /// For positive significance, rounds toward negative infinity.
    /// When both number and significance are negative, rounds away from zero.
    static let floor = ExcelFunction(name: "FLOOR", minArgs: 2, maxArgs: 2) { args in
        catching {
            let number = try toNumber(args[0])
            let significance = try toNumber(args[1])
            guard significance != 0 else { throw EvalError.div0Error }
            // When significance > 0: floor(n/s)*s rounds toward -inf
            // When significance < 0: ceil(n/s)*s rounds toward -inf for the multiple
            if significance > 0 {
                return .number(Foundation.floor(number / significance) * significance)
            } else {
                return .number(Foundation.ceil(number / significance) * significance)
            }
        }
    }

    // MARK: - SIGN

    /// `SIGN(number)` -- returns the sign of a number: 1, 0, or -1.
    static let sign = ExcelFunction(name: "SIGN", minArgs: 1, maxArgs: 1) { args in
        catching {
            let n = try toNumber(args[0])
            if n > 0 { return .number(1) }
            if n < 0 { return .number(-1) }
            return .number(0)
        }
    }

    // MARK: - PI

    /// `PI()` -- returns the value of pi (3.14159265358979...).
    static let pi = ExcelFunction(name: "PI", minArgs: 0, maxArgs: 0) { _ in
        .number(Double.pi)
    }

    // MARK: - Trigonometry and logs, bridged to Foundation

    // These are libm's, reached through Foundation. Excel's contract is the same as
    // C's — radians, principal values — so there is nothing to translate and a
    // second implementation of a sine would be a liability with no upside. The
    // bridging *is* the work: arity, coercion, and Excel's errors.

    /// `SIN(number)` — the sine of an angle in radians.
    public static let sin = unary("SIN") { Foundation.sin($0) }

    /// `COS(number)` — the cosine of an angle in radians.
    public static let cos = unary("COS") { Foundation.cos($0) }

    /// `TAN(number)` — the tangent of an angle in radians.
    public static let tan = unary("TAN") { Foundation.tan($0) }

    /// `ASIN(number)` — the arcsine, in radians. `#NUM!` outside −1…1.
    public static let asin = unary("ASIN", domain: { (-1.0...1.0).contains($0) }) {
        Foundation.asin($0)
    }

    /// `ACOS(number)` — the arccosine, in radians. `#NUM!` outside −1…1.
    public static let acos = unary("ACOS", domain: { (-1.0...1.0).contains($0) }) {
        Foundation.acos($0)
    }

    /// `ATAN(number)` — the arctangent, in radians.
    public static let atan = unary("ATAN") { Foundation.atan($0) }

    /// `ATAN2(x, y)` — the arctangent of `y/x`, using both signs to place the
    /// quadrant.
    ///
    /// Excel takes **x first**, which is the reverse of C's `atan2(y, x)` and of
    /// most other languages'. Getting it backwards is a silent quadrant error, so
    /// the argument order is the whole of what this binding has to get right.
    public static let atan2 = ExcelFunction(name: "ATAN2", minArgs: 2, maxArgs: 2) { args in
        if let error = firstError(args) { return error }
        let x = try toNumber(args[0])
        let y = try toNumber(args[1])
        guard x != 0 || y != 0 else { return .error(.div0) }
        return .number(Foundation.atan2(y, x))
    }

    /// `LOG10(number)` — the base-10 logarithm. `#NUM!` at or below zero.
    public static let log10 = unary("LOG10", domain: { $0 > 0 }) { Foundation.log10($0) }

    /// `TRUNC(number, [digits])` — cuts toward zero.
    ///
    /// Not `INT`, which rounds *down*: they agree on positives and differ on
    /// negatives, where `TRUNC(-8.9)` is −8 and `INT(-8.9)` is −9. That difference is
    /// the only reason Excel has both.
    public static let trunc = ExcelFunction(name: "TRUNC", minArgs: 1, maxArgs: 2) { args in
        if let error = firstError(args) { return error }
        let value = try toNumber(args[0])
        let digits = args.count > 1 ? Int(try toNumber(args[1])) : 0
        let scale = pow(10.0, Double(digits))
        return .number((value * scale).rounded(.towardZero) / scale)
    }

    /// `PRODUCT(number1, [number2], ...)` — everything multiplied together.
    ///
    /// Inside a range only numbers count; blanks and text are ignored rather than
    /// treated as zero, which would take every product to nothing.
    public static let product = ExcelFunction(
        name: "PRODUCT", minArgs: 1, maxArgs: nil
    ) { args in
        if let error = firstError(args) { return error }
        var total = 1.0
        var seen = false
        for argument in args {
            for value in numbers(in: argument) {
                total *= value
                seen = true
            }
        }
        return .number(seen ? total : 0)
    }

    /// `GCD(number1, [number2], ...)` — the greatest common divisor.
    ///
    /// Arguments are truncated to integers, as Excel does, and must not be negative.
    public static let gcd = ExcelFunction(name: "GCD", minArgs: 1, maxArgs: nil) { args in
        if let error = firstError(args) { return error }
        var result = 0
        for argument in args {
            for value in numbers(in: argument) {
                let whole = Int(value.rounded(.towardZero))
                guard whole >= 0 else { return .error(.num) }
                result = greatestCommonDivisor(result, whole)
            }
        }
        return .number(Double(result))
    }

    /// `LCM(number1, [number2], ...)` — the least common multiple.
    public static let lcm = ExcelFunction(name: "LCM", minArgs: 1, maxArgs: nil) { args in
        if let error = firstError(args) { return error }
        var result = 1
        for argument in args {
            for value in numbers(in: argument) {
                let whole = Int(value.rounded(.towardZero))
                guard whole >= 0 else { return .error(.num) }
                guard whole != 0 else { return .number(0) }
                let divisor = greatestCommonDivisor(result, whole)
                guard divisor != 0 else { continue }
                result = result / divisor * whole
            }
        }
        return .number(Double(result))
    }

    /// Euclid's algorithm, iterative so it needs no base-case guard.
    ///
    /// - Parameters:
    ///   - lhs: One number.
    ///   - rhs: The other.
    /// - Returns: Their greatest common divisor.
    private static func greatestCommonDivisor(_ lhs: Int, _ rhs: Int) -> Int {
        var a = Swift.abs(lhs)
        var b = Swift.abs(rhs)
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return a
    }

    /// The numbers inside an argument, ignoring anything that is not one.
    ///
    /// - Parameter value: The argument.
    /// - Returns: Its numeric elements, or itself if it is a number.
    private static func numbers(in value: CellValue) -> [Double] {
        switch value {
        case .number(let number):
            return [number]
        case .array(let matrix):
            return matrix.elements.flatMap { element -> [Double] in
                if case .number(let number) = element { return [number] }
                return []
            }
        case .bool(let flag):
            return [flag ? 1 : 0]
        default:
            return []
        }
    }

    /// A one-argument numeric function, with Excel's coercion and errors.
    ///
    /// - Parameters:
    ///   - name: The Excel name.
    ///   - domain: What the function accepts; anything else is `#NUM!`.
    ///   - body: The computation.
    /// - Returns: The registered function.
    private static func unary(
        _ name: String,
        domain: (@Sendable (Double) -> Bool)? = nil,
        body: @escaping @Sendable (Double) -> Double
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 1, maxArgs: 1) { args in
            if let error = firstError(args) { return error }
            let value = try toNumber(args[0])
            if let domain, !domain(value) { return .error(.num) }
            let result = body(value)
            guard result.isFinite else { return .error(.num) }
            return .number(result)
        }
    }

    /// The first argument that is an error, if any.
    private static func firstError(_ args: [CellValue]) -> CellValue? {
        for argument in args {
            if case .error = argument { return argument }
        }
        return nil
    }

    // MARK: - Base conversion

    // Excel's engineering conversions work in two's complement over ten digits, so
    // `DEC2HEX(-1)` is `FFFFFFFFFF` rather than `-1`. The range that fits is
    // −2³⁹ … 2³⁹−1, and anything outside it is `#NUM!`.

    /// The width Excel's DEC2* functions work in: ten digits of the target base's
    /// nibble, which is forty bits.
    private static let engineeringBits = 40

    /// `DEC2HEX(number, [places])` — a decimal as hexadecimal.
    public static let dec2hex = toBase("DEC2HEX", radix: 16)

    /// `DEC2BIN(number, [places])` — a decimal as binary. Excel's range here is only
    /// −512…511, ten binary digits rather than ten hex ones.
    public static let dec2bin = toBase("DEC2BIN", radix: 2, bits: 10)

    /// `DEC2OCT(number, [places])` — a decimal as octal.
    public static let dec2oct = toBase("DEC2OCT", radix: 8, bits: 30)

    /// `HEX2DEC(number)` — hexadecimal back to decimal, reading the top bit as sign.
    public static let hex2dec = fromBase("HEX2DEC", radix: 16, digits: 10)

    /// `BIN2DEC(number)` — binary back to decimal.
    public static let bin2dec = fromBase("BIN2DEC", radix: 2, digits: 10)

    /// `OCT2DEC(number)` — octal back to decimal.
    public static let oct2dec = fromBase("OCT2DEC", radix: 8, digits: 10)

    /// `BASE(number, radix, [min_length])` — a number in any base from 2 to 36.
    ///
    /// Unlike the `DEC2*` family this is unsigned and has no two's-complement
    /// wrapping: a negative number is `#NUM!` rather than a large positive one.
    public static let baseFunc = ExcelFunction(name: "BASE", minArgs: 2, maxArgs: 3) { args in
        if let error = firstError(args) { return error }
        let value = try toNumber(args[0])
        let radix = Int(try toNumber(args[1]))
        guard value >= 0, (2...36).contains(radix) else { return .error(.num) }
        var digits = String(Int(value.rounded(.towardZero)), radix: radix).uppercased()
        if args.count > 2 {
            let minimum = Int(try toNumber(args[2]))
            guard minimum >= 0 else { return .error(.num) }
            while digits.count < minimum { digits = "0" + digits }
        }
        return .text(digits)
    }

    /// `DECIMAL(text, radix)` — the inverse of ``baseFunc``.
    public static let decimalFunc = ExcelFunction(
        name: "DECIMAL", minArgs: 2, maxArgs: 2
    ) { args in
        if let error = firstError(args) { return error }
        guard case .text(let digits) = args[0].resolved else { return .error(.value) }
        let radix = Int(try toNumber(args[1]))
        guard (2...36).contains(radix),
              let value = Int(digits.trimmingCharacters(in: .whitespaces), radix: radix)
        else { return .error(.num) }
        return .number(Double(value))
    }

    /// A `DEC2*` conversion.
    ///
    /// - Parameters:
    ///   - name: The Excel name.
    ///   - radix: The target base.
    ///   - bits: How wide the two's-complement window is.
    /// - Returns: The registered function.
    private static func toBase(_ name: String, radix: Int, bits: Int? = nil) -> ExcelFunction {
        let width = bits ?? engineeringBits
        return ExcelFunction(name: name, minArgs: 1, maxArgs: 2) { args in
            if let error = firstError(args) { return error }
            let value = Int(try toNumber(args[0]).rounded(.towardZero))
            let limit = 1 << (width - 1)
            guard value >= -limit, value < limit else { return .error(.num) }
            // Negatives wrap into the window, which is what makes DEC2HEX(-1) read
            // as all Fs rather than as a signed literal.
            let unsigned = value < 0 ? (1 << width) + value : value
            var digits = String(unsigned, radix: radix).uppercased()
            if args.count > 1 {
                let places = Int(try toNumber(args[1]))
                guard places >= 0, places >= digits.count, value >= 0 else {
                    return .error(.num)
                }
                while digits.count < places { digits = "0" + digits }
            }
            return .text(digits)
        }
    }

    /// A `*2DEC` conversion.
    ///
    /// - Parameters:
    ///   - name: The Excel name.
    ///   - radix: The source base.
    ///   - digits: How many digits the window holds.
    /// - Returns: The registered function.
    private static func fromBase(_ name: String, radix: Int, digits: Int) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 1, maxArgs: 1) { args in
            if let error = firstError(args) { return error }
            let text: String
            switch args[0].resolved {
            case .text(let value): text = value.trimmingCharacters(in: .whitespaces)
            case .number(let value): text = String(Int(value))
            case .blank: text = "0"
            default: return .error(.value)
            }
            guard text.count <= digits, let raw = Int(text, radix: radix) else {
                return .error(.num)
            }
            // The top digit carries the sign, the same window the DEC2* side writes.
            let width = digits * Int(log2(Double(radix)).rounded())
            let limit = 1 << (width - 1)
            return .number(Double(raw >= limit ? raw - (1 << width) : raw))
        }
    }
}
