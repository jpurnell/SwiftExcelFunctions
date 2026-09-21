import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// `IF` given an **array condition** answers once per element.
///
/// ## The idiom
///
/// `MATCH(quarter, IF(years = wanted, quarters, 0), 0)` is how a spreadsheet looks something up
/// on two keys without a helper column: the `IF` blanks out every row of the wrong year, and
/// the `MATCH` then searches what is left.
///
/// **64 corpus cells across three `Goals Template` workbooks are this shape:**
///
/// ```
/// INDEX(BAU_3_Bullet_1, MATCH(template_quarter,
///       IF(template_year = Report_Year, Report_Quarter, 0), 0), 0)
/// ```
///
/// `Report_Year` is `Input!$E:$E` and `Report_Quarter` is `Input!$D:$D`, so the condition is a
/// column of comparisons and the true branch a column of quarters. We answered `#VALUE!` for
/// every one, because the condition was not a single truth value and `IF` refused it.
///
/// Excel answers `#N/A` for 63 of them — the year genuinely is not in the sheet — and a real
/// value for the 64th. Both come out of the same rule, which is why `#N/A` is not a shortcut
/// worth taking: the one that finds something has to find it.
///
/// ```
///        A         B
///   1   2015       1
///   2   2014       2
///   3   2015       3
/// ```
final class IfArrayConditionTests: XCTestCase {

    private struct Book: CellValueProvider {
        static let cells: [String: CellValue] = [
            "A1": .number(2015), "B1": .number(1), "C1": .text("first"),
            "A2": .number(2014), "B2": .number(2), "C2": .text("second"),
            "A3": .number(2015), "B3": .number(3), "C3": .text("third"),
        ]
        func value(at ref: CellRef) -> CellValue? { Self.cells[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { Self.cells[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("C3") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("C3") }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { Self.cells[$0.reference] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func evaluate(_ formula: String) throws -> CellValue {
        try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                      cells: Book(), names: NoNames(), inSheet: "Sheet1")
    }

    /// The condition is an array, so the answer is one per element.
    func testAnArrayConditionGivesAnArray() throws {
        guard case .array(let matrix) = try evaluate("IF(A1:A3=2015,B1:B3,0)") else {
            return XCTFail("expected an array, one element per row")
        }
        XCTAssertEqual(matrix.elements, [.number(1), .number(0), .number(3)],
                       "row 2 is the wrong year, so its branch is the false one")
    }

    /// **The corpus shape**, which finds its row.
    func testTheCorpusShapeFindsItsRow() throws {
        XCTAssertEqual(
            try evaluate("INDEX(C1:C3,MATCH(3,IF(A1:A3=2015,B1:B3,0),0),0)"), .text("third"))
    }

    /// And where the pair is not in the sheet, the answer is `#N/A` — not `#VALUE!`.
    ///
    /// 63 of the 64 corpus cells are this: the template asks for a year the input does not
    /// carry. Excel says "not found"; we said "malformed", which is a different statement.
    func testAPairThatIsNotThereIsNotFoundRatherThanMalformed() throws {
        XCTAssertEqual(try evaluate("MATCH(2,IF(A1:A3=2015,B1:B3,0),0)"), .error(.na))
    }

    /// Both branches may be arrays, and they are read at the same position.
    func testBothBranchesMayBeArrays() throws {
        guard case .array(let matrix) = try evaluate("IF(A1:A3=2015,B1:B3,C1:C3)") else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(matrix.elements, [.number(1), .text("second"), .number(3)])
    }

    /// A missing third argument is `FALSE`, element by element, as it is for a scalar call.
    func testTheOmittedBranchIsFalse() throws {
        guard case .array(let matrix) = try evaluate("IF(A1:A3=2015,B1:B3)") else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(matrix.elements, [.number(1), .bool(false), .number(3)])
    }

    /// **A branch shorter than the condition runs out**, and Excel says so with `#N/A` rather
    /// than reusing a value or padding with a blank.
    func testABranchShorterThanTheConditionRunsOut() throws {
        guard case .array(let matrix) = try evaluate("IF(A1:A3=2015,B1:B2,0)") else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(matrix.elements, [.number(1), .number(0), .error(.na)],
                       "the third row has no true branch to take")
    }

    /// A scalar condition is untouched, and neither branch is evaluated needlessly — the
    /// laziness that makes `IF(A1=0,"",1/A1)` safe is not traded away for this.
    func testAScalarConditionStillTakesOneBranch() throws {
        XCTAssertEqual(try evaluate("IF(A1=2015,B1,1/0)"), .number(1),
                       "the false branch divides by zero and must not be evaluated")
        XCTAssertEqual(try evaluate("IF(A2=2015,1/0,B2)"), .number(2))
    }
}
