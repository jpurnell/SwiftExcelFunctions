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

        let span = top - bottom + 1
        let offset = Int(random.nextUniform() * Double(span))
        return .number(Double(bottom + Swift.min(offset, span - 1)))
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
}
