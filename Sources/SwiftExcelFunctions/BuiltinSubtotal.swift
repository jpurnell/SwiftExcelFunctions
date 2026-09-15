import Foundation
import BusinessMath
import SwiftExcelCore

/// `SUBTOTAL` — eleven aggregates behind one name, chosen by a number.
///
/// ```
/// SUBTOTAL(9, B2:B100)      sum
/// SUBTOTAL(109, B2:B100)    sum, ignoring rows the user has hidden
/// ```
///
/// | Code | | Code | | Code | |
/// |---|---|---|---|---|---|
/// | 1 / 101 | `AVERAGE` | 5 / 105 | `MIN` | 9 / 109 | `SUM` |
/// | 2 / 102 | `COUNT` | 6 / 106 | `PRODUCT` | 10 / 110 | `VAR` |
/// | 3 / 103 | `COUNTA` | 7 / 107 | `STDEV` | 11 / 111 | `VARP` |
/// | 4 / 104 | `MAX` | 8 / 108 | `STDEVP` | | |
///
/// ## What the hundreds mean, and why they do not mean it here
///
/// The 101–111 block ignores rows **the user has hidden by hand**; the 1–11 block includes
/// them. Both blocks ignore rows hidden by a filter.
///
/// **This package cannot tell the difference, and says so rather than guessing.** Row
/// visibility is a property of the *sheet*, not of the values a function is handed, and an
/// evaluator that receives `[CellValue]` has no way to ask. So 101–111 answer exactly what
/// 1–11 answer, and the two agree on every workbook where nothing is hidden — which is
/// every workbook whose author did not specifically arrange otherwise.
///
/// Making this visible matters more than the eight corpus calls do: a caller who believes
/// `SUBTOTAL(109, …)` is filtering for them will read a total as net when it is gross. The
/// alternative — refusing the hundreds — would turn a mostly-right answer into no answer
/// for a distinction the file usually does not draw.
///
/// ## The nesting rule is likewise not modelled
///
/// In Excel a `SUBTOTAL` skips any other `SUBTOTAL` inside its range, which is what lets a
/// grand total sit under a column of subtotals without double-counting. That rule needs the
/// *formulas* of the cells in the range rather than their values, and here the values have
/// already been read.
public enum BuiltinSubtotal {

    /// `SUBTOTAL` for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [subtotal]

    /// `SUBTOTAL(function_num, ref1, [ref2], …)`.
    public static let subtotal = ExcelFunction(name: "SUBTOTAL", minArgs: 2, maxArgs: nil) { args in
        if let error = BuiltinSpreadsheetStatistics.firstError(args) { return error }
        guard let requested = BuiltinSpreadsheetStatistics.real(args[0]) else {
            return .error(.value)
        }
        guard let aggregate = Aggregate(code: requested) else { return .error(.value) }

        let cells = flattened(Array(args.dropFirst()))
        // An error anywhere in the range is the answer, as it is for `SUM`. Skipping it
        // the way text is skipped would report a total over the rows that happened to
        // work, which is the one answer nobody could detect as wrong.
        if let error = cells.first(where: { if case .error = $0 { return true } else { return false } }) {
            return error
        }
        return aggregate.applied(to: cells)
    }

    /// Which aggregate a function number names.
    enum Aggregate: CaseIterable {
        case average, count, countA, maximum, minimum, product
        case standardDeviation, standardDeviationP, sum, variance, varianceP

        /// Reads the function number, in either block.
        ///
        /// - Parameter code: The first argument as written.
        /// - Returns: The aggregate, or `nil` for a number in neither block.
        init?(code: Double) {
            guard code.isFinite, code.magnitude < 1e9 else { return nil }
            // Truncated rather than rounded, which is Excel's rule for a function number
            // and the same one `NOMINAL` applies to its period count.
            let truncated = code.rounded(.towardZero)
            // The hundreds block is the same eleven, one property of the sheet apart —
            // and it is a property this package is not given. See the type's own note.
            let index = truncated >= 101 ? truncated - 100 : truncated
            switch index {
            case 1: self = .average
            case 2: self = .count
            case 3: self = .countA
            case 4: self = .maximum
            case 5: self = .minimum
            case 6: self = .product
            case 7: self = .standardDeviation
            case 8: self = .standardDeviationP
            case 9: self = .sum
            case 10: self = .variance
            case 11: self = .varianceP
            default: return nil
            }
        }

        /// Applies the aggregate to a flattened range.
        ///
        /// - Parameter cells: Every cell the references named, blanks and text included —
        ///   `COUNTA` is the one that needs them.
        /// - Returns: Excel's answer, error cases and all.
        func applied(to cells: [CellValue]) -> CellValue {
            if case .countA = self {
                return .number(Double(cells.filter { if case .blank = $0 { return false }
                                                     else { return true } }.count))
            }
            let values = cells.compactMap(BuiltinSubtotal.number)
            switch self {
            case .count: return .number(Double(values.count))
            // Answered before the numbers were extracted, because it counts what is
            // present rather than what is numeric.
            case .countA: return .number(Double(cells.count))
            case .sum: return .number(values.reduce(0, +))
            case .product:
                // The product of nothing is zero in Excel, not the empty product of one.
                guard !values.isEmpty else { return .number(0) }
                return .number(values.reduce(1, *))
            case .average:
                guard !values.isEmpty else { return .error(.div0) }
                return .number(mean(values))
            case .maximum: return .number(values.max() ?? 0)
            case .minimum: return .number(values.min() ?? 0)
            case .standardDeviation:
                guard values.count >= 2 else { return .error(.div0) }
                return .number(stdDevS(values))
            case .standardDeviationP:
                guard !values.isEmpty else { return .error(.div0) }
                return .number(stdDevP(values))
            case .variance:
                guard values.count >= 2 else { return .error(.div0) }
                return .number(varianceS(values))
            case .varianceP:
                guard !values.isEmpty else { return .error(.div0) }
                // Module-qualified: the case beside it is also called `varianceP`, and
                // an unqualified call resolves to the case rather than the function.
                return .number(BusinessMath.varianceP(values))
            }
        }
    }

    /// Every cell the arguments name, arrays opened out and everything else kept.
    ///
    /// Unlike the statistical helpers this keeps blanks and text, because `COUNTA` counts
    /// what is *present* rather than what is numeric.
    private static func flattened(_ args: [CellValue]) -> [CellValue] {
        var cells: [CellValue] = []
        for argument in args {
            if case .array(let matrix) = argument {
                cells.append(contentsOf: flattened(matrix.elements))
            } else {
                cells.append(argument)
            }
        }
        return cells
    }

    /// A cell as a number, when it holds one.
    ///
    /// Text is skipped rather than coerced: `SUBTOTAL(9, …)` over a column with a header
    /// in it sums the numbers, which is the behaviour the function exists for.
    private static func number(_ value: CellValue) -> Double? {
        switch value {
        case .number(let number): return number.isFinite ? number : nil
        case .bool(let flag): return flag ? 1 : 0
        case .formula(_, let cached): return cached.flatMap(number)
        default: return nil
        }
    }
}
