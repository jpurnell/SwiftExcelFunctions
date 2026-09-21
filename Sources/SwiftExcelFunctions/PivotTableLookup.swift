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
/// ## The two axes are transposes of each other
///
/// That is the whole design. Row labels run down the label columns; column items run across
/// the header rows; both are **sparse**, written once and inherited by everything after them
/// until they change; and both carry **subtotals** in the same structural position. So one walk
/// answers for either, told which way to read.
///
/// ```
///  92                                        | Scenario | Region |
///  93                                        | CY       |        | CY Total | PY  |     | PY Total
///  94  Values   | Last21Flag    | Report_Date | GBR     | WNE    |          | GBR | WNE |
///  95   B1      | L21           | 2014-06-02  | 223     | 85     | 308      | 203 | 70  | 273
///  96           |               | 2014-06-03  | 245     | 108    | 353      | 213 | 111 | 324
///  97           | L21 Total     |             | 468     | 193    | 661      | 416 | 181 | 597
///  98           | (blank)       | 2014-05-19  | 109     | 40     | 149      | 90  | 30  | 120
/// 102  Total  B1                |             | 577     | 233    | 810      | 506 | 211 | 717
/// ```
///
/// `CY` is written once at `G93` and covers `G` and `H`, exactly as ` B1` is written once at
/// `D95` and covers everything down to `D102`. `CY Total` totals a column group; `L21 Total`
/// totals a row group; `Total  B1` totals another, with the word at the other end.
///
/// ## What has to be got right
///
/// **A subtotal is an answer.** Leaving a field unconstrained asks for the total across it, and
/// Excel rendered that total — 420 cells at one anchor leave the innermost row field free.
/// Excel writes a subtotal **only where the group splits**, though: `LOBMix_noXH` = `VD` has
/// three `BP/IP` items and gets a `VD Total` row, while `V` has none and its single data row is
/// its own total. Both rules are needed; either alone is wrong on most of the corpus.
///
/// **A constraint need not be a prefix.** 930 cells name `Report_Date` while leaving
/// `Last21Flag` above it free. That resolves here because the flag *partitions* the dates
/// rather than subdividing them, so exactly one row carries each date — which is checked
/// rather than assumed: a gap that leaves two rows matching is refused, because the total
/// across them is rendered nowhere.
///
/// **A subtotal caption is written either way round.** `"L21 Total"` puts the word after the
/// item and `"Total  B1"` puts it before, and both are in the same table. It is only ever
/// tested after everything above it has already matched, so it confirms a row rather than
/// choosing one.
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
    ///     constrains a row when the values pseudo-field is on the row axis.
    ///   - layout: The table to look in.
    ///   - cells: Where the rendered values are read from.
    /// - Returns: The cell holding the value, or `nil` to refuse.
    static func cell(forPairs pairs: [Pair], dataField: Int,
                     in layout: PivotTableLayout,
                     cells: any CellValueProvider) -> CellRef? {
        var remaining: [Pair] = []
        for pair in pairs {
            guard let index = layout.pageFields.firstIndex(where: {
                $0.lowercased() == pair.field.lowercased()
            }) else {
                remaining.append(pair)
                continue
            }
            guard agreesWithFilter(pair, at: index, in: layout, cells: cells) else { return nil }
        }

        // Every remaining pair must name an axis this table actually has. One that names none
        // is asking about a field the pivot does not group by.
        for pair in remaining {
            let onRows = layout.rowFields.contains { $0.matches(pair.field) }
            let onColumns = layout.columnFields.contains { $0.matches(pair.field) }
            guard onRows || onColumns else { return nil }
        }

        guard let column = line(forPairs: remaining, dataField: nil,
                                on: columnAxis(of: layout), in: layout, cells: cells,
                                whenUnconstrained: layout.grandTotalColumn),
              let row = line(forPairs: remaining, dataField: dataField,
                             on: rowAxis(of: layout), in: layout, cells: cells,
                             whenUnconstrained: layout.grandTotalRow) else {
            return nil
        }
        return CellRef(column: column, row: row)
    }

    // MARK: - The page fields

    /// Whether a pair naming a page field agrees with the filter the table was rendered under.
    ///
    /// A page field is **not** a constraint on the grid: the filter was applied before any of
    /// these numbers were written. Naming the item it is set to is redundant and harmless;
    /// naming any other item asks for figures this rendering does not contain, and answering
    /// from the rows that *are* here would report one filter's number under another's name.
    ///
    /// `(All)` is no filter at all, so it confirms no particular item and the pair is refused.
    private static func agreesWithFilter(_ pair: Pair, at index: Int,
                                         in layout: PivotTableLayout,
                                         cells: any CellValueProvider) -> Bool {
        guard index < layout.pageFieldRows.count else { return false }
        let selection = CellRef(column: layout.range.start.column + 1,
                                row: layout.pageFieldRows[index])
        let applied = cells.value(at: selection, inSheet: layout.sheet) ?? .blank
        return matches(applied, pair.item)
    }

    // MARK: - One axis, read either way

    /// One axis of a rendered pivot, described so the same walk reads rows or columns.
    ///
    /// For the **row** axis a *line* is a row and each field's labels run down a column; for
    /// the **column** axis a line is a column and each field's items run across a row. Nothing
    /// else differs, which is why this is one type and not two.
    private struct Axis {
        /// The fields on this axis, outermost first.
        let fields: [PivotAxisField]
        /// The lines to walk, in rendered order.
        let lines: ClosedRange<Int>
        /// The cell holding field `field`'s label on line `line`.
        let label: (_ field: Int, _ line: Int) -> CellRef
    }

    private static func rowAxis(of layout: PivotTableLayout) -> Axis {
        let start = layout.range.start.column
        return Axis(
            fields: layout.rowFields,
            lines: layout.firstDataSheetRow...Swift.max(layout.firstDataSheetRow,
                                                        layout.range.end.row),
            label: { field, line in CellRef(column: start + field, row: line) })
    }

    /// The column axis, whose items stack **down** one header row per field.
    ///
    /// `firstHeaderRow` is where the outermost field's items are written and each further field
    /// takes the row below — `pivotTable47` puts `Scenario` on row 93 and `Region` on row 94,
    /// with data from row 95, which is `firstDataRow` = 3 rows below the top of the range.
    private static func columnAxis(of layout: PivotTableLayout) -> Axis {
        let top = layout.range.start.row + layout.firstHeaderRow
        let first = layout.firstDataSheetColumn
        return Axis(
            fields: layout.columnFields,
            lines: first...Swift.max(first, layout.range.end.column),
            label: { field, line in CellRef(column: line, row: top + field) })
    }

    /// The line on one axis that a call's pairs select.
    ///
    /// - Parameters:
    ///   - pairs: Every pair still in play, of which those naming this axis are used.
    ///   - dataField: The data field's index, where the values pseudo-field is on this axis.
    ///   - axis: The axis to walk.
    ///   - layout: The table.
    ///   - cells: Where the rendered labels are read from.
    ///   - whenUnconstrained: The line to answer with when nothing constrains this axis —
    ///     the grand total row or column, and `nil` where the table renders none.
    /// - Returns: The line, or `nil` to refuse.
    private static func line(forPairs pairs: [Pair], dataField: Int?, on axis: Axis,
                             in layout: PivotTableLayout, cells: any CellValueProvider,
                             whenUnconstrained: Int?) -> Int? {
        guard !axis.fields.isEmpty else {
            // No axis: there is one line of data, and no pair may claim to narrow it.
            let named = pairs.contains { pair in
                axis.fields.contains { $0.matches(pair.field) }
            }
            return named ? nil : axis.lines.lowerBound
        }

        var wanted = [CellValue?](repeating: nil, count: axis.fields.count)
        for (index, field) in axis.fields.enumerated() {
            switch field {
            case .dataFieldNames:
                guard let dataField, dataField < layout.dataFields.count else { return nil }
                wanted[index] = .text(layout.dataFields[dataField])
            case .field(let name):
                wanted[index] = pairs.first { $0.field.lowercased() == name.lowercased() }?.item
            }
        }

        // Nothing named this axis, so the answer is its total — which a table may not render.
        guard let target = wanted.lastIndex(where: { $0 != nil }) else {
            return whenUnconstrained
        }
        return walk(to: target, wanted: wanted, on: axis, sheet: layout.sheet, cells: cells)
    }

    /// Walks an axis, carrying labels along it, and returns the one line that answers.
    ///
    /// Each line is tested two ways, and they are complementary rather than alternatives:
    ///
    /// - **As a data line**, where nothing finer than `target` is written on it and every
    ///   constrained field matches. This is what answers an unsplit group, whose single line
    ///   is its own total.
    /// - **As that group's subtotal line**, whose deepest written label is at `target` itself
    ///   and reads the item's name with `Total` at one end or the other.
    ///
    /// A line labelled `VD Total` never matches the first test, since that text is not `VD`, so
    /// the two never claim the same line for the same reason. Where they nonetheless both find
    /// something, or one finds two, **the answer is refused**: a number that stands for more
    /// than one grouping is not the one that was asked for.
    private static func walk(to target: Int, wanted: [CellValue?], on axis: Axis,
                             sheet: String, cells: any CellValueProvider) -> Int? {
        let count = axis.fields.count
        var carried = [CellValue?](repeating: nil, count: count)
        var found: Int?

        for line in axis.lines {
            var deepest: Int?
            for field in 0..<count {
                let label = cells.value(at: axis.label(field, line), inSheet: sheet) ?? .blank
                guard !isBlank(label) else { continue }
                carried[field] = label
                // A new group here means every finer grouping starts over.
                for finer in (field + 1)..<count { carried[finer] = nil }
                deepest = field
            }
            guard let deepest else { continue }
            guard matchesAll(carried, wanted, upTo: target) else { continue }

            let isData = deepest <= target && matchesOne(carried[target], wanted[target])
            // **A subtotal needs everything above it named.** It is the total of one specific
            // outer group — `GBR Total` sits inside `CY` and counts no `PY` — so with a field
            // above `target` left free it cannot stand for the total across them. A *data*
            // line has no such trouble: it is one cell of the grid, and a gap above it is
            // answerable exactly when it still picks out one line, which the walk checks.
            let named = wanted[0..<target].allSatisfy { $0 != nil }
            let isTotal = named && deepest == target
                && matchesTotal(carried[target], of: wanted[target])
            guard isData || isTotal else { continue }
            // A second candidate means the question does not pick out one number.
            guard found == nil else { return nil }
            found = line
        }
        return found
    }

    /// Whether every constrained field **above** `target` agrees with what was asked for.
    private static func matchesAll(_ carried: [CellValue?], _ wanted: [CellValue?],
                                   upTo target: Int) -> Bool {
        for index in 0..<target where wanted[index] != nil {
            guard matchesOne(carried[index], wanted[index]) else { return false }
        }
        return true
    }

    private static func matchesOne(_ carried: CellValue?, _ wanted: CellValue?) -> Bool {
        guard let wanted else { return true }
        guard let carried else { return false }
        return matches(carried, wanted)
    }

    /// Whether a label is the subtotal caption for an item.
    ///
    /// **Both ends.** `"L21 Total"` and `"Total  B1"` are in the same corpus table: the first
    /// is how an ordinary field totals a group, the second how the values pseudo-field does,
    /// and the doubled space in the second is real — the caption it is built from is `" B1"`,
    /// with a leading space of its own, so nothing here may trim.
    ///
    /// Tested **only after** everything above it has already matched, so it never decides which
    /// group a line belongs to; it confirms that this line totals the group already reached.
    /// That is what keeps an item genuinely named `"VD Total"` from reading as a total of
    /// `"VD"`. The word is Excel's and is localised — `"Gesamtergebnis"` in German — so a table
    /// whose totals are captioned another way refuses rather than answering from a wrong line.
    private static func matchesTotal(_ label: CellValue?, of item: CellValue?) -> Bool {
        guard let label, let item, case .text(let rendered) = label else { return false }
        let wanted = text(of: item)
        guard !wanted.isEmpty, rendered.count > wanted.count else { return false }
        let lowered = rendered.lowercased()
        let target = wanted.lowercased()

        if lowered.hasPrefix(target) {
            let suffix = rendered.dropFirst(wanted.count)
            if suffix.trimmingCharacters(in: .whitespaces).lowercased() == Self.totalWord {
                return true
            }
        }
        guard lowered.hasSuffix(target) else { return false }
        let prefix = rendered.dropLast(wanted.count)
        return prefix.trimmingCharacters(in: .whitespaces).lowercased() == Self.totalWord
    }

    /// The word Excel writes into a subtotal's caption.
    private static let totalWord = "total"

    // MARK: - Comparing items

    /// Whether a rendered label is the item a formula asked for.
    ///
    /// **By value, not by rendering.** The column items in one corpus fixture are numbers, so
    /// `"20"` written as text is not the same thing as `20`; comparing what the cell displays
    /// would match nothing. Text is compared case-insensitively and **never trimmed**, since
    /// the same workbook writes data field captions with a leading space.
    private static func matches(_ rendered: CellValue, _ wanted: CellValue) -> Bool {
        switch (rendered, wanted) {
        case (.number(let lhs), .number(let rhs)):
            return lhs == rhs
        case (.bool(let lhs), .bool(let rhs)):
            return lhs == rhs
        // **An omitted item names the blank one.** 204 corpus cells are written
        // `GETPIVOTDATA("Subs",$C$134,…,"BP/IP",)` — a trailing comma with nothing after it —
        // and the group they want is the one Excel renders as the literal text `(blank)`.
        case (.text(Self.blankItemLabel), .blank):
            return true
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
    /// omits an item entirely is asking for exactly this line.
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
