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

/// `SUMPRODUCT` evaluates its arguments in array context, and `SUM` does not.
///
/// **Measured in round fifteen, and it refuted the prediction that produced it.** The corpus
/// shape is `SUMPRODUCT((MOD(COLUMN(C38:GT38),2)=$A$1) * … )`, counting alternating columns,
/// and it answered 18 against Excel's 12. The obvious reading was that `COLUMN` over a range
/// should return an array. Excel says otherwise:
///
/// | | Excel |
/// |---|---:|
/// | `SUM(COLUMN($H:$M))` | 8 |
/// | `SUMPRODUCT((MOD(COLUMN($H:$M),2)=0)*1)` | 3 |
///
/// `COLUMN` returning the leftmost column is **correct**. What differs is the caller:
/// `SUMPRODUCT` forces array evaluation of its arguments and `SUM` does not. Acting on the
/// prediction would have broken the case that already agreed, and only asking `COLUMN` alone
/// alongside the whole idiom caught it.
final class ArrayContextTests: XCTestCase {

    /// Six cells across columns H to M, so the column numbers are 8 through 13.
    private struct Row: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { .text("P") }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { .text("P") }
        func lastPopulatedCell() -> CellRef? { CellRef("M2") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("M2") }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { _ in .text("P") }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func evaluate(_ formula: String) throws -> CellValue {
        try FormulaEvaluator.evaluate(try FormulaParser.parse(formula), cells: Row(),
                                      names: NoNames())
    }

    /// Outside an array context, `COLUMN` over a range is its leftmost column.
    func testSUMLeavesCOLUMNAsAScalar() throws {
        XCTAssertEqual(try evaluate("SUM(COLUMN($H2:$M2))"), .number(8))
        XCTAssertEqual(try evaluate("SUM(MOD(COLUMN($H2:$M2), 2))"), .number(0))
    }

    /// Inside `SUMPRODUCT`, it is the whole array.
    func testSUMPRODUCTEvaluatesCOLUMNAsAnArray() throws {
        // Columns 8…13: three of them even.
        XCTAssertEqual(try evaluate("SUMPRODUCT((MOD(COLUMN($H2:$M2), 2) = 0) * 1)"),
                       .number(3))
        // And the array reaches through nesting — the corpus's own shape wraps COLUMN in
        // MOD, in a comparison, in a multiplication.
        XCTAssertEqual(try evaluate("SUMPRODUCT((MOD(COLUMN($H2:$M2), 2) = 1) * 1)"),
                       .number(3))
    }

    /// `ROW` is the same function turned ninety degrees, and must follow.
    func testROWFollowsTheSameRule() throws {
        XCTAssertEqual(try evaluate("SUM(ROW($H2:$H5))"), .number(2))
        XCTAssertEqual(try evaluate("SUMPRODUCT((ROW($H2:$H5) > 0) * 1)"), .number(4))
    }
}

/// `SUMIF` stretches a short `sum_range`; `SUMIFS` refuses one.
///
/// **Measured in round fifteen, and it settled a question that had been open all session.**
/// Given three keys and a one-cell sum range, Excel answers `4` for `SUMIF` — extending the
/// range to the criteria range's shape and taking the two matching rows — and `#VALUE!` for
/// `SUMIFS`. This package answered the same number to both, so the two were very nearly
/// implemented as one function with its arguments moved. They are not.
///
/// Asserted through the evaluator because stretching needs the **reference**: an
/// `ExcelFunction` receives evaluated values, and by then a one-cell sum range is a single
/// number with no address.
final class SumRangeStretchTests: XCTestCase {

    /// `H2:J2` are the keys `x`, `y`, `x`; `K2:M2` are 1, 2, 3.
    private struct Sheet: CellValueProvider {
        private static let cells: [String: CellValue] = [
            "H2": .text("x"), "I2": .text("y"), "J2": .text("x"),
            "K2": .number(1), "L2": .number(2), "M2": .number(3),
        ]
        func value(at ref: CellRef) -> CellValue? { Self.cells[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { Self.cells[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("M2") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("M2") }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { Self.cells[$0.reference] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func evaluate(_ formula: String) throws -> CellValue {
        try FormulaEvaluator.evaluate(try FormulaParser.parse(formula), cells: Sheet(),
                                      names: NoNames())
    }

    func testSUMIFStretchesAShortSumRange() throws {
        XCTAssertEqual(try evaluate("SUMIF(H2:J2, \"x\", K2)"), .number(4),
                       "K2 grows to K2:M2, so the rows keyed x are 1 and 3")
        XCTAssertEqual(try evaluate("SUMIF(H2:J2, \"x\", K2:M2)"), .number(4),
                       "control: written in full, the same answer")
    }

    func testSUMIFSRefusesAShortSumRange() throws {
        XCTAssertEqual(try evaluate("SUMIFS(K2, H2:J2, \"x\")"), .error(.value),
                       "SUMIFS requires the shapes to match, and says so")
    }
}
