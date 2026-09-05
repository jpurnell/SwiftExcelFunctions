import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// The lookups, against tables whose shape is known rather than guessed.
///
/// Every expectation here is Excel's documented positional semantics. The three
/// marked as regressions were measured failing against the build before
/// `CellMatrix` existed, and the reason each failed was the same: the value the
/// function received could not say what shape it was.
final class ShapedLookupTests: XCTestCase {

    // MARK: - Helpers

    private struct Cells: CellValueProvider {
        var stored: [CellRef: CellValue] = [:]
        func value(at ref: CellRef) -> CellValue? { stored[ref] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { stored[ref] }
        func values(in range: CellRange) -> [CellValue] { range.cells.compactMap { stored[$0] } }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
    }

    private func function(named name: String) -> ExcelFunction? {
        BuiltinNavigationFunctions.all.first { $0.name == name }
    }

    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let fn = function(named: name) else {
            XCTFail("\(name) is not registered")
            return .error(.name)
        }
        return try fn.evaluate(args)
    }

    /// A table of the stated shape.
    private func grid(_ rows: [[CellValue]],
                      file: StaticString = #filePath, line: UInt = #line) -> CellValue {
        let width = rows.first?.count ?? 0
        guard rows.allSatisfy({ $0.count == width }),
              let matrix = CellMatrix(elements: rows.flatMap { $0 },
                                      rows: rows.count, columns: width) else {
            XCTFail("ragged table", file: file, line: line)
            return .error(.value)
        }
        return .array(matrix)
    }

    // MARK: - VLOOKUP

    /// **Regression.** A four-column table asked for its third column.
    ///
    /// Measured before the fix: `#N/A`. Twelve elements divide evenly by three,
    /// so the width search stopped at three, read the table as 4×3, and found no
    /// row whose first cell was `"b"`.
    func testVlookupOnAFourColumnTable() throws {
        let table = grid([
            [.text("a"), .text("a2"), .text("a3"), .text("a4")],
            [.text("b"), .text("b2"), .text("b3"), .text("b4")],
            [.text("c"), .text("c2"), .text("c3"), .text("c4")],
        ])
        XCTAssertEqual(try eval("VLOOKUP", .text("b"), table, .number(3), .bool(false)),
                       .text("b3"))
    }

    /// The last column of a wide table, where the width matters most.
    func testVlookupReachesTheLastColumn() throws {
        let table = grid([
            [.number(1), .text("a2"), .text("a3"), .text("a4"), .text("a5")],
            [.number(2), .text("b2"), .text("b3"), .text("b4"), .text("b5")],
        ])
        XCTAssertEqual(try eval("VLOOKUP", .number(2), table, .number(5), .bool(false)),
                       .text("b5"))
    }

    /// A column index past the table's width is `#REF!`, as in Excel.
    func testVlookupPastTheLastColumnIsARefError() throws {
        let table = grid([[.number(1), .text("a2")], [.number(2), .text("b2")]])
        XCTAssertEqual(try eval("VLOOKUP", .number(2), table, .number(3), .bool(false)),
                       .error(.ref))
    }

    /// A blank inside the table no longer shifts the rows under it.
    func testVlookupOverATableWithAGap() throws {
        let table = grid([
            [.text("a"), .text("a2"), .blank],
            [.text("b"), .text("b2"), .text("b3")],
        ])
        XCTAssertEqual(try eval("VLOOKUP", .text("b"), table, .number(3), .bool(false)),
                       .text("b3"))
    }

    // MARK: - HLOOKUP

    /// **Regression.** The mirror of the VLOOKUP case, on a four-row table.
    func testHlookupOnAFourRowTable() throws {
        let table = grid([
            [.text("a"), .text("b"), .text("c")],
            [.text("a2"), .text("b2"), .text("c2")],
            [.text("a3"), .text("b3"), .text("c3")],
            [.text("a4"), .text("b4"), .text("c4")],
        ])
        XCTAssertEqual(try eval("HLOOKUP", .text("b"), table, .number(3), .bool(false)),
                       .text("b3"))
    }

    func testHlookupPastTheLastRowIsARefError() throws {
        let table = grid([[.number(1), .number(2)], [.text("a"), .text("b")]])
        XCTAssertEqual(try eval("HLOOKUP", .number(2), table, .number(3), .bool(false)),
                       .error(.ref))
    }

    // MARK: - INDEX

    /// **Regression.** A 2×3 block asked for row 2, column 1.
    ///
    /// Measured before the fix: `2`, the second element of the flat list. The
    /// answer is `4`, the first cell of the second row. The old code said so
    /// itself — "this doesn't work without knowing dimensions."
    func testIndexReadsRowAndColumnOnABlock() throws {
        let block = grid([[.number(1), .number(2), .number(3)],
                          [.number(4), .number(5), .number(6)]])
        XCTAssertEqual(try eval("INDEX", block, .number(2), .number(1)), .number(4))
        XCTAssertEqual(try eval("INDEX", block, .number(1), .number(3)), .number(3))
        XCTAssertEqual(try eval("INDEX", block, .number(2), .number(3)), .number(6))
    }

    func testIndexPastTheBlockIsARefError() throws {
        let block = grid([[.number(1), .number(2)], [.number(3), .number(4)]])
        XCTAssertEqual(try eval("INDEX", block, .number(3), .number(1)), .error(.ref))
        XCTAssertEqual(try eval("INDEX", block, .number(1), .number(3)), .error(.ref))
    }

    /// One-dimensional `INDEX` counts along the vector, whichever way it runs.
    func testIndexOverVectors() throws {
        let column = CellValue.array(CellMatrix(column: [.number(10), .number(20), .number(30)]))
        XCTAssertEqual(try eval("INDEX", column, .number(3)), .number(30))

        let row = CellValue.array(CellMatrix(row: [.number(10), .number(20), .number(30)]))
        XCTAssertEqual(try eval("INDEX", row, .number(3)), .number(30))
    }

    /// **Regression, end to end.** `INDEX(A1:A4, 3)` with `A2` empty.
    ///
    /// Measured before the fix: `40`. The blank was dropped when the range was
    /// read, so the third position held the fourth cell. This is the failure the
    /// whole change exists for, and it goes through the evaluator rather than
    /// calling the function directly, because the loss happened during the read.
    func testIndexOverARangeWithAGap() throws {
        var cells = Cells()
        cells.stored[CellRef("A1")] = .number(10)
        // A2 empty
        cells.stored[CellRef("A3")] = .number(30)
        cells.stored[CellRef("A4")] = .number(40)

        let result = try FormulaEvaluator.evaluate(
            .function("INDEX", [
                .cellRange(CellRange(from: CellRef("A1"), to: CellRef("A4"))),
                .number(3),
            ]),
            cells: cells, names: NamedRangeCollection())
        XCTAssertEqual(result, .number(30))
    }

    /// And the blank itself is reachable, rather than being a hole that shifts.
    func testIndexCanLandOnABlank() throws {
        var cells = Cells()
        cells.stored[CellRef("A1")] = .number(10)
        cells.stored[CellRef("A3")] = .number(30)

        let result = try FormulaEvaluator.evaluate(
            .function("INDEX", [
                .cellRange(CellRange(from: CellRef("A1"), to: CellRef("A3"))),
                .number(2),
            ]),
            cells: cells, names: NamedRangeCollection())
        XCTAssertEqual(result, .blank)
    }

    // MARK: - MATCH

    /// `MATCH` counts positions too, so a gap must not close under it either.
    func testMatchOverARangeWithAGap() throws {
        var cells = Cells()
        cells.stored[CellRef("A1")] = .number(10)
        // A2 empty
        cells.stored[CellRef("A3")] = .number(30)

        let result = try FormulaEvaluator.evaluate(
            .function("MATCH", [
                .number(30),
                .cellRange(CellRange(from: CellRef("A1"), to: CellRef("A3"))),
                .number(0),
            ]),
            cells: cells, names: NamedRangeCollection())
        XCTAssertEqual(result, .number(3))
    }
}
