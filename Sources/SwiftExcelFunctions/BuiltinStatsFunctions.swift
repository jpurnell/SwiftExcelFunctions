import Foundation
import SwiftExcelCore

/// Statistics category built-in Excel functions.
///
/// Provides implementations of 13 standard Excel statistical functions:
/// `AVERAGE`, `STDEV`, `STDEVP`, `MEDIAN`, `MIN`, `MAX`, `COUNT`, `COUNTA`,
/// `PERCENTILE`, `LARGE`, `SMALL`, `VAR`, and `VARP`.
///
/// Register all functions at once via ``all``:
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinStatsFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinStatsFunctions {

    /// All statistics functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        average, stdev, stdevp, median, min, max, count, counta,
        percentile, large, small, varFunc, varp,
    ]

    // MARK: - Helpers

    /// Flattens arrays and extracts numeric values from cell value arguments.
    ///
    /// Bools passed directly (not from a range) are treated as 1.0/0.0.
    /// Text, blank, date, and formula values are skipped.
    ///
    /// - Parameter args: The cell value arguments to process.
    /// - Returns: An array of `Double` values extracted from the arguments.
    private static func flattenNumbers(_ args: [CellValue]) -> [Double] {
        var result: [Double] = []
        for arg in args {
            switch arg {
            case .number(let n):
                result.append(n)
            case .array(let items):
                result.append(contentsOf: flattenNumbers(items))
            case .bool(let b):
                result.append(b ? 1.0 : 0.0)
            case .blank, .text, .error, .formula, .date:
                continue
            }
        }
        return result
    }

    /// Checks all arguments (including inside arrays) for any error values.
    ///
    /// Returns the first error found, or `nil` if no errors are present.
    ///
    /// - Parameter args: The cell value arguments to scan.
    /// - Returns: The first `ExcelError` found, or `nil`.
    private static func findFirstError(_ args: [CellValue]) -> ExcelError? {
        for arg in args {
            switch arg {
            case .error(let e):
                return e
            case .array(let items):
                if let e = findFirstError(items) {
                    return e
                }
            case .formula(_, let cached):
                if let cached = cached, case .error(let e) = cached {
                    return e
                }
            default:
                continue
            }
        }
        return nil
    }

    /// Flattens arrays and counts values according to the given predicate.
    ///
    /// - Parameters:
    ///   - args: The cell value arguments to process.
    ///   - predicate: A closure determining whether a value should be counted.
    /// - Returns: The count of matching values.
    private static func flatCount(_ args: [CellValue],
                                  where predicate: (CellValue) -> Bool) -> Double {
        var count = 0.0
        for arg in args {
            switch arg {
            case .array(let items):
                count += flatCount(items, where: predicate)
            default:
                if predicate(arg) {
                    count += 1
                }
            }
        }
        return count
    }

    private static func safeDivide(_ numerator: Double, _ denominator: Double) throws -> Double {
        guard denominator != 0 else { throw EvalError.div0Error }
        return numerator / denominator
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
            return .error(.value)
        }
    }

    // MARK: - AVERAGE

    /// `AVERAGE(number1, [number2], ...)` -- returns the arithmetic mean of numeric values.
    ///
    /// Ignores text and blank cells. Returns `#DIV/0!` if no numeric values are found.
    /// Error values in arguments are propagated.
    static let average = ExcelFunction(name: "AVERAGE", minArgs: 1, maxArgs: nil) { args in
        catching {
            if let e = findFirstError(args) { throw EvalError.excelError(e) }
            let numbers = flattenNumbers(args)
            guard !numbers.isEmpty else { throw EvalError.div0Error }
            let sum = numbers.reduce(0.0, +)
            return .number(try safeDivide(sum, Double(numbers.count)))
        }
    }

    // MARK: - STDEV (sample)

    /// `STDEV(number1, [number2], ...)` -- returns the sample standard deviation (n-1).
    ///
    /// Requires at least two numeric values. Returns `#DIV/0!` otherwise.
    /// Error values in arguments are propagated.
    static let stdev = ExcelFunction(name: "STDEV", minArgs: 1, maxArgs: nil) { args in
        catching {
            if let e = findFirstError(args) { throw EvalError.excelError(e) }
            let numbers = flattenNumbers(args)
            let count = Double(numbers.count)
            guard count >= 2 else { throw EvalError.div0Error }
            let mean = try safeDivide(numbers.reduce(0.0, +), count)
            let sumSqDev = numbers.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            let variance = try safeDivide(sumSqDev, count - 1)
            return .number(variance.squareRoot())
        }
    }

    // MARK: - STDEVP (population)

    /// `STDEVP(number1, [number2], ...)` -- returns the population standard deviation (n).
    ///
    /// Requires at least one numeric value. Returns `#DIV/0!` if none found.
    /// Error values in arguments are propagated.
    static let stdevp = ExcelFunction(name: "STDEVP", minArgs: 1, maxArgs: nil) { args in
        catching {
            if let e = findFirstError(args) { throw EvalError.excelError(e) }
            let numbers = flattenNumbers(args)
            guard !numbers.isEmpty else { throw EvalError.div0Error }
            let count = Double(numbers.count)
            let mean = try safeDivide(numbers.reduce(0.0, +), count)
            let sumSqDev = numbers.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            let variance = try safeDivide(sumSqDev, count)
            return .number(variance.squareRoot())
        }
    }

    // MARK: - MEDIAN

    /// `MEDIAN(number1, [number2], ...)` -- returns the middle value of the sorted numeric values.
    ///
    /// For an even count, returns the average of the two middle values.
    /// Returns `#NUM!` if no numeric values are found.
    /// Error values in arguments are propagated.
    static let median = ExcelFunction(name: "MEDIAN", minArgs: 1, maxArgs: nil) { args in
        catching {
            if let e = findFirstError(args) { throw EvalError.excelError(e) }
            let numbers = flattenNumbers(args).sorted()
            guard !numbers.isEmpty else { throw EvalError.numError }
            let n = numbers.count
            if n % 2 == 1 {
                return .number(numbers[n / 2])
            } else {
                return .number((numbers[n / 2 - 1] + numbers[n / 2]) / 2.0)
            }
        }
    }

    // MARK: - MIN

    /// `MIN(number1, [number2], ...)` -- returns the smallest numeric value.
    ///
    /// Ignores text and blank cells. Returns 0 if no numeric values are found.
    /// Error values in arguments are propagated.
    static let min = ExcelFunction(name: "MIN", minArgs: 1, maxArgs: nil) { args in
        catching {
            if let e = findFirstError(args) { throw EvalError.excelError(e) }
            let numbers = flattenNumbers(args)
            guard let result = numbers.min() else { return .number(0) }
            return .number(result)
        }
    }

    // MARK: - MAX

    /// `MAX(number1, [number2], ...)` -- returns the largest numeric value.
    ///
    /// Ignores text and blank cells. Returns 0 if no numeric values are found.
    /// Error values in arguments are propagated.
    static let max = ExcelFunction(name: "MAX", minArgs: 1, maxArgs: nil) { args in
        catching {
            if let e = findFirstError(args) { throw EvalError.excelError(e) }
            let numbers = flattenNumbers(args)
            guard let result = numbers.max() else { return .number(0) }
            return .number(result)
        }
    }

    // MARK: - COUNT

    /// `COUNT(value1, [value2], ...)` -- counts the number of numeric values.
    ///
    /// Counts numbers and dates. Ignores text, blank, bool, and error values.
    static let count = ExcelFunction(name: "COUNT", minArgs: 1, maxArgs: nil) { args in
        let n = flatCount(args) { value in
            switch value {
            case .number: return true
            case .date: return true
            default: return false
            }
        }
        return .number(n)
    }

    // MARK: - COUNTA

    /// `COUNTA(value1, [value2], ...)` -- counts the number of non-blank values.
    ///
    /// Everything except `.blank` counts, including errors.
    static let counta = ExcelFunction(name: "COUNTA", minArgs: 1, maxArgs: nil) { args in
        let n = flatCount(args) { value in
            if case .blank = value { return false }
            return true
        }
        return .number(n)
    }

    // MARK: - PERCENTILE

    /// `PERCENTILE(array, k)` -- returns the k-th percentile of the data.
    ///
    /// Uses Excel's linear interpolation method. `k` must be between 0 and 1 inclusive.
    /// Returns `#NUM!` if `k` is out of range or the data array contains no numbers.
    /// Error values in the array are propagated.
    static let percentile = ExcelFunction(name: "PERCENTILE", minArgs: 2, maxArgs: 2) { args in
        catching {
            if let e = findFirstError([args[0]]) { throw EvalError.excelError(e) }
            guard case .number(let k) = args[1] else {
                if case .error(let e) = args[1] { throw EvalError.excelError(e) }
                throw EvalError.typeMismatch
            }
            guard k >= 0, k <= 1 else { throw EvalError.numError }

            let numbers = flattenNumbers([args[0]]).sorted()
            guard !numbers.isEmpty else { throw EvalError.numError }

            let n = numbers.count
            if n == 1 { return .number(numbers[0]) }

            let rank = k * Double(n - 1)
            let intPart = Int(rank)
            let fracPart = rank - Double(intPart)

            if intPart >= n - 1 {
                return .number(numbers[n - 1])
            }

            let result = numbers[intPart] + fracPart * (numbers[intPart + 1] - numbers[intPart])
            return .number(result)
        }
    }

    // MARK: - LARGE

    /// `LARGE(array, k)` -- returns the k-th largest value from the data.
    ///
    /// `k` must be between 1 and the count of numeric values inclusive.
    /// Returns `#NUM!` if `k` is out of range or the data array is empty.
    /// Error values in the array are propagated.
    static let large = ExcelFunction(name: "LARGE", minArgs: 2, maxArgs: 2) { args in
        catching {
            if let e = findFirstError([args[0]]) { throw EvalError.excelError(e) }
            guard case .number(let kDouble) = args[1] else {
                if case .error(let e) = args[1] { throw EvalError.excelError(e) }
                throw EvalError.typeMismatch
            }
            let k = Int(kDouble)
            guard k >= 1 else { throw EvalError.numError }

            let sorted = flattenNumbers([args[0]]).sorted(by: >)
            guard k <= sorted.count else { throw EvalError.numError }
            return .number(sorted[k - 1])
        }
    }

    // MARK: - SMALL

    /// `SMALL(array, k)` -- returns the k-th smallest value from the data.
    ///
    /// `k` must be between 1 and the count of numeric values inclusive.
    /// Returns `#NUM!` if `k` is out of range or the data array is empty.
    /// Error values in the array are propagated.
    static let small = ExcelFunction(name: "SMALL", minArgs: 2, maxArgs: 2) { args in
        catching {
            if let e = findFirstError([args[0]]) { throw EvalError.excelError(e) }
            guard case .number(let kDouble) = args[1] else {
                if case .error(let e) = args[1] { throw EvalError.excelError(e) }
                throw EvalError.typeMismatch
            }
            let k = Int(kDouble)
            guard k >= 1 else { throw EvalError.numError }

            let sorted = flattenNumbers([args[0]]).sorted()
            guard k <= sorted.count else { throw EvalError.numError }
            return .number(sorted[k - 1])
        }
    }

    // MARK: - VAR (sample variance)

    /// `VAR(number1, [number2], ...)` -- returns the sample variance (n-1).
    ///
    /// Requires at least two numeric values. Returns `#DIV/0!` otherwise.
    /// Error values in arguments are propagated.
    static let varFunc = ExcelFunction(name: "VAR", minArgs: 1, maxArgs: nil) { args in
        catching {
            if let e = findFirstError(args) { throw EvalError.excelError(e) }
            let numbers = flattenNumbers(args)
            let count = Double(numbers.count)
            guard count >= 2 else { throw EvalError.div0Error }
            let mean = try safeDivide(numbers.reduce(0.0, +), count)
            let sumSqDev = numbers.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            return .number(try safeDivide(sumSqDev, count - 1))
        }
    }

    // MARK: - VARP (population variance)

    /// `VARP(number1, [number2], ...)` -- returns the population variance (n).
    ///
    /// Requires at least one numeric value. Returns `#DIV/0!` if none found.
    /// Error values in arguments are propagated.
    static let varp = ExcelFunction(name: "VARP", minArgs: 1, maxArgs: nil) { args in
        catching {
            if let e = findFirstError(args) { throw EvalError.excelError(e) }
            let numbers = flattenNumbers(args)
            guard !numbers.isEmpty else { throw EvalError.div0Error }
            let count = Double(numbers.count)
            let mean = try safeDivide(numbers.reduce(0.0, +), count)
            let sumSqDev = numbers.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) }
            return .number(try safeDivide(sumSqDev, count))
        }
    }
}
