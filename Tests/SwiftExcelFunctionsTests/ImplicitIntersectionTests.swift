import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// **Implicit intersection** — a range used where a single value is expected.
///
/// ## The rule
///
/// In a formula that was *not* array-entered, Excel intersects a multi-cell range with the
/// formula's own row (for a range spanning rows) or column, and uses that one cell. It is the
/// pre-dynamic-array behaviour modern Excel writes as `@`.
///
/// ```
/// I10:  IF(AND($A10:A44478 > start, $A10:A44478 < end), 1, 0)     ← plain <f>: means A10
/// AF14: INDEX(…, MATCH(…, IF(template_year = Report_Year, …), 0)) ← <f t="array">: means the column
/// ```
///
/// Both are in the corpus, one row apart in spirit and entirely different in meaning. The
/// first is 11 cells that read `0` where Excel has `1`; the second is 64 cells that need the
/// array reading and got it in the round before this one.
///
/// ## Where it must not fire
///
/// **Inside a context that expects an array.** `SUMPRODUCT((A1:A5=x)*(B1:B5))` is normally
/// entered and still evaluates as arrays, which is the entire reason the idiom exists. The
/// gate is therefore two conditions, not one: the formula is not array-entered *and* nothing
/// enclosing it has asked for arrays.
///
/// ```
///        A     B
///   1    1    10
///   2    2    20
///   3    3    30
///   4    4    40
///   5    5    50
/// ```
final class ImplicitIntersectionTests: XCTestCase {

    private struct Book: CellValueProvider {
        static let cells: [String: CellValue] = [
            "A1": .number(1), "B1": .number(10),
            "A2": .number(2), "B2": .number(20),
            "A3": .number(3), "B3": .number(30),
            "A4": .number(4), "B4": .number(40),
            "A5": .number(5), "B5": .number(50),
        ]
        /// Cells whose formula was array-entered.
        let arrayEntered: Set<String>
        init(arrayEntered: Set<String> = []) { self.arrayEntered = arrayEntered }
        func value(at ref: CellRef) -> CellValue? { Self.cells[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { Self.cells[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("B5") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("B5") }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { Self.cells[$0.reference] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
        func isArrayEntered(at ref: CellRef, inSheet sheet: String) -> Bool {
            arrayEntered.contains(ref.reference)
        }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    /// Evaluates as if written in `at`, which is what decides the intersection.
    private func evaluate(_ formula: String, at cell: String,
                          arrayEntered: Set<String> = []) throws -> CellValue {
        try FormulaEvaluator.evaluate(
            try FormulaParser.parse(formula),
            cells: Book(arrayEntered: arrayEntered), names: NoNames(),
            at: CellAddress(sheet: "Sheet1", ref: cell), inSheet: "Sheet1")
    }

    // MARK: - The measured shape

    /// **The corpus cell.** Written in row 3, `A1:A5 > 2` means `A3 > 2`, which is true.
    func testAComparisonIntersectsWithTheFormulasRow() throws {
        XCTAssertEqual(try evaluate("IF(AND(A1:A5>2,A1:A5<5),1,0)", at: "D3"), .number(1),
                       "row 3: 3 > 2 and 3 < 5")
        XCTAssertEqual(try evaluate("IF(AND(A1:A5>2,A1:A5<5),1,0)", at: "D1"), .number(0),
                       "row 1: 1 is not > 2")
    }

    /// Arithmetic intersects too — it is the operator that expects one value, not the function.
    func testArithmeticIntersects() throws {
        XCTAssertEqual(try evaluate("A1:A5*10", at: "D4"), .number(40))
        XCTAssertEqual(try evaluate("A1:A5&\"x\"", at: "D2"), .text("2x"))
    }

    /// A range spanning **columns** intersects against the formula's column instead.
    func testARowRangeIntersectsWithTheFormulasColumn() throws {
        XCTAssertEqual(try evaluate("A1:B1*2", at: "B7"), .number(20), "column B of row 1")
    }

    /// **No intersection is `#VALUE!`**, which is Excel's answer and not a silent zero.
    func testNoIntersectionIsAValueError() throws {
        XCTAssertEqual(try evaluate("A1:A5*10", at: "D9"), .error(.value),
                       "row 9 is outside A1:A5")
    }

    // MARK: - Where it must not fire

    /// **An array-entered formula means the whole range**, and 64 corpus cells depend on it.
    func testAnArrayEnteredFormulaDoesNotIntersect() throws {
        guard case .array(let matrix) =
                try evaluate("A1:A5>2", at: "D3", arrayEntered: ["D3"]) else {
            return XCTFail("array-entered: the comparison stays a column")
        }
        XCTAssertEqual(matrix.elements.count, 5)
    }

    /// **`SUMPRODUCT` asks for arrays**, normally entered or not — the idiom exists for that.
    func testSumproductStillSeesArrays() throws {
        XCTAssertEqual(try evaluate("SUMPRODUCT((A1:A5>2)*B1:B5)", at: "D3"), .number(120),
                       "30 + 40 + 50, not row 3 alone")
        XCTAssertEqual(try evaluate("SUMPRODUCT(--(A1:A5>2))", at: "D3"), .number(3))
    }

    /// A range passed **as an argument** is not an operand, and never intersected.
    func testAPlainRangeArgumentIsUntouched() throws {
        XCTAssertEqual(try evaluate("SUM(A1:A5)", at: "D3"), .number(15))
        XCTAssertEqual(try evaluate("COUNT(A1:A5)", at: "D9"), .number(5),
                       "even from a row the range does not reach")
    }

    /// With no calling cell there is nothing to intersect against, so the array survives —
    /// which is what keeps every existing test that evaluates without an address working.
    func testWithoutACallingCellNothingIntersects() throws {
        let value = try FormulaEvaluator.evaluate(
            try FormulaParser.parse("A1:A5>2"), cells: Book(), names: NoNames(),
            inSheet: "Sheet1")
        guard case .array = value else { return XCTFail("expected an array") }
    }

    /// A one-cell range is already a single value and is unaffected either way.
    func testAOneCellRangeIsUnaffected() throws {
        XCTAssertEqual(try evaluate("A2:A2*10", at: "D9"), .number(20))
    }
}
