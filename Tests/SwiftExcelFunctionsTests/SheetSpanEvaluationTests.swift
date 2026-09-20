import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// Evaluating a 3-D reference — `SUM('Q1:Q4'!B7)`.
///
/// **A corpus run found 9,958 cells of one workbook depending on this.** Every one is a sum
/// across a span of sheets, `SUM('8887997613:8887997618'!DL62)` repeated down a column, and
/// this package answered 28 where Excel answered 47.
///
/// The shortfall was silent, which is what made it survive: the terms that named a *single*
/// sheet resolved perfectly, so the total was plausible and merely wrong. Nothing errored,
/// nothing refused, and the only way to see it was to compare against Excel's own cached
/// value on a workbook nobody wrote for us.
final class SheetSpanEvaluationTests: XCTestCase {

    /// A workbook of named sheets, each holding one value at `B7`.
    private struct Book: CellValueProvider {
        let order: [String]
        let values: [String: Double]

        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? {
            guard ref.reference == "B7", let value = values[sheet] else { return nil }
            return .number(value)
        }
        func lastPopulatedCell() -> CellRef? { CellRef("B7") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("B7") }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet sheet: String) -> [CellValue] {
            range.cells.map { value(at: $0, inSheet: sheet) ?? .blank }
        }
        func sheetNames() -> [String] { order }
    }

    private static let book = Book(
        order: ["Cover", "Q1", "Q2", "Q3", "Q4", "Notes"],
        values: ["Cover": 100, "Q1": 1, "Q2": 2, "Q3": 4, "Q4": 8, "Notes": 200])

    private func evaluate(_ formula: String) throws -> CellValue {
        try FormulaEvaluator.evaluate(try FormulaParser.parse(formula), cells: Self.book,
                                      names: NoNames())
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    /// The shape the corpus is full of.
    func testASumAcrossASpanOfSheetsAddsEveryOne() throws {
        // 1 + 2 + 4 + 8, with `Cover` and `Notes` outside the span and left out.
        XCTAssertEqual(try evaluate("SUM('Q1:Q4'!B7)"), .number(15))
    }

    /// The ends are included, and nothing beyond them is.
    func testTheEndsAreIncludedAndNothingElseIs() throws {
        XCTAssertEqual(try evaluate("SUM('Q1:Q2'!B7)"), .number(3))
        XCTAssertEqual(try evaluate("SUM('Q2:Q3'!B7)"), .number(6))
        XCTAssertEqual(try evaluate("SUM('Cover:Q1'!B7)"), .number(101),
                       "a span may start at the first sheet")
    }

    /// A span of one sheet is that sheet, and an ordinary reference still works.
    func testADegenerateSpanAndAPlainReference() throws {
        XCTAssertEqual(try evaluate("SUM('Q3:Q3'!B7)"), .number(4))
        XCTAssertEqual(try evaluate("SUM('Q3'!B7)"), .number(4),
                       "no colon, so one sheet — the path that already worked")
    }

    /// Other aggregates see the same values, since the span produces an array like any other.
    func testTheSpanIsAnArrayLikeAnyOther() throws {
        XCTAssertEqual(try evaluate("COUNT('Q1:Q4'!B7)"), .number(4))
        XCTAssertEqual(try evaluate("MAX('Q1:Q4'!B7)"), .number(8))
        XCTAssertEqual(try evaluate("MIN('Q1:Q4'!B7)"), .number(1))
    }

    /// An end that names no sheet reads as empty rather than as one end of the span.
    ///
    /// **Silently dropping to one end is the bug this replaces**, so it must not come back
    /// as the error path. `SUM` over nothing is 0, which is what an empty range gives.
    func testAnEndThatNamesNoSheetReadsAsEmpty() throws {
        XCTAssertEqual(try evaluate("SUM('Q1:Nope'!B7)"), .number(0))
        XCTAssertEqual(try evaluate("SUM('Nope:Q4'!B7)"), .number(0))
    }
}
