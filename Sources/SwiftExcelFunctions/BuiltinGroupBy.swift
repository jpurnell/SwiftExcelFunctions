import Foundation
import SwiftExcelCore

/// `GROUPBY` and `PIVOTBY` — aggregate a column by the values of another.
///
/// ```
/// GROUPBY(A2:A99, B2:B99, SUM)                 one row per region, sales totalled
/// PIVOTBY(A2:A99, C2:C99, B2:B99, SUM)         regions down, quarters across
/// ```
///
/// Both were classified **out of scope on zero corpus demand**, not on difficulty, and the
/// classification said it should move the moment they were wanted. They are here now.
///
/// ## The aggregate is a function, named without being called
///
/// `GROUPBY(…, SUM)` passes `SUM` **eta-reduced** — the function itself, not a call to it.
/// The parser reads a bare name as `.namedRange("SUM")`, so this is reached before its
/// arguments are evaluated, the way `LAMBDA` and the higher-order six are: evaluated first,
/// `SUM` is a name the workbook does not define and the call is `#NAME?` before it starts.
///
/// A `LAMBDA` is accepted in the same position, which is what makes the aggregate open-ended
/// rather than a list of eleven the way `SUBTOTAL`'s is.
///
/// ## What is implemented, and what is asked rather than assumed
///
/// The grouping, the aggregation, ascending order and the grand total are the function.
/// Several of Microsoft's optional arguments select behaviour this package has **not
/// measured** — the default `total_depth`, whether headers are detected, the sort
/// conventions. Unlike the `Psi*` family these *can* be measured: they are Excel functions,
/// and `ConformanceCases.roundTen` asks about exactly these points. Until that returns, the
/// choices below are stated in the documentation of each argument rather than presented as
/// settled.
public enum BuiltinGroupBy {

    /// Both functions, for registration in a ``FunctionRegistry``.
    ///
    /// The bodies are never reached — ``FormulaEvaluator`` intercepts them, since the
    /// aggregate argument must not be evaluated. They exist so the names resolve.
    public static let all: [ExcelFunction] = [
        ExcelFunction(name: "GROUPBY", minArgs: 3, maxArgs: 8) { _ in .error(.value) },
        ExcelFunction(name: "PIVOTBY", minArgs: 4, maxArgs: 11) { _ in .error(.value) }
    ]

    /// Whether this file answers a name.
    static func governs(_ name: String) -> Bool { name == "GROUPBY" || name == "PIVOTBY" }

    /// How the aggregate is applied to one group's values.
    typealias Aggregate = (_ values: [CellValue]) throws -> CellValue

    // MARK: - GROUPBY

    /// `GROUPBY(row_fields, values, function, [field_headers], [total_depth], [sort_order])`.
    ///
    /// - Parameters:
    ///   - rowFields: the column whose distinct values become the groups.
    ///   - values: the column to aggregate.
    ///   - totalDepth: `0` for no total row, `1` for a grand total. **Defaults to 1**, which
    ///     is what Microsoft documents; it is among the points round ten asks about.
    ///   - ascending: `true` to sort groups ascending by key, which is the documented default.
    ///   - aggregate: the function to apply to each group.
    /// - Returns: two columns — the group key and its aggregate — one row per group.
    static func groupBy(
        rowFields: CellValue, values: CellValue,
        totalDepth: Int, ascending: Bool, aggregate: Aggregate
    ) rethrows -> CellValue {
        let keys = column(of: rowFields)
        let data = column(of: values)
        guard !keys.isEmpty, keys.count == data.count else { return .error(.value) }

        let groups = grouped(keys: keys, data: data, ascending: ascending)
        var elements: [CellValue] = []
        for group in groups {
            elements.append(group.key)
            elements.append(try aggregate(group.values))
        }
        if totalDepth >= 1 {
            // The grand total aggregates **every** value, not the group aggregates. Summing
            // sums agrees; averaging averages does not, and would report the mean of the
            // group means as though it were the mean of the data.
            elements.append(.text("Total"))
            elements.append(try aggregate(data))
        }
        let rows = groups.count + (totalDepth >= 1 ? 1 : 0)
        guard let matrix = CellMatrix(elements: elements, rows: rows, columns: 2) else {
            return .error(.value)
        }
        return .array(matrix)
    }

    // MARK: - PIVOTBY

    /// `PIVOTBY(row_fields, col_fields, values, function, …)`.
    ///
    /// The same grouping in two directions at once. The result carries a header row of column
    /// keys with an empty corner cell, so the shape reads as a table rather than as a matrix
    /// whose first row happens to be labels.
    ///
    /// A cell with no matching rows is **empty**, not zero: no observation is not the same as
    /// an observation of nothing, and a zero there would be summed and averaged along with
    /// the real ones.
    static func pivotBy(
        rowFields: CellValue, columnFields: CellValue, values: CellValue,
        totalDepth: Int, ascending: Bool, aggregate: Aggregate
    ) rethrows -> CellValue {
        let rowKeys = column(of: rowFields)
        let columnKeys = column(of: columnFields)
        let data = column(of: values)
        guard !rowKeys.isEmpty, rowKeys.count == data.count,
              columnKeys.count == data.count else { return .error(.value) }

        let rowOrder = distinct(rowKeys, ascending: ascending)
        let columnOrder = distinct(columnKeys, ascending: ascending)

        var elements: [CellValue] = [.blank]
        elements.append(contentsOf: columnOrder)
        if totalDepth >= 1 { elements.append(.text("Total")) }

        for rowKey in rowOrder {
            elements.append(rowKey)
            for columnKey in columnOrder {
                let matching = (0..<data.count).filter {
                    same(rowKeys[$0], rowKey) && same(columnKeys[$0], columnKey)
                }.map { data[$0] }
                // Empty rather than zero — see the note on this method.
                elements.append(matching.isEmpty ? .blank : try aggregate(matching))
            }
            if totalDepth >= 1 {
                let matching = (0..<data.count).filter { same(rowKeys[$0], rowKey) }
                    .map { data[$0] }
                elements.append(try aggregate(matching))
            }
        }
        if totalDepth >= 1 {
            elements.append(.text("Total"))
            for columnKey in columnOrder {
                let matching = (0..<data.count).filter { same(columnKeys[$0], columnKey) }
                    .map { data[$0] }
                elements.append(matching.isEmpty ? .blank : try aggregate(matching))
            }
            elements.append(try aggregate(data))
        }

        let width = columnOrder.count + 1 + (totalDepth >= 1 ? 1 : 0)
        let height = rowOrder.count + 1 + (totalDepth >= 1 ? 1 : 0)
        guard let matrix = CellMatrix(elements: elements, rows: height, columns: width) else {
            return .error(.value)
        }
        return .array(matrix)
    }

    // MARK: - Grouping

    private struct Group {
        let key: CellValue
        var values: [CellValue]
    }

    /// Groups values by key, in the order the keys are to appear.
    private static func grouped(
        keys: [CellValue], data: [CellValue], ascending: Bool
    ) -> [Group] {
        distinct(keys, ascending: ascending).map { key in
            Group(key: key,
                  values: (0..<data.count).filter { same(keys[$0], key) }.map { data[$0] })
        }
    }

    /// The distinct keys, sorted.
    ///
    /// **First appearance breaks ties**, so two keys this package cannot order — two text
    /// values differing only in case, say — keep the order the data had rather than an
    /// arbitrary one. A stable result matters more here than a clever collation: an unstable
    /// one makes the same workbook produce different output on different runs.
    private static func distinct(_ keys: [CellValue], ascending: Bool) -> [CellValue] {
        var seen: [CellValue] = []
        for key in keys where !seen.contains(where: { same($0, key) }) {
            seen.append(key)
        }
        let sorted = seen.enumerated().sorted { left, right in
            if let ordering = order(left.element, right.element) {
                return ascending ? ordering : !ordering
            }
            return left.offset < right.offset
        }
        return sorted.map(\.element)
    }

    /// Whether the left key sorts before the right, or `nil` if they are not comparable.
    ///
    /// Numbers before text, which is Excel's own ordering for a mixed column.
    private static func order(_ left: CellValue, _ right: CellValue) -> Bool? {
        switch (left, right) {
        case (.number(let a), .number(let b)): return a == b ? nil : a < b
        case (.text(let a), .text(let b)): return a == b ? nil : a < b
        case (.bool(let a), .bool(let b)): return a == b ? nil : (!a && b)
        case (.number, .text): return true
        case (.text, .number): return false
        default: return nil
        }
    }

    /// Whether two keys name the same group.
    ///
    /// Text compares **case-insensitively**, which is Excel's rule everywhere else it
    /// compares text — `=` and `MATCH` both do — so "North" and "north" are one region.
    private static func same(_ left: CellValue, _ right: CellValue) -> Bool {
        switch (left, right) {
        case (.number(let a), .number(let b)): return a == b
        case (.text(let a), .text(let b)): return a.lowercased() == b.lowercased()
        case (.bool(let a), .bool(let b)): return a == b
        case (.blank, .blank): return true
        default: return false
        }
    }

    /// One argument's cells, in reading order.
    private static func column(of value: CellValue) -> [CellValue] {
        if case .array(let matrix) = value { return matrix.elements }
        return [value]
    }
}
