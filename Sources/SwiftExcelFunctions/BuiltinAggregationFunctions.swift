import Foundation
import SwiftExcelCore

/// Aggregation category built-in Excel functions.
///
/// Provides implementations of 6 standard Excel aggregation functions:
/// `SUM`, `SUMIF`, `SUMIFS`, `COUNTIF`, `COUNTIFS`, and `AVERAGEIF`.
///
/// Register all functions at once via ``all``:
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinAggregationFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinAggregationFunctions {

    /// All aggregation functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        sum, sumif, sumifs, countif, countifs, averageif, sumproduct, sumsq,
    ]

    // MARK: - Products

    /// `SUMPRODUCT(array1, [array2], …)` — multiply element by element, then sum.
    ///
    /// A dot product, which is how a spreadsheet writes an objective function or
    /// a constraint row. Only 805 calls in the corpus but spread over **134
    /// sheets** — wider than any other function this package lacked, because
    /// almost every optimisation model has one.
    ///
    /// Non-numeric entries count as zero rather than erroring. That is Excel's
    /// rule and it matters: a label at the head of a row would otherwise poison
    /// the whole product.
    ///
    /// Arrays of different lengths are `#VALUE!`. Pairing them off by position
    /// and ignoring the tail would answer a question nobody asked.
    public static let sumproduct = ExcelFunction(
        name: "SUMPRODUCT", minArgs: 1, maxArgs: nil
    ) { args in
        let arrays = args.map { toArray($0) }
        guard let width = arrays.first?.count else { return .number(0) }
        guard arrays.allSatisfy({ $0.count == width }) else { return .error(.value) }

        var total = 0.0
        for index in 0..<width {
            var product = 1.0
            for array in arrays {
                // Anything that is not a number contributes zero, so the whole
                // term drops out rather than the whole sum failing.
                guard case .number(let value) = array[index] else {
                    product = 0
                    break
                }
                product *= value
            }
            total += product
        }
        return .number(total)
    }

    /// `SUMSQ(number1, …)` — the sum of squares.
    public static let sumsq = ExcelFunction(name: "SUMSQ", minArgs: 1, maxArgs: nil) { args in
        catching {
            var total = 0.0
            for value in flatten(args) {
                if case .error(let error) = value { throw EvalError.excelError(error) }
                guard case .number(let number) = value else { continue }
                total += number * number
            }
            return .number(total)
        }
    }

    // MARK: - Type coercion

    /// Extracts a `Double` from a `CellValue`, returning `nil` for non-numeric types
    /// (text, blank) instead of throwing.
    private static func numericValue(_ value: CellValue) -> Double? {
        switch value {
        case .number(let n):
            return n
        case .bool(let b):
            return b ? 1.0 : 0.0
        case .blank, .text:
            return nil
        case .error:
            return nil
        case .date(let d):
            return d.timeIntervalSinceReferenceDate / 86_400.0
        case .formula(_, let cached):
            return numericValue(cached ?? .blank)
        case .array:
            return nil
        }
    }

    /// Extracts a `Double` from a `CellValue`, applying Excel-style type coercion.
    private static func toNumber(_ value: CellValue) throws -> Double {
        switch value {
        case .number(let n):
            return n
        case .text(let s):
            guard let n = Double(s) else { throw EvalError.typeMismatch }
            return n
        case .bool(let b):
            return b ? 1.0 : 0.0
        case .blank:
            return 0.0
        case .error(let e):
            throw EvalError.excelError(e)
        case .date(let d):
            return d.timeIntervalSinceReferenceDate / 86_400.0
        case .formula(_, let cached):
            return try toNumber(cached ?? .blank)
        case .array:
            throw EvalError.typeMismatch
        }
    }

    private static func safeDivide(_ numerator: Double, _ denominator: Double) throws -> Double {
        guard denominator != 0 else { throw EvalError.div0Error }
        return numerator / denominator
    }

    /// Wraps a function body so that ``EvalError`` maps to the correct ``CellValue/error(_:)``.
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

    /// Flattens nested arrays in a list of `CellValue` arguments into a single flat list.
    private static func flatten(_ args: [CellValue]) -> [CellValue] {
        var result: [CellValue] = []
        for arg in args {
            if case .array(let elements) = arg {
                result.append(contentsOf: flatten(elements))
            } else {
                result.append(arg)
            }
        }
        return result
    }

    /// Extracts the flat array of values from a `CellValue`.
    private static func toArray(_ value: CellValue) -> [CellValue] {
        if case .array(let elements) = value {
            return elements
        }
        return [value]
    }

    // MARK: - Criteria matching

    /// Determines whether a `CellValue` matches an Excel-style criteria string.
    ///
    /// Criteria formats:
    /// - `">5"` — greater than 5
    /// - `">=10"` — greater than or equal to 10
    /// - `"<3"` — less than 3
    /// - `"<=7"` — less than or equal to 7
    /// - `"<>0"` — not equal to 0
    /// - `"=hello"` — equals "hello"
    /// - `"hello"` — equals "hello"
    /// - `"5"` — equals 5 (or the string "5" for text cells)
    ///
    /// - Parameters:
    ///   - value: The cell value to test.
    ///   - criteria: The criteria string.
    /// - Returns: Whether the value matches.
    static func matchesCriteria(_ value: CellValue, _ criteria: String) -> Bool {
        let trimmed = criteria.trimmingCharacters(in: .whitespaces)

        // Parse operator and operand
        let op: String
        let operand: String

        if trimmed.hasPrefix(">=") {
            op = ">="
            operand = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("<=") {
            op = "<="
            operand = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix("<>") {
            op = "<>"
            operand = String(trimmed.dropFirst(2))
        } else if trimmed.hasPrefix(">") {
            op = ">"
            operand = String(trimmed.dropFirst(1))
        } else if trimmed.hasPrefix("<") {
            op = "<"
            operand = String(trimmed.dropFirst(1))
        } else if trimmed.hasPrefix("=") {
            op = "="
            operand = String(trimmed.dropFirst(1))
        } else {
            op = "="
            operand = trimmed
        }

        // Try numeric comparison first
        if let criteriaNum = Double(operand) {
            guard let valueNum = numericValue(value) else {
                // Non-numeric value vs numeric criteria
                // For equality, non-numeric != number
                return op == "<>" ? true : false
            }
            switch op {
            case ">": return valueNum > criteriaNum
            case ">=": return valueNum >= criteriaNum
            case "<": return valueNum < criteriaNum
            case "<=": return valueNum <= criteriaNum
            case "<>": return valueNum != criteriaNum
            case "=": return valueNum == criteriaNum
            default: return false
            }
        }

        // Text comparison (case-insensitive)
        let valueText: String
        switch value {
        case .text(let s):
            valueText = s
        case .number(let n):
            if n == n.rounded(.towardZero) && !n.isInfinite && !n.isNaN {
                if let intVal = Int(exactly: n) {
                    valueText = String(intVal)
                } else {
                    valueText = String(n)
                }
            } else {
                valueText = String(n)
            }
        case .bool(let b):
            valueText = b ? "TRUE" : "FALSE"
        case .blank:
            // Blank matches "" or <>non-empty
            if op == "=" && operand.isEmpty { return true }
            if op == "<>" && !operand.isEmpty { return true }
            return false
        default:
            return false
        }

        switch op {
        case "=":
            return valueText.caseInsensitiveCompare(operand) == .orderedSame
        case "<>":
            return valueText.caseInsensitiveCompare(operand) != .orderedSame
        case ">":
            return valueText.caseInsensitiveCompare(operand) == .orderedDescending
        case ">=":
            let cmp = valueText.caseInsensitiveCompare(operand)
            return cmp == .orderedDescending || cmp == .orderedSame
        case "<":
            return valueText.caseInsensitiveCompare(operand) == .orderedAscending
        case "<=":
            let cmp = valueText.caseInsensitiveCompare(operand)
            return cmp == .orderedAscending || cmp == .orderedSame
        default:
            return false
        }
    }

    /// Extracts the criteria string from a `CellValue`.
    private static func criteriaString(from value: CellValue) -> String? {
        switch value {
        case .text(let s):
            return s
        case .number(let n):
            if n == n.rounded(.towardZero) && !n.isInfinite && !n.isNaN {
                if let intVal = Int(exactly: n) {
                    return String(intVal)
                }
            }
            return String(n)
        case .bool(let b):
            return b ? "TRUE" : "FALSE"
        default:
            return nil
        }
    }

    // MARK: - SUM

    /// `SUM(number1, [number2], ...)` -- returns the sum of all numeric values.
    ///
    /// Flattens arrays. Ignores text and blank values.
    static let sum = ExcelFunction(name: "SUM", minArgs: 1, maxArgs: nil) { args in
        catching {
            let flat = flatten(args)
            var total = 0.0
            for value in flat {
                // Check for error propagation
                if case .error(let e) = value {
                    throw EvalError.excelError(e)
                }
                if let n = numericValue(value) {
                    total += n
                }
            }
            return .number(total)
        }
    }

    // MARK: - SUMIF

    /// `SUMIF(range, criteria, [sum_range])` -- sums cells that match a criteria.
    ///
    /// If `sum_range` is omitted, the `range` values are summed directly.
    /// If `sum_range` is provided, corresponding values from `sum_range` are summed
    /// where the `range` value matches the criteria.
    static let sumif = ExcelFunction(name: "SUMIF", minArgs: 2, maxArgs: 3) { args in
        catching {
            let rangeValues = toArray(args[0])
            guard let criteria = criteriaString(from: args[1]) else {
                return .error(.value)
            }

            let sumValues: [CellValue]
            if args.count > 2 {
                sumValues = toArray(args[2])
            } else {
                sumValues = rangeValues
            }

            var total = 0.0
            for (i, val) in rangeValues.enumerated() {
                if matchesCriteria(val, criteria) {
                    let sumVal = i < sumValues.count ? sumValues[i] : .blank
                    if let n = numericValue(sumVal) {
                        total += n
                    }
                }
            }
            return .number(total)
        }
    }

    // MARK: - SUMIFS

    /// `SUMIFS(sum_range, criteria_range1, criteria1, ...)` -- sums with multiple criteria.
    ///
    /// The first argument is the range to sum. Subsequent arguments come in pairs:
    /// criteria_range and criteria string.
    static let sumifs = ExcelFunction(name: "SUMIFS", minArgs: 3, maxArgs: nil) { args in
        catching {
            guard args.count >= 3 else { return .error(.value) }
            // Remaining args after sum_range must be in pairs
            guard (args.count - 1) % 2 == 0 else { return .error(.value) }

            let sumValues = toArray(args[0])

            // Collect criteria pairs
            var criteriaPairs: [([CellValue], String)] = []
            var idx = 1
            while idx + 1 < args.count {
                let criteriaRange = toArray(args[idx])
                guard let criteria = criteriaString(from: args[idx + 1]) else {
                    return .error(.value)
                }
                criteriaPairs.append((criteriaRange, criteria))
                idx += 2
            }

            var total = 0.0
            for i in 0..<sumValues.count {
                var allMatch = true
                for (range, criteria) in criteriaPairs {
                    let val = i < range.count ? range[i] : .blank
                    if !matchesCriteria(val, criteria) {
                        allMatch = false
                        break
                    }
                }
                if allMatch {
                    if let n = numericValue(sumValues[i]) {
                        total += n
                    }
                }
            }
            return .number(total)
        }
    }

    // MARK: - COUNTIF

    /// `COUNTIF(range, criteria)` -- counts the number of cells matching a criteria.
    static let countif = ExcelFunction(name: "COUNTIF", minArgs: 2, maxArgs: 2) { args in
        catching {
            let rangeValues = toArray(args[0])
            guard let criteria = criteriaString(from: args[1]) else {
                return .error(.value)
            }

            var count = 0
            for val in rangeValues {
                if matchesCriteria(val, criteria) {
                    count += 1
                }
            }
            return .number(Double(count))
        }
    }

    // MARK: - COUNTIFS

    /// `COUNTIFS(criteria_range1, criteria1, [criteria_range2, criteria2], ...)` -- counts with multiple criteria.
    ///
    /// Arguments come in pairs: criteria_range and criteria string.
    static let countifs = ExcelFunction(name: "COUNTIFS", minArgs: 2, maxArgs: nil) { args in
        catching {
            guard args.count >= 2 else { return .error(.value) }
            guard args.count % 2 == 0 else { return .error(.value) }

            // Collect criteria pairs
            var criteriaPairs: [([CellValue], String)] = []
            var idx = 0
            while idx + 1 < args.count {
                let criteriaRange = toArray(args[idx])
                guard let criteria = criteriaString(from: args[idx + 1]) else {
                    return .error(.value)
                }
                criteriaPairs.append((criteriaRange, criteria))
                idx += 2
            }

            guard let firstRange = criteriaPairs.first?.0 else {
                return .error(.value)
            }

            var count = 0
            for i in 0..<firstRange.count {
                var allMatch = true
                for (range, criteria) in criteriaPairs {
                    let val = i < range.count ? range[i] : .blank
                    if !matchesCriteria(val, criteria) {
                        allMatch = false
                        break
                    }
                }
                if allMatch {
                    count += 1
                }
            }
            return .number(Double(count))
        }
    }

    // MARK: - AVERAGEIF

    /// `AVERAGEIF(range, criteria, [average_range])` -- averages cells that match a criteria.
    ///
    /// If `average_range` is omitted, the matching `range` values are averaged.
    /// Returns `#DIV/0!` if no cells match.
    static let averageif = ExcelFunction(name: "AVERAGEIF", minArgs: 2, maxArgs: 3) { args in
        catching {
            let rangeValues = toArray(args[0])
            guard let criteria = criteriaString(from: args[1]) else {
                return .error(.value)
            }

            let avgValues: [CellValue]
            if args.count > 2 {
                avgValues = toArray(args[2])
            } else {
                avgValues = rangeValues
            }

            var total = 0.0
            var count = 0
            for (i, val) in rangeValues.enumerated() {
                if matchesCriteria(val, criteria) {
                    let avgVal = i < avgValues.count ? avgValues[i] : .blank
                    if let n = numericValue(avgVal) {
                        total += n
                        count += 1
                    }
                }
            }

            return .number(try safeDivide(total, Double(count)))
        }
    }
}
