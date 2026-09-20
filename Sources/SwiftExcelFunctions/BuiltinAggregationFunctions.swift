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
        sum, sumif, sumifs, countif, countifs, averageif, averageifs, sumproduct, sumsq,
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
                // **An error is the answer, not a dropped term.** Text and blanks
                // contribute zero so the term falls out, but `#N/A` anywhere in the
                // rectangle makes the whole sum `#N/A` — which is what Excel does, and what
                // stops a total quietly reading low because one input is missing.
                if case .error = array[index] { return array[index] }
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
        case .array, .lambda:
            // Neither is a number. A lambda reaching an aggregate means a function was
            // passed where a value belongs, and this family skips what it cannot count.
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
        case .lambda:
            // `#CALC!` rather than `#VALUE!`: the author forgot to call something.
            throw EvalError.excelError(.calc)
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
    /// The first argument that is itself an error, if any.
    ///
    /// An error handed to a function as an argument is the function's answer: `SUMIFS(#REF!,
    /// …)` is `#REF!`. Without this the error flattened to no values at all, which sums to
    /// zero — so a broken reference read as "the total is zero", and in the workbook that
    /// found it the enclosing `IF(… = 0, "", …)` turned that into an empty-looking cell.
    ///
    /// This is about the **argument**, not about error cells *inside* a range: Excel treats
    /// those function by function, and that question is not settled here.
    private static func propagatedError(_ args: [CellValue],
                                        skipping exempt: Set<Int> = []) -> CellValue? {
        for (index, argument) in args.enumerated() where !exempt.contains(index) {
            if case .error = argument { return argument }
        }
        return nil
    }

    /// The argument positions holding **criteria** rather than ranges.
    ///
    /// **An error propagates from a range and not from a criterion**, measured in round
    /// fifteen. An earlier fix here propagated from *every* position after measuring only the
    /// sum-range one, and 672 corpus cells reading `SUMIF($G$8:$G$250, #REF!, K$8:K$250)`
    /// disagreed with Excel ever since: Excel answers `0`, this answered `#REF!`.
    ///
    /// - Parameters:
    ///   - name: The function being called.
    ///   - count: How many arguments it was given.
    /// - Returns: The positions to exempt.
    private static func criteriaPositions(of name: String, count: Int) -> Set<Int> {
        switch name {
        // `f(range, criteria, [other_range])`
        case "SUMIF", "COUNTIF", "AVERAGEIF": return [1]
        // `f(range1, criteria1, range2, criteria2, …)`
        case "COUNTIFS": return Set(stride(from: 1, to: count, by: 2))
        // `f(aggregate_range, range1, criteria1, …)`
        case "SUMIFS", "AVERAGEIFS", "MAXIFS", "MINIFS":
            return Set(stride(from: 2, to: count, by: 2))
        default: return []
        }
    }

    /// Whether a criterion selects nothing at all.
    ///
    /// **Measured in round fifteen**, over a range that *contains* a blank — the case that
    /// could have gone either way. A blank criterion matches neither the blanks nor zero, and
    /// an error criterion matches nothing rather than propagating. Excel answers `0` to all
    /// four of `SUMIF`, `SUMIFS`, `COUNTIF` and `COUNTIFS`; this package matched the blank and
    /// answered `2`, or counted it and answered `1`.
    ///
    /// The `.blank` branch of ``criteriaString(from:)`` carried the opposite belief in a
    /// comment — "matches the empty cells, which is what Excel does" — which was never
    /// measured and is not what Excel does.
    ///
    /// `AVERAGEIF` and `AVERAGEIFS` are **not** included: this was not asked of them, and an
    /// average over no rows is `#DIV/0!` rather than `0`, so the answer does not carry across.
    static func criterionSelectsNothing(_ value: CellValue) -> Bool {
        switch value {
        case .blank, .error: return true
        default: return false
        }
    }

    private static func flatten(_ args: [CellValue]) -> [CellValue] {
        var result: [CellValue] = []
        for arg in args {
            if case .array(let matrix) = arg {
                result.append(contentsOf: flatten(matrix.elements))
            } else {
                result.append(arg)
            }
        }
        return result
    }

    /// Extracts the flat array of values from a `CellValue`.
    static func toArray(_ value: CellValue) -> [CellValue] {
        if case .array(let matrix) = value {
            return matrix.elements
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
            // **`COUNTIF` coerces text that reads as a number**, unlike a plain comparison:
            // `COUNTIF(H2:H23, "1")` counts the cells holding the *text* "1" as well as
            // those holding the number. Measured: 11 in Excel where this answered 6.
            let coerced: Double?
            if case .text(let text) = value.resolved {
                coerced = Double(text.trimmingCharacters(in: .whitespaces))
            } else {
                coerced = numericValue(value)
            }
            guard let valueNum = coerced else {
                // Non-numeric value vs numeric criteria
                // For equality, non-numeric != number
                return op == "<>" ? true : false
            }
            // **Excel's comparison rule applies wherever Excel compares**, and a criterion
            // is a comparison. `COUNTIF(H2:H23, "1")` counts 0.99999999999999978 as a 1,
            // because the difference is negligible against the operands — the same rule
            // that makes `0.1+0.2=0.3` true. Comparing the raw doubles instead answered 6
            // where Excel answered 11.
            let difference = ExcelFinalRounding.corrected(
                valueNum - criteriaNum, lhs: valueNum, rhs: criteriaNum)
            switch op {
            case ">": return difference > 0
            case ">=": return difference >= 0
            case "<": return difference < 0
            case "<=": return difference <= 0
            case "<>": return difference != 0
            case "=": return difference == 0
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

        // `*` and `?` are Excel's wildcards, and three things are true about them that a
        // straight pattern match would get wrong:
        //
        // - only equality reads them — `">a*"` compares against three characters;
        // - they match **text**, so `COUNTIF(range, "*")` counts the cells holding text and
        //   passes over the numbers, which is what makes it "how many are filled in";
        // - a blank is not matched by `*` at all, having been answered above.
        // A tilde with no wildcard after it still needs the matcher, which is the only
        // thing that knows `~*` means one asterisk rather than two characters.
        if ExcelWildcard.isPattern(operand) || operand.contains("~"), op == "=" || op == "<>" {
            guard case .text = value else { return op == "<>" }
            let matched = ExcelWildcard.matches(valueText, pattern: operand)
            return op == "=" ? matched : !matched
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
    static func criteriaString(from value: CellValue) -> String? {
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
        case .date(let date):
            // A date criterion is its serial, because that is what the cells it will be
            // compared against hold. Left out, `SUMIFS(amounts, month, I$1, …)` refused the
            // whole call — 200 cells in one corpus workbook, every one wrapped in an
            // `IFERROR` that turned the refusal into a plausible zero.
            return criteriaString(from: .number(BuiltinDateTimeFunctions.dateToSerial(date)))
        case .blank:
            // An empty criterion cell matches the empty cells, which is what Excel does
            // and is occasionally what a half-filled template means to ask.
            return ""
        case .formula(_, let cached):
            return cached.flatMap(criteriaString)
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
            if let error = propagatedError(args, skipping: criteriaPositions(of: "SUMIF", count: args.count)) {
                return error
            }
            if criterionSelectsNothing(args[1]) { return .number(0) }
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
                    // **An error in a selected row is the answer; one in a skipped row is
                    // not.** Measured in round fourteen, and selective rather than blanket:
                    // Excel answers `#REF!` when the error sits in a matching row and the
                    // ordinary total when it sits in a row the criteria passes over. An
                    // error in the *criteria* range propagates nothing — it matches nothing.
                    //
                    // The corpus found this as 12,960 cells across four workbooks and could
                    // not say which rule was at work, because there the error row happened
                    // to match. Assuming the blanket rule from that one shape would have
                    // been wrong on two of the round's eleven cases.
                    //
                    // `COUNTIF` counts around an error instead, measured in the same round,
                    // which is why this guard is where values are summed and not where rows
                    // are counted.
                    if case .error = sumVal { return sumVal }
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
            if let error = propagatedError(args, skipping: criteriaPositions(of: "SUMIFS", count: args.count)) {
                return error
            }
            // A criterion selecting nothing makes the whole call zero — measured
            // in round fifteen for a blank and for an error alike.
            for position in criteriaPositions(of: "SUMIFS", count: args.count)
            where args.indices.contains(position) {
                if criterionSelectsNothing(args[position]) { return .number(0) }
            }
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
                // **The ranges must match, and `SUMIFS` refuses when they do not.** Measured
                // in round fifteen: given three keys and a one-cell sum range, Excel answers
                // `#VALUE!` here and `4` for the `SUMIF` spelling — the clearest proof that
                // these are two functions rather than one with its arguments moved. This
                // package answered the same number to both.
                guard criteriaRange.count == sumValues.count else { return .error(.value) }
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
                    // Selected, so an error here is the answer — see the note in `SUMIF`.
                    if case .error = sumValues[i] { return sumValues[i] }
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
            if let error = propagatedError(args, skipping: criteriaPositions(of: "COUNTIF", count: args.count)) {
                return error
            }
            if criterionSelectsNothing(args[1]) { return .number(0) }
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
            if let error = propagatedError(args, skipping: criteriaPositions(of: "COUNTIFS", count: args.count)) {
                return error
            }
            // A criterion selecting nothing makes the whole call zero — measured
            // in round fifteen for a blank and for an error alike.
            for position in criteriaPositions(of: "COUNTIFS", count: args.count)
            where args.indices.contains(position) {
                if criterionSelectsNothing(args[position]) { return .number(0) }
            }
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
            if let error = propagatedError(args) { return error }
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
                    // Selected, so an error here is the answer — see the note in `SUMIF`.
                    if case .error = avgVal { return avgVal }
                    if let n = numericValue(avgVal) {
                        total += n
                        count += 1
                    }
                }
            }

            return .number(try safeDivide(total, Double(count)))
        }
    }

    // MARK: - AVERAGEIFS

    /// `AVERAGEIFS(average_range, criteria_range1, criteria1, …)` — the mean of the rows
    /// meeting **every** criterion.
    ///
    /// The most-called function this package could not answer: **35 calls** in the corpus
    /// sweep, all in one workbook, all returning `#NAME?` for want of a name.
    ///
    /// Two details separate it from ``sumifs``, and both are Excel's doing rather than
    /// ours:
    ///
    /// - **The value range comes first**, as it does in `SUMIFS` and `MAXIFS` and *not* as
    ///   it does in `AVERAGEIF`, where the criteria range leads and the value range is an
    ///   optional third argument. Reading the two the same way puts the criteria where the
    ///   values should be and averages the wrong column without erroring.
    /// - **No matching row is `#DIV/0!`**, not zero. `MAXIFS` answers zero for an empty
    ///   selection and this answers an error, so there is no consistent rule across the
    ///   `*IFS` family to infer from — each is what Excel documents for that function.
    ///
    /// Only numbers are averaged. Text in the value range is skipped rather than counted
    /// as zero, which is what changes a mean rather than merely a total.
    static let averageifs = ExcelFunction(name: "AVERAGEIFS", minArgs: 3, maxArgs: nil) { args in
        catching {
            if let error = propagatedError(args) { return error }
            // The value range, then (range, criterion) pairs — so an odd count is a
            // criterion with no range or a range with no criterion.
            guard args.count >= 3, (args.count - 1) % 2 == 0 else { return .error(.value) }
            if let error = args.first(where: { if case .error = $0 { return true } else { return false } }) {
                return error
            }

            let candidates = toArray(args[0])
            var conditions: [(range: [CellValue], criterion: String)] = []
            for index in stride(from: 1, to: args.count, by: 2) {
                guard let criterion = criteriaString(from: args[index + 1]) else {
                    return .error(.value)
                }
                conditions.append((toArray(args[index]), criterion))
            }

            var total = 0.0
            var count = 0
            for row in candidates.indices {
                let matches = conditions.allSatisfy { condition in
                    let value = row < condition.range.count ? condition.range[row] : .blank
                    return matchesCriteria(value, condition.criterion)
                }
                guard matches, let number = numericValue(candidates[row]) else { continue }
                total += number
                count += 1
            }

            // Excel's answer to "the average of nothing" is an error, not zero.
            guard count > 0 else { return .error(.div0) }
            return .number(try safeDivide(total, Double(count)))
        }
    }
}
