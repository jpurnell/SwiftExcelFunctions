import Foundation
import SwiftExcelCore

/// Finding one cell of a rendered pivot table from a `GETPIVOTDATA` call's field/item pairs.
///
/// ## What is being read
///
/// A pivot table's values are **already on the worksheet**. Excel renders them into cells and
/// caches them there like any other formula result, so this navigates a grid rather than
/// aggregating anything — `xl/pivotCache/` contributes the field *names* and not one record.
///
/// The grid, from `pivotTable8` of `Dot Com YTD Performance Report 6 20.xlsx`:
///
/// ```
/// 135  Scenario | Region  | LOBMix_noXH | BP/IP  | 20  | 21  | 22    ← names + column items
/// 136  CY       | GBR     | V           |        | 303 | 301 | 256
/// 137           |         | D           |        |1633 |1233 | 944
/// 139           |         | VD          | BP     | 487 | 319 | 390
/// 141           |         |             |(blank) |1406 |1315 |1361
/// 142           |         | VD Total    |        |2076 |1852 |1989   ← a subtotal
/// 146           | GBR Total                      |5011 |4130 |4038
/// 243  Grand Total                               |48095|47039|45282
/// ```
///
/// ## The three things that make it hard
///
/// **Labels are sparse.** `Scenario` and `Region` are written on row 136 and inherited by every
/// row beneath until they change. A lookup that requires a literal match in every label column
/// finds row 136 and nothing else — the overwhelming majority of corpus cells are on rows that
/// write no label at all.
///
/// **Subtotals are answers.** 420 corpus cells at one anchor constrain three of four row
/// fields, and Excel answers them from row 142, the row labelled `VD Total`. Treating subtotal
/// rows as "not data" and skipping them would refuse every one.
///
/// **Items are not text.** The column items here are numbers, `(blank)` is a real item
/// rendered as literal text, and a name is matched case-insensitively but never trimmed.
enum PivotTableLookup {

    /// One `field, item` pair from a call.
    struct Pair {
        let field: String
        let item: CellValue
    }

    /// The cell a call's pairs identify, or `nil` where no single cell answers.
    ///
    /// - Parameters:
    ///   - pairs: The field/item pairs, in the order written. Order does not matter: Excel
    ///     matches by name.
    ///   - dataField: The data field's position in ``PivotTableLayout/dataFields``, which
    ///     selects a row when the values pseudo-field is on the row axis.
    ///   - layout: The table to look in.
    ///   - cells: Where the rendered values are read from.
    /// - Returns: The cell holding the value, or `nil` to refuse.
    static func cell(forPairs pairs: [Pair], dataField: Int,
                     in layout: PivotTableLayout,
                     cells: any CellValueProvider) -> CellRef? {
        // A pair naming a page field is a **consistency check**, not a constraint: the filter
        // was applied before the table was rendered. Naming the item it is set to is
        // redundant and fine; naming any other item asks for numbers this table does not
        // contain, and answering from the rows that are here would report one filter's figure
        // under another's name.
        var remaining: [Pair] = []
        for pair in pairs {
            guard let index = layout.pageFields.firstIndex(where: {
                $0.lowercased() == pair.field.lowercased()
            }) else {
                remaining.append(pair)
                continue
            }
            guard index < layout.pageFieldRows.count else { return nil }
            let selection = CellRef(column: layout.range.start.column + 1,
                                    row: layout.pageFieldRows[index])
            let applied = cells.value(at: selection, inSheet: layout.sheet) ?? .blank
            // `(All)` is no filter at all, so it agrees with nothing in particular and
            // cannot confirm the item asked for.
            guard matches(applied, pair.item) else { return nil }
        }

        guard let column = column(forPairs: remaining, in: layout, cells: cells),
              let row = row(forPairs: remaining, dataField: dataField,
                            in: layout, cells: cells) else {
            return nil
        }
        return CellRef(column: column, row: row)
    }

    // MARK: - The column

    /// The data column the column-axis pairs select.
    ///
    /// With no column fields there is one data column and no pair can name it. With one, the
    /// items are written across ``PivotTableLayout/headerRow``.
    ///
    /// **More than one column field is refused**, which is the whole of what this cannot yet
    /// answer: 960 corpus cells, every one of them on `pivotTable47` at `D92:R247`.
    ///
    /// Its items stack down two header rows, the outer one sparse across the columns the way
    /// row labels are sparse down the rows, with a column subtotal beside them:
    ///
    /// ```
    ///  92                            | Scenario | Region |     |     |     |
    ///  93                            | CY       |        |     |     |     | CY Total
    ///  94  Values | Last21Flag | Report_Date | GBR | WNE | FRE | BLT | KEY |
    ///  95   B1    | L21        | 2014-06-02  | 223 |  85 | 280 | 343 | 187 | 1118
    /// ```
    ///
    /// Answering it needs the same fill-across the rows already get, and two further things
    /// that pivot also shows: a **gap** in the row prefix (`Last21Flag` is left unconstrained
    /// by 930 of those cells), and a subtotal caption written `"Total  HSI"` rather than
    /// `"HSI Total"`. Refusing all three is why this run reports **0 differed** — every cell
    /// it cannot answer says so.
    private static func column(forPairs pairs: [Pair], in layout: PivotTableLayout,
                               cells: any CellValueProvider) -> Int? {
        let named = pairs.filter { pair in
            layout.columnFields.contains { $0.matches(pair.field) }
        }
        guard layout.columnFields.count <= 1 else { return nil }
        guard let field = layout.columnFields.first else {
            // No column axis: the single data column is the first one.
            return named.isEmpty ? layout.firstDataSheetColumn : nil
        }
        guard case .field = field, let pair = named.first, named.count == 1 else {
            // A column axis nobody named asks for the total across it, which lives in the
            // grand total column — and `nil` where the table renders none, which is the
            // common case. Such a table holds its overall total in no cell at all.
            return named.isEmpty ? layout.grandTotalColumn : nil
        }
        for column in layout.dataColumns {
            let header = CellRef(column: column, row: layout.headerRow)
            let item = cells.value(at: header, inSheet: layout.sheet) ?? .blank
            if matches(item, pair.item) { return column }
        }
        return nil
    }

    // MARK: - The row

    /// The row the row-axis pairs select.
    ///
    /// Row fields are **hierarchical**, outermost first, and a pair constrains the field whose
    /// label column it names. The constrained fields must form a prefix of that hierarchy: a
    /// table grouped `Scenario → Region` renders a total for `CY` and one for `CY/GBR`, and
    /// never one for `GBR` across all scenarios, because that grouping was never computed.
    /// Asking for the latter is refused rather than answered from a row that means something
    /// else.
    ///
    /// Where the prefix is shorter than the hierarchy, the answer is that prefix's **subtotal**
    /// row; where it is the whole hierarchy, it is a data row; where it is empty, the grand
    /// total.
    private static func row(forPairs pairs: [Pair], dataField: Int,
                            in layout: PivotTableLayout,
                            cells: any CellValueProvider) -> Int? {
        guard !layout.rowFields.isEmpty else {
            return pairs.isEmpty ? layout.grandTotalRow : nil
        }

        // Match each row field to the pair naming it, keeping the axis's own order. The
        // values pseudo-field is selected by the data field argument rather than by a pair.
        var wanted: [CellValue?] = []
        var used = 0
        for field in layout.rowFields {
            switch field {
            case .dataFieldNames:
                guard dataField < layout.dataFields.count else { return nil }
                wanted.append(.text(layout.dataFields[dataField]))
                used += 1
            case .field(let name):
                guard let pair = pairs.first(where: {
                    $0.field.lowercased() == name.lowercased()
                }) else {
                    wanted.append(nil)
                    continue
                }
                wanted.append(pair.item)
                used += 1
            }
        }
        // Every row-axis pair must have landed on a field; one that did not names a field
        // this table does not put on the rows.
        let onRowAxis = pairs.filter { pair in
            layout.rowFields.contains { $0.matches(pair.field) }
        }
        guard used == onRowAxis.count + (layout.rowFields.contains(.dataFieldNames) ? 1 : 0)
        else {
            return nil
        }
        // Anything not on the row axis, the column axis or the page axis is not in the table.
        for pair in pairs where !layout.rowFields.contains(where: { $0.matches(pair.field) })
            && !layout.columnFields.contains(where: { $0.matches(pair.field) }) {
            return nil
        }

        // The constrained fields must be a prefix: no gaps, because the grouping that would
        // answer a gap was never rendered.
        let depth = wanted.prefix { $0 != nil }.count
        guard wanted.dropFirst(depth).allSatisfy({ $0 == nil }) else { return nil }
        guard depth > 0 else { return layout.grandTotalRow }

        return scan(depth: depth, wanted: wanted, in: layout, cells: cells)
    }

    /// Walks the rendered rows, carrying labels down, and returns the row totalling to `depth`.
    ///
    /// The scan keeps the last label seen in each column, which is what makes a sparse
    /// rendering readable: a row writing nothing in columns 0 and 1 still *has* those values.
    /// Writing a label also clears every column to its right, because a new group starts there.
    ///
    /// ## Two rows can be the total of a group, and which one depends on the data
    ///
    /// **Excel renders a subtotal row only where the group actually splits.** In the corpus
    /// fixture, `LOBMix_noXH` = `VD` has three `BP/IP` items beneath it and gets a `VD Total`
    /// row; `V`, `D` and `T` have none, and their single data row *is* their total — no
    /// subtotal row is written for them at all.
    ///
    /// ```
    /// 136  CY | GBR | V        |         | 303   ← asking for (CY, GBR, V) ends here
    /// 139     |     | VD       | BP      | 487
    /// 140     |     |          | IP      | 183
    /// 141     |     |          | (blank) | 1406
    /// 142     |     | VD Total |         | 2076  ← asking for (CY, GBR, VD) ends here
    /// ```
    ///
    /// So a row answers for a prefix of length `depth` when either:
    ///
    /// - **nothing finer is written on it** and its carried labels match the prefix — the
    ///   group never split, so this row is its own total; or
    /// - it is the group's **subtotal row**: its last written label is in column `depth - 1`
    ///   and reads `"<item> Total"`.
    ///
    /// A lookup that only knew the second rule would refuse every unsplit group; one that only
    /// knew the first would return row 139 for `VD` — one `BP/IP` item's figure reported as the
    /// total of all three.
    ///
    /// The `"… Total"` suffix is tested **only after** the prefix above it has already matched,
    /// so it never decides which group a row belongs to; it only confirms that this row totals
    /// the group the scan is already standing in. That is what keeps an item genuinely named
    /// `"VD Total"` from being read as a subtotal of `"VD"`.
    private static func scan(depth: Int, wanted: [CellValue?], in layout: PivotTableLayout,
                             cells: any CellValueProvider) -> Int? {
        let start = layout.range.start.column
        let fields = layout.rowFields.count
        var carried = [CellValue?](repeating: nil, count: fields)
        let lastRow = layout.grandTotalRow.map { $0 - 1 } ?? layout.range.end.row
        guard layout.firstDataSheetRow <= lastRow else { return nil }

        for row in layout.firstDataSheetRow...lastRow {
            var deepest: Int?
            for offset in 0..<fields {
                let label = cells.value(at: CellRef(column: start + offset, row: row),
                                        inSheet: layout.sheet) ?? .blank
                guard !isBlank(label) else { continue }
                carried[offset] = label
                // A new group here means every finer grouping restarts.
                for finer in (offset + 1)..<fields { carried[finer] = nil }
                deepest = offset
            }
            guard let deepest else { continue }

            // The group never split: this row is the whole of it, and so is its total.
            if deepest < depth, matchesPrefix(carried, wanted, depth: depth) {
                return row
            }
            // The group did split, and this is the row Excel wrote to total it.
            if depth < fields, deepest == depth - 1,
               matchesPrefix(carried, wanted, depth: depth - 1),
               let label = carried[depth - 1], let item = wanted[depth - 1],
               matchesTotal(label, of: item) {
                return row
            }
        }
        return nil
    }

    /// Whether the carried labels agree with what was asked for, down to `depth` columns.
    private static func matchesPrefix(_ carried: [CellValue?], _ wanted: [CellValue?],
                                      depth: Int) -> Bool {
        for index in 0..<depth {
            guard let want = wanted[index] else { continue }
            guard let have = carried[index], matches(have, want) else { return false }
        }
        return true
    }

    /// Whether a label is the subtotal caption for an item — `"VD"` against `"VD Total"`.
    ///
    /// Checked **only after** the prefix above it has already matched, so this never decides
    /// which group a row belongs to; it only confirms that the row is the total of the group
    /// the scan is already standing in. The word is Excel's and is localised — it reads
    /// `"Gesamtergebnis"` in German — so a table whose subtotals are spelled another way
    /// refuses rather than answering from the wrong row.
    private static func matchesTotal(_ label: CellValue, of item: CellValue) -> Bool {
        guard case .text(let rendered) = label else { return false }
        let wanted = text(of: item)
        guard rendered.count > wanted.count else { return false }
        guard rendered.lowercased().hasPrefix(wanted.lowercased()) else { return false }
        let suffix = rendered.dropFirst(wanted.count)
        return suffix.trimmingCharacters(in: .whitespaces).lowercased() == "total"
    }

    // MARK: - Comparing items

    /// Whether a rendered label is the item a formula asked for.
    ///
    /// **By value, not by rendering.** The column items in the corpus fixture are numbers, so
    /// `"20"` written as text is not the same thing as `20`; comparing what the cell displays
    /// would match nothing. Text is compared case-insensitively and **never trimmed**, since
    /// the same workbook writes data field captions with a leading space.
    private static func matches(_ rendered: CellValue, _ wanted: CellValue) -> Bool {
        switch (rendered, wanted) {
        case (.number(let lhs), .number(let rhs)):
            return lhs == rhs
        // **An omitted item names the blank one.** 204 corpus cells are written
        // `GETPIVOTDATA("Subs",$C$134,…,"BP/IP",)` — a trailing comma with nothing after it —
        // and the group they want is the one Excel renders as the literal text `(blank)`.
        case (.text(Self.blankItemLabel), .blank):
            return true
        case (.bool(let lhs), .bool(let rhs)):
            return lhs == rhs
        default:
            return text(of: rendered).lowercased() == text(of: wanted).lowercased()
        }
    }

    /// A cell value as the text a label would be compared as.
    private static func text(of value: CellValue) -> String {
        switch value {
        case .text(let string): return string
        case .number(let number):
            return number == number.rounded() && abs(number) < 1e15
                ? String(Int(number))
                : String(number)
        case .bool(let flag): return flag ? "TRUE" : "FALSE"
        case .blank: return ""
        case .error(let error): return error.description
        default: return ""
        }
    }

    /// How Excel renders the empty item of a field.
    ///
    /// It is a real group with real numbers beside it, so this text is a *value* and not an
    /// absence — which is why ``isBlank(_:)`` says it is not blank, and why a formula that
    /// omits an item entirely is asking for exactly this row.
    private static let blankItemLabel = "(blank)"

    /// Whether a cell carries no label.
    ///
    /// `(blank)` is **not** blank — see ``blankItemLabel``.
    private static func isBlank(_ value: CellValue) -> Bool {
        switch value {
        case .blank: return true
        case .text(let string): return string.isEmpty
        default: return false
        }
    }
}
