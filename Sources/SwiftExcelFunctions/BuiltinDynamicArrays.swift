import Foundation
import SwiftExcelCore

/// The dynamic-array family: reshaping, stacking, filtering and sorting.
///
/// `FILTER`, `SORT`, `SORTBY`, `UNIQUE`, `TAKE`, `DROP`, `EXPAND`, `HSTACK`, `VSTACK`,
/// `TOROW`, `TOCOL`, `WRAPROWS`, `WRAPCOLS`, `CHOOSEROWS`, `CHOOSECOLS` and `XMATCH`.
///
/// ## Matrix in, matrix out, and no `#SPILL!`
///
/// In Excel these functions *spill*: they return a rectangle that grows into the cells below
/// and right, and `#SPILL!` is what happens when something is in the way. That is a fact
/// about a worksheet's occupancy, and this package evaluates a formula without one — the
/// master plan settled the shape as **matrix only**, and a caller who needs the cells written
/// somewhere uses `FormulaEvaluator.evaluate(_:over:…)`, which already exists for array
/// formulas and does exactly this.
///
/// So each function here returns a `CellMatrix` and never reports `#SPILL!`. What it cannot
/// do is not silently approximated: it is simply not this layer's question.
///
/// ## One-based, and rectangles stay rectangles
///
/// Every index a formula writes is one-based, and negative indices count from the end —
/// `TAKE(a, -2)` is the last two rows. A result is always a full rectangle, padded with
/// `#N/A` where there is nothing to put, because a ragged matrix cannot be written into
/// cells and Excel does not produce one.
public enum BuiltinDynamicArrays {

    /// Every dynamic-array function, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        filter, sort, sortBy, unique, take, drop, expand,
        hstack, vstack, toRow, toCol, wrapRows, wrapCols,
        chooseRows, chooseCols, xmatch
    ]

    // MARK: - Selecting

    /// `FILTER(array, include, [if_empty])` — the rows or columns the mask keeps.
    ///
    /// The mask's shape decides the direction: a column mask selects rows, a row mask selects
    /// columns. Nothing kept is `if_empty` if given and `#CALC!` if not — Excel's answer for
    /// a result that has no cells at all.
    public static let filter = ExcelFunction(name: "FILTER", minArgs: 2, maxArgs: 3) { args in
        if let error = args.first(where: isError) { return error }
        let source = matrix(of: args[0])
        let mask = matrix(of: args[1])
        let fallback = args.count > 2 ? args[2] : CellValue.error(.calc)

        // A column mask selects rows; a row mask selects columns. Ambiguous only for a 1×1
        // mask, where both readings agree.
        if mask.columns == 1 && mask.rows == source.rows {
            let kept = (0..<source.rows).filter { truthy(mask[$0, 0]) }
            guard !kept.isEmpty else { return fallback }
            return shaped(kept.flatMap { row in (0..<source.columns).map { source[row, $0] } },
                          rows: kept.count, columns: source.columns)
        }
        if mask.rows == 1 && mask.columns == source.columns {
            let kept = (0..<source.columns).filter { truthy(mask[0, $0]) }
            guard !kept.isEmpty else { return fallback }
            return shaped((0..<source.rows).flatMap { row in kept.map { source[row, $0] } },
                          rows: source.rows, columns: kept.count)
        }
        // A mask that matches neither dimension is `#VALUE!`: there is no correspondence
        // between its cells and the array's, so any answer would be invented.
        return .error(.value)
    }

    /// `UNIQUE(array, [by_col], [exactly_once])` — distinct rows, in the order first seen.
    ///
    /// Order matters and is not sorted: Excel keeps first appearance, and a caller who wants
    /// them sorted says `SORT(UNIQUE(…))`. `exactly_once` keeps only the rows that appear a
    /// single time, which is a different question from distinctness.
    public static let unique = ExcelFunction(name: "UNIQUE", minArgs: 1, maxArgs: 3) { args in
        if let error = args.first(where: isError) { return error }
        let source = matrix(of: args[0])
        let byColumn = args.count > 1 && truthy(args[1])
        let onlyOnce = args.count > 2 && truthy(args[2])

        let lines = byColumn ? source.columns : source.rows
        var keys: [String] = []
        var counts: [String: Int] = [:]
        for index in 0..<lines {
            let key = signature(of: line(index, in: source, byColumn: byColumn))
            keys.append(key)
            counts[key, default: 0] += 1
        }

        var seen: Set<String> = []
        var kept: [Int] = []
        for (index, key) in keys.enumerated() {
            if onlyOnce {
                if counts[key] == 1 { kept.append(index) }
            } else if seen.insert(key).inserted {
                kept.append(index)
            }
        }
        guard !kept.isEmpty else { return .error(.calc) }
        return assembled(kept, from: source, byColumn: byColumn)
    }

    // MARK: - Ordering

    /// `SORT(array, [sort_index], [sort_order], [by_col])` — ordered by one of its own lines.
    public static let sort = ExcelFunction(name: "SORT", minArgs: 1, maxArgs: 4) { args in
        if let error = args.first(where: isError) { return error }
        let source = matrix(of: args[0])
        let byColumn = args.count > 3 && truthy(args[3])
        let index = args.count > 1 ? (whole(args[1]) ?? 1) : 1
        let descending = args.count > 2 && (BuiltinMathPrimitives.real(args[2]) ?? 1) < 0

        let width = byColumn ? source.rows : source.columns
        guard index >= 1, index <= width else { return .error(.value) }

        let order = ordering(count: byColumn ? source.columns : source.rows, descending: descending) {
            line($0, in: source, byColumn: byColumn)[index - 1]
        }
        return assembled(order, from: source, byColumn: byColumn)
    }

    /// `SORTBY(array, by_array, [sort_order], …)` — ordered by a *separate* array.
    ///
    /// Several key/order pairs are allowed and are applied in order of significance, so the
    /// second key breaks ties in the first. A stable sort is what makes that work, and Swift's
    /// is not guaranteed stable, so the ordering below breaks ties by index.
    public static let sortBy = ExcelFunction(name: "SORTBY", minArgs: 2, maxArgs: nil) { args in
        if let error = args.first(where: isError) { return error }
        let source = matrix(of: args[0])

        var keys: [(values: CellMatrix, descending: Bool)] = []
        var index = 1
        while index < args.count {
            let by = matrix(of: args[index])
            let descending = index + 1 < args.count
                && (BuiltinMathPrimitives.real(args[index + 1]) ?? 1) < 0
            guard by.elements.count == source.rows else { return .error(.value) }
            keys.append((by, descending))
            index += 2
        }
        guard !keys.isEmpty else { return .error(.value) }

        var order = Array(0..<source.rows)
        // Least significant key first, so the most significant is applied last and wins.
        for key in keys.reversed() {
            let settled = order
            order = ordering(count: settled.count, descending: key.descending) {
                key.values.elements[settled[$0]]
            }.map { settled[$0] }
        }
        return assembled(order, from: source, byColumn: false)
    }

    // MARK: - Taking and padding

    /// `TAKE(array, rows, [columns])` — the first or last lines. Negative counts from the end.
    public static let take = ExcelFunction(name: "TAKE", minArgs: 2, maxArgs: 3) { args in
        slice(args, keeping: true)
    }

    /// `DROP(array, rows, [columns])` — everything but. Negative drops from the end.
    public static let drop = ExcelFunction(name: "DROP", minArgs: 2, maxArgs: 3) { args in
        slice(args, keeping: false)
    }

    /// `EXPAND(array, rows, [columns], [pad_with])` — grown to a size, padded.
    ///
    /// The pad defaults to `#N/A`, which is Excel's and is the honest one: a cell that was
    /// never in the data has no value, and zero would be a number somebody might sum.
    public static let expand = ExcelFunction(name: "EXPAND", minArgs: 2, maxArgs: 4) { args in
        if let error = args.first(where: isError) { return error }
        let source = matrix(of: args[0])
        let rows = whole(args[1]) ?? source.rows
        let columns = args.count > 2 ? (whole(args[2]) ?? source.columns) : source.columns
        let pad = args.count > 3 ? args[3] : CellValue.error(.na)
        // Shrinking is not expanding: Excel refuses rather than quietly truncating.
        guard rows >= source.rows, columns >= source.columns else { return .error(.value) }

        var elements: [CellValue] = []
        elements.reserveCapacity(rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                elements.append(source.element(row: row, column: column) ?? pad)
            }
        }
        return shaped(elements, rows: rows, columns: columns)
    }

    // MARK: - Stacking

    /// `VSTACK(array1, …)` — arrays laid one under another, widened to the widest.
    public static let vstack = ExcelFunction(name: "VSTACK", minArgs: 1, maxArgs: nil) { args in
        if let error = args.first(where: isError) { return error }
        let parts = args.map(matrix(of:))
        let width = parts.map(\.columns).max() ?? 0
        var elements: [CellValue] = []
        var rows = 0
        for part in parts {
            for row in 0..<part.rows {
                for column in 0..<width {
                    // Short rows are padded with `#N/A`, not blank: the cell is not empty,
                    // it was never there.
                    elements.append(part.element(row: row, column: column) ?? .error(.na))
                }
                rows += 1
            }
        }
        return shaped(elements, rows: rows, columns: width)
    }

    /// `HSTACK(array1, …)` — arrays laid side by side, deepened to the deepest.
    public static let hstack = ExcelFunction(name: "HSTACK", minArgs: 1, maxArgs: nil) { args in
        if let error = args.first(where: isError) { return error }
        let parts = args.map(matrix(of:))
        let height = parts.map(\.rows).max() ?? 0
        let width = parts.reduce(0) { $0 + $1.columns }
        var elements: [CellValue] = []
        for row in 0..<height {
            for part in parts {
                for column in 0..<part.columns {
                    elements.append(part.element(row: row, column: column) ?? .error(.na))
                }
            }
        }
        return shaped(elements, rows: height, columns: width)
    }

    // MARK: - Reshaping

    /// `TOROW(array, [ignore], [scan_by_column])` — everything on one line.
    public static let toRow = ExcelFunction(name: "TOROW", minArgs: 1, maxArgs: 3) { args in
        flattened(args) { values in shaped(values, rows: 1, columns: values.count) }
    }

    /// `TOCOL(array, [ignore], [scan_by_column])` — everything in one column.
    public static let toCol = ExcelFunction(name: "TOCOL", minArgs: 1, maxArgs: 3) { args in
        flattened(args) { values in shaped(values, rows: values.count, columns: 1) }
    }

    /// `WRAPROWS(vector, wrap_count, [pad_with])` — a vector folded into rows.
    public static let wrapRows = ExcelFunction(
        name: "WRAPROWS", minArgs: 2, maxArgs: 3
    ) { args in
        wrapped(args, intoRows: true)
    }

    /// `WRAPCOLS(vector, wrap_count, [pad_with])` — a vector folded into columns.
    public static let wrapCols = ExcelFunction(
        name: "WRAPCOLS", minArgs: 2, maxArgs: 3
    ) { args in
        wrapped(args, intoRows: false)
    }

    /// `CHOOSEROWS(array, row_num1, …)` — the named rows, in the order named.
    ///
    /// Repeats are allowed: `CHOOSEROWS(a, 1, 1, 2)` is three rows. It selects rather than
    /// filters, so the order and the count are the caller's to decide.
    public static let chooseRows = ExcelFunction(
        name: "CHOOSEROWS", minArgs: 2, maxArgs: nil
    ) { args in
        chosen(args, byColumn: false)
    }

    /// `CHOOSECOLS(array, col_num1, …)` — the named columns, in the order named.
    public static let chooseCols = ExcelFunction(
        name: "CHOOSECOLS", minArgs: 2, maxArgs: nil
    ) { args in
        chosen(args, byColumn: true)
    }

    // MARK: - XMATCH

    /// `XMATCH(lookup, array, [match_mode], [search_mode])` — the position of a value.
    ///
    /// `MATCH`'s replacement, and the difference worth knowing is the default: `XMATCH`
    /// defaults to **exact**, where `MATCH` defaults to "largest value not greater than" and
    /// quietly assumes the data is sorted. Modes: 0 exact, -1 exact or next smaller, 1 exact
    /// or next larger, 2 wildcard. Search mode -1 searches from the end.
    public static let xmatch = ExcelFunction(name: "XMATCH", minArgs: 2, maxArgs: 4) { args in
        if let error = args.first(where: isError) { return error }
        let haystack = matrix(of: args[1]).elements
        let mode = args.count > 2 ? (whole(args[2]) ?? 0) : 0
        let reverse = args.count > 3 && (BuiltinMathPrimitives.real(args[3]) ?? 1) < 0
        let order = reverse ? Array(haystack.indices.reversed()) : Array(haystack.indices)

        // Exact first, whatever the mode: a match that is present beats one that is nearest.
        for index in order where matches(args[0], haystack[index], wildcard: mode == 2) {
            return .number(Double(index + 1))
        }
        guard mode == -1 || mode == 1 else { return .error(.na) }

        // Nearest in the direction asked for, by value rather than by position — the data
        // need not be sorted, which is the other thing `XMATCH` fixes.
        var best: (index: Int, value: CellValue)?
        for index in order {
            let candidate = haystack[index]
            let comparison = FormulaEvaluator.compareValues(candidate, args[0])
            let wanted: ComparisonResult = mode == -1 ? .orderedAscending : .orderedDescending
            guard comparison == wanted else { continue }
            guard let current = best else { best = (index, candidate); continue }
            let better: ComparisonResult = mode == -1 ? .orderedDescending : .orderedAscending
            if FormulaEvaluator.compareValues(candidate, current.value) == better {
                best = (index, candidate)
            }
        }
        guard let found = best else { return .error(.na) }
        return .number(Double(found.index + 1))
    }

    // MARK: - Plumbing

    private static func isError(_ value: CellValue) -> Bool {
        if case .error = value { return true }
        return false
    }

    private static func matrix(of value: CellValue) -> CellMatrix {
        if case .array(let matrix) = value { return matrix }
        return CellMatrix(single: value)
    }

    private static func shaped(_ elements: [CellValue], rows: Int, columns: Int) -> CellValue {
        guard rows > 0, columns > 0,
              let matrix = CellMatrix(elements: elements, rows: rows, columns: columns) else {
            return .error(.calc)
        }
        return .array(matrix)
    }

    private static func whole(_ value: CellValue) -> Int? {
        guard let number = BuiltinMathPrimitives.real(value) else { return nil }
        return Int(exactly: number.rounded(.towardZero))
    }

    private static func truthy(_ value: CellValue) -> Bool {
        switch value {
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        default: return false
        }
    }

    /// One row or column of a matrix.
    private static func line(_ index: Int, in matrix: CellMatrix, byColumn: Bool) -> [CellValue] {
        byColumn
            ? (0..<matrix.rows).map { matrix[$0, index] }
            : (0..<matrix.columns).map { matrix[index, $0] }
    }

    /// A row or column's identity, for distinctness.
    private static func signature(of values: [CellValue]) -> String {
        values.map { String(describing: $0) }.joined(separator: "\u{1F}")
    }

    /// The chosen lines, reassembled into a matrix in the order given.
    private static func assembled(
        _ order: [Int], from source: CellMatrix, byColumn: Bool
    ) -> CellValue {
        if byColumn {
            var elements: [CellValue] = []
            for row in 0..<source.rows {
                for column in order { elements.append(source[row, column]) }
            }
            return shaped(elements, rows: source.rows, columns: order.count)
        }
        let elements = order.flatMap { row in (0..<source.columns).map { source[row, $0] } }
        return shaped(elements, rows: order.count, columns: source.columns)
    }

    /// An ordering of `0..<count`, by a key, with the index as a tiebreak.
    ///
    /// The tiebreak is what makes the sort **stable**, and stability is not decoration here:
    /// `SORTBY` applies several keys in turn and relies on an earlier pass surviving a later
    /// one. Swift's `sort` is not guaranteed stable, so it is arranged rather than assumed.
    private static func ordering(
        count: Int, descending: Bool, key: (Int) -> CellValue
    ) -> [Int] {
        let keys = (0..<count).map(key)
        return (0..<count).sorted { left, right in
            let comparison = FormulaEvaluator.compareValues(keys[left], keys[right])
            if comparison == .orderedSame { return left < right }
            return descending
                ? comparison == .orderedDescending
                : comparison == .orderedAscending
        }
    }

    /// `TAKE` and `DROP`, which differ only in which end they name.
    private static func slice(_ args: [CellValue], keeping: Bool) -> CellValue {
        if let error = args.first(where: isError) { return error }
        let source = matrix(of: args[0])

        func span(_ requested: Int?, of total: Int) -> Range<Int> {
            guard let requested, requested != 0 else { return 0..<total }
            let size = Swift.min(Swift.abs(requested), total)
            if keeping {
                return requested > 0 ? 0..<size : (total - size)..<total
            }
            // Dropping: the complement of what `TAKE` would have kept.
            return requested > 0 ? size..<total : 0..<(total - size)
        }

        let rows = span(whole(args[1]), of: source.rows)
        let columns = span(args.count > 2 ? whole(args[2]) : nil, of: source.columns)
        guard !rows.isEmpty, !columns.isEmpty else { return .error(.calc) }

        let elements = rows.flatMap { row in columns.map { source[row, $0] } }
        return shaped(elements, rows: rows.count, columns: columns.count)
    }

    /// `TOROW` and `TOCOL`: every cell in reading order, with an ignore rule.
    ///
    /// `ignore` is 0 keep everything, 1 drop blanks, 2 drop errors, 3 drop both.
    private static func flattened(
        _ args: [CellValue], _ shape: ([CellValue]) -> CellValue
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        let source = matrix(of: args[0])
        let ignore = args.count > 1 ? (whole(args[1]) ?? 0) : 0
        let byColumn = args.count > 2 && truthy(args[2])

        var values: [CellValue] = []
        if byColumn {
            for column in 0..<source.columns {
                for row in 0..<source.rows { values.append(source[row, column]) }
            }
        } else {
            values = source.elements
        }
        let kept = values.filter { value in
            if ignore == 1 || ignore == 3, case .blank = value { return false }
            if ignore == 2 || ignore == 3, isError(value) { return false }
            return true
        }
        guard !kept.isEmpty else { return .error(.calc) }
        return shape(kept)
    }

    /// `WRAPROWS` and `WRAPCOLS`, which fold a vector into a rectangle.
    private static func wrapped(_ args: [CellValue], intoRows: Bool) -> CellValue {
        if let error = args.first(where: isError) { return error }
        let values = matrix(of: args[0]).elements
        guard let width = whole(args[1]), width >= 1 else { return .error(.value) }
        let pad = args.count > 2 ? args[2] : CellValue.error(.na)

        let lines = (values.count + width - 1) / width
        var padded = values
        // A rectangle, always: the last line is filled out rather than left short, because a
        // ragged result cannot be written into cells.
        padded.append(contentsOf: Array(repeating: pad, count: lines * width - values.count))

        guard intoRows else {
            // Columns: the vector runs down the first column, then the second.
            var elements: [CellValue] = []
            for row in 0..<width {
                for column in 0..<lines { elements.append(padded[column * width + row]) }
            }
            return shaped(elements, rows: width, columns: lines)
        }
        return shaped(padded, rows: lines, columns: width)
    }

    /// `CHOOSEROWS` and `CHOOSECOLS`.
    private static func chosen(_ args: [CellValue], byColumn: Bool) -> CellValue {
        if let error = args.first(where: isError) { return error }
        let source = matrix(of: args[0])
        let total = byColumn ? source.columns : source.rows

        var order: [Int] = []
        for argument in args.dropFirst() {
            for value in matrix(of: argument).elements {
                guard let requested = whole(value), requested != 0 else { return .error(.value) }
                // Negative counts from the end, as everywhere in this family.
                let index = requested > 0 ? requested - 1 : total + requested
                guard index >= 0, index < total else { return .error(.value) }
                order.append(index)
            }
        }
        guard !order.isEmpty else { return .error(.value) }
        return assembled(order, from: source, byColumn: byColumn)
    }

    /// Whether a lookup value matches a candidate, optionally by wildcard.
    private static func matches(
        _ lookup: CellValue, _ candidate: CellValue, wildcard: Bool
    ) -> Bool {
        guard wildcard, case .text(let pattern) = lookup, case .text(let text) = candidate else {
            return FormulaEvaluator.compareValues(lookup, candidate) == .orderedSame
        }
        return BuiltinAggregationFunctions.matchesCriteria(.text(text), pattern)
    }
}
