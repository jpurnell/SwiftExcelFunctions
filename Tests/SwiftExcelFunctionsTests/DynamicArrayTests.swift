import Foundation
import Testing
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// The dynamic-array family, over ranges the way a workbook supplies them.
@Suite struct DynamicArrayTests {

    private struct Cells: CellValueProvider {
        var data: [String: CellValue] = [:]
        func value(at ref: CellRef) -> CellValue? { data[ref.reference] }
        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet sheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { range.cells.compactMap { value(at: $0) } }
        func values(in range: CellRange, inSheet sheet: String) -> [CellValue] { [] }
    }
    private struct Names: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private let letters = ["A", "B", "C", "D", "E", "F"]

    /// A rectangle starting at a column, and the AST that names it.
    private func block(_ start: String, _ rows: [[CellValue]]) -> (FormulaAST, [String: CellValue]) {
        guard let origin = letters.firstIndex(of: start), let width = rows.first?.count else {
            return (.error(.value), [:])
        }
        var data: [String: CellValue] = [:]
        for (r, row) in rows.enumerated() {
            for (c, value) in row.enumerated() { data["\(letters[origin + c])\(r + 1)"] = value }
        }
        let last = letters[origin + width - 1]
        return (.cellRange(CellRange(from: "\(start)1", to: "\(last)\(rows.count)")), data)
    }

    private func call(_ name: String, _ args: [FormulaAST],
                      _ data: [String: CellValue]) throws -> CellValue {
        try FormulaEvaluator.evaluate(
            .function(name, args), cells: Cells(data: data), names: Names(), functions: .builtin)
    }

    private func grid(_ value: CellValue) -> (rows: Int, columns: Int, values: [String])? {
        guard case .array(let m) = value else { return nil }
        return (m.rows, m.columns, m.elements.map(describe))
    }

    private func describe(_ value: CellValue) -> String {
        switch value {
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .text(let t): return t
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return e.rawValue
        case .blank: return "-"
        default: return "?"
        }
    }

    private func n(_ values: [Int]) -> [CellValue] { values.map { .number(Double($0)) } }

    // MARK: - FILTER

    @Test func filterKeepsTheRowsAColumnMaskSelects() throws {
        let (array, d1) = block("A", [n([1, 10]), n([2, 20]), n([3, 30])])
        let (mask, d2) = block("C", [[.bool(true)], [.bool(false)], [.bool(true)]])
        let result = try call("FILTER", [array, mask], d1.merging(d2) { a, _ in a })
        #expect(grid(result)?.values == ["1", "10", "3", "30"])
        #expect(grid(result)?.rows == 2)
    }

    @Test func filterKeepsTheColumnsARowMaskSelects() throws {
        let (array, d1) = block("A", [n([1, 2, 3]), n([4, 5, 6])])
        let (mask, d2) = block("D", [[.bool(true), .bool(false), .bool(true)]])
        let result = try call("FILTER", [array, mask], d1.merging(d2) { a, _ in a })
        #expect(grid(result)?.values == ["1", "3", "4", "6"])
        #expect(grid(result)?.columns == 2)
    }

    /// Nothing kept is `if_empty`, or `#CALC!` when none was given — a result with no cells.
    @Test func filterWithNothingKept() throws {
        let (array, d1) = block("A", [n([1]), n([2])])
        let (mask, d2) = block("C", [[.bool(false)], [.bool(false)]])
        let data = d1.merging(d2) { a, _ in a }
        #expect(try call("FILTER", [array, mask], data) == .error(.calc))
        #expect(try call("FILTER", [array, mask, .text("none")], data) == .text("none"))
    }

    /// A mask matching neither dimension is refused rather than guessed at.
    @Test func filterRefusesAMaskThatFitsNeitherWay() throws {
        let (array, d1) = block("A", [n([1, 2]), n([3, 4])])
        let (mask, d2) = block("D", [[.bool(true)], [.bool(true)], [.bool(true)]])
        #expect(try call("FILTER", [array, mask], d1.merging(d2) { a, _ in a }) == .error(.value))
    }

    // MARK: - UNIQUE

    /// Order is first appearance, not sorted.
    @Test func uniqueKeepsFirstAppearanceOrder() throws {
        let (array, data) = block("A", [[.text("b")], [.text("a")], [.text("b")], [.text("c")]])
        #expect(grid(try call("UNIQUE", [array], data))?.values == ["b", "a", "c"])
    }

    /// `exactly_once` is a different question from distinctness.
    @Test func uniqueExactlyOnce() throws {
        let (array, data) = block("A", [[.text("b")], [.text("a")], [.text("b")]])
        #expect(grid(try call("UNIQUE", [array, .bool(false), .bool(true)], data))?.values == ["a"])
    }

    /// Whole rows are compared, not cells.
    @Test func uniqueComparesWholeRows() throws {
        let (array, data) = block("A", [n([1, 2]), n([1, 3]), n([1, 2])])
        #expect(grid(try call("UNIQUE", [array], data))?.rows == 2)
    }

    // MARK: - SORT and SORTBY

    @Test func sortOrdersByAColumn() throws {
        let (array, data) = block("A", [n([3, 30]), n([1, 10]), n([2, 20])])
        #expect(grid(try call("SORT", [array], data))?.values == ["1", "10", "2", "20", "3", "30"])
        #expect(grid(try call("SORT", [array, .number(2), .number(-1)], data))?.values == ["3", "30", "2", "20", "1", "10"])
    }

    @Test func sortRefusesAnIndexOutsideTheArray() throws {
        let (array, data) = block("A", [n([1, 2])])
        #expect(try call("SORT", [array, .number(5)], data) == .error(.value))
    }

    /// `SORTBY` orders by a separate array, and a second key breaks ties in the first.
    @Test func sortByUsesASeparateKeyAndIsStable() throws {
        let (array, d1) = block("A", [[.text("w")], [.text("x")], [.text("y")], [.text("z")]])
        let (major, d2) = block("C", [n([2]), n([1]), n([2]), n([1])])
        let (minor, d3) = block("D", [n([1]), n([2]), n([2]), n([1])])
        let data = d1.merging(d2) { a, _ in a }.merging(d3) { a, _ in a }

        #expect(grid(try call("SORTBY", [array, major], data))?.values == ["x", "z", "w", "y"], "ties keep their original order")
        #expect(grid(try call("SORTBY", [array, major, .number(1), minor], data))?.values == ["z", "x", "w", "y"], "the minor key breaks the tie")
    }

    // MARK: - TAKE, DROP, EXPAND

    @Test func takeFromEitherEnd() throws {
        let (array, data) = block("A", [n([1]), n([2]), n([3]), n([4])])
        #expect(grid(try call("TAKE", [array, .number(2)], data))?.values == ["1", "2"])
        #expect(grid(try call("TAKE", [array, .number(-2)], data))?.values == ["3", "4"])
    }

    @Test func dropIsTheComplementOfTake() throws {
        let (array, data) = block("A", [n([1]), n([2]), n([3]), n([4])])
        #expect(grid(try call("DROP", [array, .number(2)], data))?.values == ["3", "4"])
        #expect(grid(try call("DROP", [array, .number(-2)], data))?.values == ["1", "2"])
    }

    @Test func takeInBothDimensions() throws {
        let (array, data) = block("A", [n([1, 2, 3]), n([4, 5, 6])])
        #expect(grid(try call("TAKE", [array, .number(1), .number(2)], data))?.values == ["1", "2"])
    }

    /// The pad is `#N/A` by default: a cell that was never in the data has no value, and a
    /// zero is a number somebody might sum.
    @Test func expandPadsWithNotAvailable() throws {
        let (array, data) = block("A", [n([1, 2])])
        let result = try call("EXPAND", [array, .number(2), .number(3)], data)
        #expect(grid(result)?.values == ["1", "2", "#N/A", "#N/A", "#N/A", "#N/A"])
        #expect(grid(try call("EXPAND", [array, .number(1), .number(3), .number(0)],
                                     data))?.values == ["1", "2", "0"])
    }

    /// Expanding cannot shrink.
    @Test func expandRefusesASmallerSize() throws {
        let (array, data) = block("A", [n([1, 2, 3])])
        #expect(try call("EXPAND", [array, .number(1), .number(2)], data) == .error(.value))
    }

    // MARK: - Stacking

    @Test func vstackAndHstack() throws {
        let (first, d1) = block("A", [n([1, 2])])
        let (second, d2) = block("C", [n([3, 4])])
        let data = d1.merging(d2) { a, _ in a }

        let stacked = try call("VSTACK", [first, second], data)
        #expect(grid(stacked)?.rows == 2)
        #expect(grid(stacked)?.values == ["1", "2", "3", "4"])

        let beside = try call("HSTACK", [first, second], data)
        #expect(grid(beside)?.columns == 4)
        #expect(grid(beside)?.values == ["1", "2", "3", "4"])
    }

    /// Ragged stacks are padded with `#N/A`, because a rectangle is what comes out.
    @Test func stackingPadsShortLines() throws {
        let (wide, d1) = block("A", [n([1, 2, 3])])
        let (narrow, d2) = block("D", [n([9])])
        let result = try call("VSTACK", [wide, narrow], d1.merging(d2) { a, _ in a })
        #expect(grid(result)?.values == ["1", "2", "3", "9", "#N/A", "#N/A"])
    }

    // MARK: - Reshaping

    @Test func toRowAndToCol() throws {
        let (array, data) = block("A", [n([1, 2]), n([3, 4])])
        #expect(grid(try call("TOROW", [array], data))?.values == ["1", "2", "3", "4"])
        #expect(grid(try call("TOCOL", [array], data))?.rows == 4)
        #expect(grid(try call("TOCOL", [array, .number(0), .bool(true)], data))?.values == ["1", "3", "2", "4"], "scanned by column")
    }

    @Test func toColCanIgnoreBlanksAndErrors() throws {
        let (array, data) = block("A", [[.number(1), .blank], [.error(.na), .number(4)]])
        #expect(grid(try call("TOROW", [array, .number(3)], data))?.values == ["1", "4"])
    }

    @Test func wrapRowsAndWrapCols() throws {
        let (vector, data) = block("A", [n([1, 2, 3, 4, 5])])
        #expect(grid(try call("WRAPROWS", [vector, .number(2)], data))?.values == ["1", "2", "3", "4", "5", "#N/A"])
        #expect(grid(try call("WRAPROWS", [vector, .number(2), .number(0)], data))?.values == ["1", "2", "3", "4", "5", "0"])

        let columns = try call("WRAPCOLS", [vector, .number(2)], data)
        #expect(grid(columns)?.rows == 2)
        #expect(grid(columns)?.values == ["1", "3", "5", "2", "4", "#N/A"])
    }

    // MARK: - CHOOSEROWS and CHOOSECOLS

    @Test func chooseRowsSelectsInTheOrderNamed() throws {
        let (array, data) = block("A", [n([1]), n([2]), n([3])])
        #expect(grid(try call("CHOOSEROWS", [array, .number(3), .number(1)], data))?.values == ["3", "1"])
        #expect(grid(try call("CHOOSEROWS", [array, .number(-1)], data))?.values == ["3"])
    }

    /// Repeats are allowed: it selects, it does not filter.
    @Test func chooseRowsMayRepeat() throws {
        let (array, data) = block("A", [n([1]), n([2])])
        #expect(grid(try call("CHOOSEROWS", [array, .number(1), .number(1), .number(2)], data))?.values == ["1", "1", "2"])
    }

    @Test func chooseColsAndOutOfRange() throws {
        let (array, data) = block("A", [n([1, 2, 3])])
        #expect(grid(try call("CHOOSECOLS", [array, .number(2)], data))?.values == ["2"])
        #expect(try call("CHOOSECOLS", [array, .number(9)], data) == .error(.value))
    }

    // MARK: - XMATCH

    /// The default is **exact**, which is the difference from `MATCH`.
    @Test func xmatchDefaultsToExact() throws {
        let (array, data) = block("A", [n([10]), n([20]), n([30])])
        #expect(try call("XMATCH", [.number(20), array], data) == .number(2))
        #expect(try call("XMATCH", [.number(25), array], data) == .error(.na), "MATCH would have answered 2 and assumed the data were sorted")
    }

    @Test func xmatchNearestInEitherDirection() throws {
        let (array, data) = block("A", [n([10]), n([20]), n([30])])
        #expect(try call("XMATCH", [.number(25), array, .number(-1)], data) == .number(2))
        #expect(try call("XMATCH", [.number(25), array, .number(1)], data) == .number(3))
    }

    /// Nearest is by value, so the data need not be sorted.
    @Test func xmatchDoesNotAssumeSortedData() throws {
        let (array, data) = block("A", [n([30]), n([10]), n([20])])
        #expect(try call("XMATCH", [.number(25), array, .number(-1)], data) == .number(3))
    }

    @Test func xmatchSearchesBackwards() throws {
        let (array, data) = block("A", [n([10]), n([20]), n([10])])
        #expect(try call("XMATCH", [.number(10), array], data) == .number(1))
        #expect(try call("XMATCH", [.number(10), array, .number(0), .number(-1)], data) == .number(3))
    }

    @Test func xmatchWildcards() throws {
        let (array, data) = block("A", [[.text("apple")], [.text("banana")]])
        #expect(try call("XMATCH", [.text("ban*"), array, .number(2)], data) == .number(2))
        #expect(try call("XMATCH", [.text("ban*"), array], data) == .error(.na))
    }
}
