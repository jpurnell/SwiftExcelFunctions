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
///
/// **Round twelve measured the rest, and this package is wrong about six of them.** The
/// answers are recorded here rather than fixed, so that what is known and what is built do
/// not quietly drift; each is a defect with a measurement behind it.
///
/// What Excel does, measured:
///
/// | Argument | Excel | This package |
/// |---|---|---|
/// | `field_headers` omitted | detects and consumes a header row | treats it as data |
/// | `field_headers` 1 | consumes the header row | treats it as data |
/// | `field_headers` 0 | treats it as data | **agrees** |
/// | `total_depth` −1 | totals present, placed **above** | reads it as "no totals" |
/// | `total_depth` 2 with one grouping level | `#VALUE!` | answers anyway |
/// | `sort_order` 2 | sorts by **column 2**, ascending | ignored |
/// | `sort_order` −2 | sorts by column 2, descending | ignored |
/// | `filter_array` | excludes the rows it marks false | ignored |
///
/// And what it already agrees on: groups ascending by key, a grand total present by default
/// and placed below, case-insensitive grouping keeping the casing first seen, numbers before
/// text in a mixed key column, `COUNT` and `MAX` as aggregates, and `ROWS` of a `PIVOTBY`
/// with both total depths at zero.
///
/// `PIVOTBY` is further out: it is one column wider than this package builds, and a repeated
/// intersection totals 12 where this answers 6.
///
/// **Getting the question asked took three attempts**, none of which was about the
/// mathematics. The name needs the `_xlfn.` prefix; the aggregate is passed as a *reference*
/// and needs `_xleta.SUM`; and a prefix applied only to a formula's outermost call leaves
/// every nested one bare. Each failure produced `#NAME?`, which is indistinguishable from an
/// Excel that does not have the function — and was twice read as exactly that.
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
        fieldHeaders: Int?, totalDepth: Int, sortOrder: Int,
        filter: [Bool]?, aggregate: Aggregate
    ) rethrows -> CellValue {
        var keys = column(of: rowFields)
        var data = column(of: values)
        guard !keys.isEmpty, keys.count == data.count else { return .error(.value) }

        // One grouping level, so one level of totals. Excel refuses a deeper request rather
        // than clamping it — measured in round twelve, where `total_depth` 2 is `#VALUE!`.
        guard abs(totalDepth) <= 1 else { return .error(.value) }

        // Omitted means *detect*, which is the default Excel keeps and this package had
        // backwards: only an explicit 0 makes the first row data.
        let consumesHeader = fieldHeaders.map { $0 != 0 } ?? headerLooksPresent(in: data)
        if consumesHeader, keys.count > 1 {
            keys.removeFirst()
            data.removeFirst()
        }

        if let filter, filter.count == keys.count {
            let kept = keys.indices.filter { filter[$0] }
            keys = kept.map { keys[$0] }
            data = kept.map { data[$0] }
        }
        guard !keys.isEmpty else { return .error(.value) }

        var rows: [(key: CellValue, value: CellValue)] = []
        for group in grouped(keys: keys, data: data, ascending: true) {
            rows.append((group.key, try aggregate(group.values)))
        }
        rows = ordered(rows, by: sortOrder)

        // The grand total aggregates **every** value, not the group aggregates. Summing sums
        // agrees; averaging averages does not, and would report the mean of the group means
        // as though it were the mean of the data.
        var total: [CellValue] = []
        if totalDepth != 0 {
            total = [.text("Total"), try aggregate(data)]
        }

        var elements: [CellValue] = []
        // A negative depth places the total **above**. It does not remove it — which is what
        // this package read the sign as, answering one row short.
        if totalDepth < 0 { elements += total }
        for row in rows {
            elements.append(row.key)
            elements.append(row.value)
        }
        if totalDepth > 0 { elements += total }

        let rowCount = rows.count + (totalDepth != 0 ? 1 : 0)
        guard let matrix = CellMatrix(elements: elements, rows: rowCount, columns: 2) else {
            return .error(.value)
        }
        return .array(matrix)
    }

    /// Whether the first row reads as a header rather than as data.
    ///
    /// **Excel detects one when `field_headers` is omitted**, measured in round twelve on
    /// `{"k";"a";"b"}` over `{"v";1;2}`: text where the column is otherwise numbers.
    private static func headerLooksPresent(in data: [CellValue]) -> Bool {
        guard data.count > 1, case .text = data[0] else { return false }
        return data.dropFirst().contains { if case .number = $0 { return true }
                                           return false }
    }

    /// The groups in the order `sort_order` asks for.
    ///
    /// **The magnitude names a column and the sign is the direction** — 2 sorts by the
    /// aggregate, −1 by the key descending. This package read only the sign, so every order
    /// came out by key.
    ///
    /// Decorated with the original position and compared on it last, so keys this package
    /// cannot order keep the order the data had. An unstable sort would make the same
    /// workbook answer differently between runs.
    private static func ordered(
        _ rows: [(key: CellValue, value: CellValue)], by sortOrder: Int
    ) -> [(key: CellValue, value: CellValue)] {
        let ascending = sortOrder >= 0
        let byAggregate = abs(sortOrder) == 2
        guard byAggregate || !ascending else { return rows }
        return rows.enumerated().sorted { left, right in
            let a = byAggregate ? left.element.value : left.element.key
            let b = byAggregate ? right.element.value : right.element.key
            guard let ordering = order(a, b) else { return left.offset < right.offset }
            return ascending ? ordering : !ordering
        }.map(\.element)
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
        fieldHeaders: Int?, rowTotalDepth: Int, rowSortOrder: Int,
        columnTotalDepth: Int, columnSortOrder: Int,
        filter: [Bool]?, aggregate: Aggregate
    ) rethrows -> CellValue {
        var rowKeys = column(of: rowFields)
        var columnKeys = column(of: columnFields)
        var data = column(of: values)
        guard !rowKeys.isEmpty, rowKeys.count == data.count,
              columnKeys.count == data.count else { return .error(.value) }
        guard abs(rowTotalDepth) <= 1, abs(columnTotalDepth) <= 1 else { return .error(.value) }
        // A sort order of zero names no column, and Excel refuses it rather than ignoring it
        // — measured in round twelve, where a `col_sort_order` of 0 is `#VALUE!`.
        guard rowSortOrder != 0, columnSortOrder != 0 else { return .error(.value) }

        let consumesHeader = fieldHeaders.map { $0 != 0 } ?? headerLooksPresent(in: data)
        if consumesHeader, rowKeys.count > 1 {
            rowKeys.removeFirst()
            columnKeys.removeFirst()
            data.removeFirst()
        }
        if let filter, filter.count == rowKeys.count {
            let kept = rowKeys.indices.filter { filter[$0] }
            rowKeys = kept.map { rowKeys[$0] }
            columnKeys = kept.map { columnKeys[$0] }
            data = kept.map { data[$0] }
        }
        guard !rowKeys.isEmpty else { return .error(.value) }

        let rowOrder = distinct(rowKeys, ascending: rowSortOrder >= 0)
        let columnOrder = distinct(columnKeys, ascending: columnSortOrder >= 0)
        // **The two depths are independent**, which this package did not have: one value
        // drove both, so a suppressed total row took the total column with it. Measured in
        // round twelve, where `row_total_depth` 0 with `col_total_depth` left to its default
        // gives three rows and four columns.
        let hasTotalRow = rowTotalDepth != 0
        let hasTotalColumn = columnTotalDepth != 0

        func cell(row: CellValue, column: CellValue) throws -> CellValue {
            let matching = data.indices.filter {
                same(rowKeys[$0], row) && same(columnKeys[$0], column)
            }.map { data[$0] }
            // Empty rather than zero — see the note on this method.
            return matching.isEmpty ? .blank : try aggregate(matching)
        }

        var header: [CellValue] = [.blank]
        header.append(contentsOf: columnOrder)
        if hasTotalColumn { header.append(.text("Total")) }

        var body: [[CellValue]] = []
        for rowKey in rowOrder {
            var line: [CellValue] = [rowKey]
            for columnKey in columnOrder { line.append(try cell(row: rowKey, column: columnKey)) }
            if hasTotalColumn {
                let matching = data.indices.filter { same(rowKeys[$0], rowKey) }.map { data[$0] }
                line.append(try aggregate(matching))
            }
            body.append(line)
        }

        var footer: [CellValue] = []
        if hasTotalRow {
            footer.append(.text("Total"))
            for columnKey in columnOrder {
                let matching = data.indices.filter { same(columnKeys[$0], columnKey) }
                    .map { data[$0] }
                footer.append(matching.isEmpty ? .blank : try aggregate(matching))
            }
            if hasTotalColumn { footer.append(try aggregate(data)) }
        }

        var elements = header
        for line in body { elements.append(contentsOf: line) }
        elements.append(contentsOf: footer)

        let width = columnOrder.count + 1 + (hasTotalColumn ? 1 : 0)
        let height = rowOrder.count + 1 + (hasTotalRow ? 1 : 0)
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
