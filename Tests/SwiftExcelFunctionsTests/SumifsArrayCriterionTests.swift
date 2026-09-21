import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// `SUMIFS` given an **array criterion** answers once per element.
///
/// ## The idiom, and why it is not exotic
///
/// `SUMPRODUCT(SUMIFS(range, keys, "x", months, q1_months))` is how a spreadsheet sums over
/// several key values without writing the addition out. `q1_months` is a three-cell name, so
/// Excel runs the `SUMIFS` three times and hands `SUMPRODUCT` a three-element array to total.
///
/// **81 corpus cells in `Traffic and stuff.xlsx` are exactly this shape**, with the names
/// resolving to `Definitions!$E$62:$E$64` and `Definitions!$E$71:$E$73`. We answered `#VALUE!`
/// for all of them, because a criterion that was not a single value had no criteria string and
/// the call refused.
///
/// ```
///            A           B        C
///   1     division    month    bounces
///   2        West        1        100
///   3        West        2        200
///   4        East        1         40
///   5        West        3        300
///   6        East        2         10
/// ```
final class SumifsArrayCriterionTests: XCTestCase {

    private struct Book: CellValueProvider {
        static let cells: [String: CellValue] = [
            "A2": .text("West"), "B2": .number(1), "C2": .number(100),
            "A3": .text("West"), "B3": .number(2), "C3": .number(200),
            "A4": .text("East"), "B4": .number(1), "C4": .number(40),
            "A5": .text("West"), "B5": .number(3), "C5": .number(300),
            "A6": .text("East"), "B6": .number(2), "C6": .number(10),
            // The three-cell name, as its own little range.
            "E1": .number(1), "E2": .number(2), "E3": .number(3),
        ]
        func value(at ref: CellRef) -> CellValue? { Self.cells[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { Self.cells[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("E6") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("E6") }
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

    /// **The corpus shape.** Three months summed for one division, totalled by `SUMPRODUCT`.
    func testSumproductOverAnArrayCriterion() throws {
        XCTAssertEqual(
            try evaluate("SUMPRODUCT(SUMIFS(C2:C6,A2:A6,\"West\",B2:B6,E1:E3))"),
            .number(600), "100 + 200 + 300")
    }

    /// The array is the criterion's shape, one sum per element and in its order.
    func testTheResultIsOnePerCriterionElement() throws {
        guard case .array(let matrix) =
                try evaluate("SUMIFS(C2:C6,A2:A6,\"East\",B2:B6,E1:E3)") else {
            return XCTFail("expected an array, one element per month")
        }
        XCTAssertEqual(matrix.elements, [.number(40), .number(10), .number(0)],
                       "month 3 has no East row, which is a zero rather than a gap")
    }

    /// A one-element criterion range is still a single answer — nothing becomes an array
    /// merely for having been written as a reference.
    func testAOneCellCriterionStaysScalar() throws {
        XCTAssertEqual(try evaluate("SUMIFS(C2:C6,A2:A6,\"West\",B2:B6,E1:E1)"), .number(100))
    }

    /// Ordinary scalar criteria are untouched.
    func testScalarCriteriaAreUnchanged() throws {
        XCTAssertEqual(try evaluate("SUMIFS(C2:C6,A2:A6,\"West\",B2:B6,2)"), .number(200))
        XCTAssertEqual(try evaluate("SUMIFS(C2:C6,A2:A6,\"West\")"), .number(600))
    }

    /// `SUMIF` takes the same treatment — same criterion, different argument order.
    func testSumifAlsoAnswersPerElement() throws {
        XCTAssertEqual(try evaluate("SUMPRODUCT(SUMIF(B2:B6,E1:E3,C2:C6))"), .number(650),
                       "every division: 140 + 210 + 300")
    }

    /// **Two array criteria are refused**, not guessed at.
    ///
    /// Excel broadcasts them, and which way depends on each one's orientation — a column
    /// against a row gives a rectangle. No corpus cell does this, so there is nothing to check
    /// an implementation against, and a wrong rectangle is a wrong number rather than an error.
    func testTwoArrayCriteriaRefuse() throws {
        XCTAssertEqual(try evaluate("SUMIFS(C2:C6,A2:A6,E1:E3,B2:B6,E1:E3)"), .error(.value))
    }
}
