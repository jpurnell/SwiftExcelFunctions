import Foundation
import SwiftExcelCore
import SwiftExcelFunctions

/// One sheet's cells, held flat, able to enumerate themselves.
///
/// ``InterpretedRun`` needs two things a file-backed provider does not offer together: cell
/// lookup, and a list of **which cells exist** so a dependency graph can be built. This is
/// that pair and nothing else — the smallest provider a simulation can run over.
struct CellSheet: CellValueProvider, PopulatedCellProvider {

    private(set) var cells: [Int: CellValue]

    init(cells: [Int: CellValue] = [:]) { self.cells = cells }

    /// Keyed by position as **one integer**, not by spelling and not by a string.
    ///
    /// `$C$4` and `C4` are the same cell, so the `$` markers cannot be part of the key. The
    /// obvious fix — key by `"\(column):\(row)"` — is the one this file shipped first, and
    /// it is a documented mistake: `WorkbookSnapshot` in the oracle carries a note saying
    /// keying by a string "meant building that string on every read… the profile was almost
    /// entirely `_BinaryIntegerToASCII`". A simulation reads far harder than the oracle does —
    /// 200,000 trials over 30 formula cells is six million reads — and it made the same
    /// mistake anyway.
    ///
    /// Excel's grid is 16,384 columns, so a column fits in 14 bits and the two pack into one
    /// `Int` with no arithmetic worth measuring.
    private static func key(_ ref: CellRef) -> Int { ref.row << 15 | ref.column }

    subscript(ref: String) -> CellValue? {
        get { cells[Self.key(CellRef(ref))] }
        set { cells[Self.key(CellRef(ref))] = newValue }
    }

    func value(at ref: CellRef) -> CellValue? { cells[Self.key(ref)] }
    func value(at ref: CellRef, inSheet: String) -> CellValue? { cells[Self.key(ref)] }

    func lastPopulatedCell() -> CellRef? {
        populatedCells().max { ($0.row, $0.column) < ($1.row, $1.column) }
    }
    func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }

    func values(in range: CellRange) -> [CellValue] {
        range.cells.map { cells[Self.key($0)] ?? .blank }
    }
    func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }

    /// Every cell this sheet holds, unpacked from the position keys.
    func populatedCells() -> [CellRef] {
        cells.keys.map { CellRef(column: $0 & 0x7FFF, row: $0 >> 15) }
    }
}

/// No defined names: this model uses none, and inventing a resolver that answers anyway
/// would hide the day one does.
struct NoNames: NameResolver {
    func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
}
