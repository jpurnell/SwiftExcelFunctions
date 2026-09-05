import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// One formula, evaluated once, filling a span.
///
/// The result is an assignment rather than a mutation: this package has no
/// workbook to write into, and returning the mapping keeps it that way while
/// still doing the whole job.
final class SpillTests: XCTestCase {

    private struct Cells: CellValueProvider {
        var stored: [CellRef: CellValue] = [:]
        func value(at ref: CellRef) -> CellValue? { stored[ref] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { stored[ref] }
        func lastPopulatedCell() -> CellRef? {
            guard let column = stored.keys.map(\.column).max(),
                  let row = stored.keys.map(\.row).max() else { return nil }
            return CellRef(column: column, row: row)
        }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
        func values(in range: CellRange) -> [CellValue] { range.cells.compactMap { stored[$0] } }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
    }

    private func column(_ values: [Double], from row: Int = 1) -> Cells {
        var cells = Cells()
        for (offset, value) in values.enumerated() {
            cells.stored[CellRef(column: 1, row: row + offset)] = .number(value)
        }
        return cells
    }

    // MARK: - The shape the corpus actually writes

    /// `{=TRANSPOSE(A1:A3)}` entered across `C1:E1` — a column read out as a row.
    ///
    /// This is the formula the one array-formula workbook in the corpus writes,
    /// five times over, and the reason spilling exists at all.
    func testTransposeSpillsAColumnAcrossARow() throws {
        let assignment = try FormulaEvaluator.spill(
            .function("TRANSPOSE", [
                .cellRange(CellRange(from: CellRef("A1"), to: CellRef("A3"))),
            ]),
            over: CellRange(from: CellRef("C1"), to: CellRef("E1")),
            cells: column([10, 20, 30]), names: NamedRangeCollection())

        XCTAssertEqual(assignment[CellRef("C1")], .number(10))
        XCTAssertEqual(assignment[CellRef("D1")], .number(20))
        XCTAssertEqual(assignment[CellRef("E1")], .number(30))
        XCTAssertEqual(assignment.count, 3, "and nothing outside the span")
    }

    /// A scalar result fills the span, which is Excel's broadcast.
    func testAScalarFillsTheSpan() throws {
        let assignment = try FormulaEvaluator.spill(
            .function("SUM", [.cellRange(CellRange(from: CellRef("A1"), to: CellRef("A3")))]),
            over: CellRange(from: CellRef("C1"), to: CellRef("D2")),
            cells: column([1, 2, 3]), names: NamedRangeCollection())

        XCTAssertEqual(assignment.count, 4)
        for ref in ["C1", "D1", "C2", "D2"] {
            XCTAssertEqual(assignment[CellRef(ref)], .number(6), "\(ref)")
        }
    }

    /// A span wider than the result pads with `#N/A`, as Excel shows.
    func testASpanLargerThanTheResultPads() throws {
        let assignment = try FormulaEvaluator.spill(
            .function("TRANSPOSE", [
                .cellRange(CellRange(from: CellRef("A1"), to: CellRef("A2"))),
            ]),
            over: CellRange(from: CellRef("C1"), to: CellRef("E1")),
            cells: column([10, 20]), names: NamedRangeCollection())

        XCTAssertEqual(assignment[CellRef("C1")], .number(10))
        XCTAssertEqual(assignment[CellRef("D1")], .number(20))
        XCTAssertEqual(assignment[CellRef("E1")], .error(.na))
    }

    func testASpanSmallerThanTheResultTruncates() throws {
        let assignment = try FormulaEvaluator.spill(
            .function("TRANSPOSE", [
                .cellRange(CellRange(from: CellRef("A1"), to: CellRef("A3"))),
            ]),
            over: CellRange(from: CellRef("C1"), to: CellRef("D1")),
            cells: column([10, 20, 30]), names: NamedRangeCollection())

        XCTAssertEqual(assignment.count, 2)
        XCTAssertEqual(assignment[CellRef("C1")], .number(10))
        XCTAssertEqual(assignment[CellRef("D1")], .number(20))
    }

    /// A span of one cell is the ordinary case, and must stay ordinary.
    func testASingleCellSpanIsJustTheValue() throws {
        let assignment = try FormulaEvaluator.spill(
            .function("SUM", [.cellRange(CellRange(from: CellRef("A1"), to: CellRef("A2")))]),
            over: CellRange(from: CellRef("C1"), to: CellRef("C1")),
            cells: column([1, 2]), names: NamedRangeCollection())

        XCTAssertEqual(assignment, [CellRef("C1"): .number(3)])
    }

    /// An error fills the span rather than escaping it — every cell of a failed
    /// array formula shows the error in Excel.
    func testAnErrorFillsTheSpan() throws {
        let assignment = try FormulaEvaluator.spill(
            .function("NA", []),
            over: CellRange(from: CellRef("C1"), to: CellRef("D1")),
            cells: Cells(), names: NamedRangeCollection())

        XCTAssertEqual(assignment[CellRef("C1")], .error(.na))
        XCTAssertEqual(assignment[CellRef("D1")], .error(.na))
    }

    /// Blanks inside the result spill as blanks; only unreachable cells are `#N/A`.
    func testBlanksInsideTheResultStayBlank() throws {
        var cells = Cells()
        cells.stored[CellRef("A1")] = .number(10)
        // A2 empty
        cells.stored[CellRef("A3")] = .number(30)

        let assignment = try FormulaEvaluator.spill(
            .function("TRANSPOSE", [
                .cellRange(CellRange(from: CellRef("A1"), to: CellRef("A3"))),
            ]),
            over: CellRange(from: CellRef("C1"), to: CellRef("E1")),
            cells: cells, names: NamedRangeCollection())

        XCTAssertEqual(assignment[CellRef("C1")], .number(10))
        XCTAssertEqual(assignment[CellRef("D1")], .blank, "a hole in the data, not in the span")
        XCTAssertEqual(assignment[CellRef("E1")], .number(30))
    }

    /// The span is placed where it is asked for, not at the sheet's origin.
    func testTheSpanIsPlacedAtItsOwnOrigin() throws {
        let assignment = try FormulaEvaluator.spill(
            .function("TRANSPOSE", [
                .cellRange(CellRange(from: CellRef("A1"), to: CellRef("A2"))),
            ]),
            over: CellRange(from: CellRef("H5"), to: CellRef("I5")),
            cells: column([10, 20]), names: NamedRangeCollection())

        XCTAssertEqual(assignment[CellRef("H5")], .number(10))
        XCTAssertEqual(assignment[CellRef("I5")], .number(20))
    }
}
