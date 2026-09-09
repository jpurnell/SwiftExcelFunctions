import Foundation
import SwiftExcelCore

/// `MAXIFS` and `MINIFS` — the extreme over the rows meeting every criterion.
///
/// ## Written as a filter and a reduce
///
/// Which is what they are. Excel's description — *"the maximum among cells specified by a
/// given set of conditions"* — is a `filter` followed by a `max`, and saying it that way in
/// Swift makes the whole function readable at a glance. The criteria machinery is
/// ``BuiltinAggregationFunctions``' own, shared with `SUMIFS` and `COUNTIFS` so that
/// `">15"` means the same thing in all five.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinConditionalExtremes.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinConditionalExtremes {

    /// Both conditional extremes for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [maxIfs, minIfs]

    /// `MAXIFS(max_range, criteria_range1, criteria1, …)`.
    public static let maxIfs = extreme("MAXIFS") { $0.max() }

    /// `MINIFS(min_range, criteria_range1, criteria1, …)`.
    public static let minIfs = extreme("MINIFS") { $0.min() }

    /// Builds a conditional extreme.
    ///
    /// - Parameters:
    ///   - name: the Excel name.
    ///   - pick: which end of the surviving values to take.
    static func extreme(
        _ name: String,
        _ pick: @escaping @Sendable ([Double]) -> Double?
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 3, maxArgs: nil) { args in
            if let error = args.first(where: { if case .error = $0 { return true } else { return false } }) {
                return error
            }
            // Criteria arrive in (range, criterion) pairs after the value range.
            guard args.count >= 3, (args.count - 1) % 2 == 0 else { return .error(.value) }

            let candidates = BuiltinAggregationFunctions.toArray(args[0])
            var conditions: [(range: [CellValue], criterion: String)] = []
            for index in stride(from: 1, to: args.count, by: 2) {
                guard let criterion = BuiltinAggregationFunctions.criteriaString(from: args[index + 1])
                else { return .error(.value) }
                let range = BuiltinAggregationFunctions.toArray(args[index])
                // Every criteria range must line up with the value range row for row;
                // a shorter one cannot say anything about the rows it does not reach.
                guard range.count == candidates.count else { return .error(.value) }
                conditions.append((range, criterion))
            }

            let surviving = candidates.indices
                .filter { row in
                    conditions.allSatisfy {
                        BuiltinAggregationFunctions.matchesCriteria($0.range[row], $0.criterion)
                    }
                }
                .compactMap { row -> Double? in
                    // Only numbers are candidates for an extreme; text in the value range
                    // is skipped rather than coerced, which is what the plain `MAX` does.
                    if case .number(let value) = candidates[row] { return value }
                    return nil
                }

            // **Zero, not `#N/A`.** Excel documents an empty selection as 0 here, against
            // the grain of `MODE.SNGL` and the lookups — so guessing consistently across
            // the library gets this one wrong.
            return .number(pick(surviving) ?? 0)
        }
    }
}
