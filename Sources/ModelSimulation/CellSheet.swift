import Foundation
import SwiftExcelCore
import SwiftExcelFunctions

/// One sheet's cells, held flat, able to enumerate themselves.
///
/// ``InterpretedRun`` needs two things a file-backed provider does not offer together: cell
/// lookup, and a list of **which cells exist** so a dependency graph can be built. This is
/// that pair and nothing else — the smallest provider a simulation can run over.
struct CellSheet: CellValueProvider, PopulatedCellProvider {

    private(set) var cells: [String: CellValue]

    init(cells: [String: CellValue] = [:]) { self.cells = cells }

    /// Keyed by position, not by spelling: `$C$4` and `C4` are the same cell, and a
    /// dictionary keyed by the written form treats them as two.
    private static func key(_ ref: CellRef) -> String { "\(ref.column):\(ref.row)" }

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

    /// Every cell this sheet holds, rebuilt from the position keys.
    func populatedCells() -> [CellRef] {
        cells.keys.compactMap { key in
            let parts = key.split(separator: ":")
            guard parts.count == 2, let column = Int(parts[0]), let row = Int(parts[1]) else {
                return nil
            }
            return CellRef(column: column, row: row)
        }
    }
}

/// No defined names: this model uses none, and inventing a resolver that answers anyway
/// would hide the day one does.
struct NoNames: NameResolver {
    func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
}
