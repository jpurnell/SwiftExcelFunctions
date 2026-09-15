import Foundation
import SwiftExcelCore
import SwiftXLSX
import XCTest
@testable import SwiftExcelFunctions

/// Excel's operators applied to rectangles.
///
/// **Found by the workbook checker, not by a test.** Its first corpus run reported 407 cells
/// in one workbook as stale, all of them this shape:
///
/// ```
/// SUMPRODUCT(--(LEN(steps)>1), --(area=$C4), --(dates>=S$3), --(dates<=EOMONTH(S$3,0)))
/// ```
///
/// Every comparison collapsed to a single `FALSE`, every `--FALSE` to `0`, and the whole
/// formula answered zero while looking entirely healthy. Excel's cached answers were 1, 2
/// and 3. Nothing in 1,400 unit tests had asked what `A1:A10 = "x"` should be, because
/// nobody writes that formula on purpose in a test — they write it in a spreadsheet.
final class ArrayBroadcastTests: XCTestCase {

    private struct Cells: CellValueProvider {
        let values: [String: CellValue]
        func value(at ref: CellRef) -> CellValue? { values[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { values[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("G3") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("G3") }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { values[$0.reference] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    /// Three columns and one row, because the shapes are what is being tested.
    ///
    /// | Range | Holds |
    /// |---|---|
    /// | `A1:A3` | 10, 20, 30 |
    /// | `B1:B3` | 1, 2, 3 |
    /// | `C1:C3` | "x", "y", "x" |
    /// | `D1:F1` | 1, 2, 3 — a *row*, for the outer product |
    /// | `G1:G3` | 1, 0, 2 — a divisor with a zero in it |
    ///
    /// Written as ranges rather than as `{1,2,3}` literals because the parser does not
    /// read an array literal — `FormulaLexer` refuses the brace. A separate gap, recorded
    /// rather than worked around, and these tests want cells anyway: a range is what a
    /// spreadsheet writes.
    private let sheet = Cells(values: [
        "A1": .number(10), "A2": .number(20), "A3": .number(30),
        "B1": .number(1), "B2": .number(2), "B3": .number(3),
        "C1": .text("x"), "C2": .text("y"), "C3": .text("x"),
        "D1": .number(1), "E1": .number(2), "F1": .number(3),
        "G1": .number(1), "G2": .number(0), "G3": .number(2),
    ])

    private func evaluate(_ formula: String) throws -> CellValue {
        try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                      cells: sheet, names: NoNames())
    }

    private func numbers(_ formula: String) throws -> [Double] {
        guard case .array(let matrix) = try evaluate(formula) else {
            XCTFail("\(formula) did not produce an array"); return []
        }
        return matrix.elements.map {
            if case .number(let value) = $0 { return value }
            if case .bool(let flag) = $0 { return flag ? 1 : 0 }
            return .nan
        }
    }

    // MARK: - Arithmetic

    /// A rectangle against a single value is a rectangle.
    func testAScalarBroadcastsAcrossARange() throws {
        XCTAssertEqual(try numbers("A1:A3*2"), [20, 40, 60])
        XCTAssertEqual(try numbers("A1:A3+1"), [11, 21, 31])
        XCTAssertEqual(try numbers("A1:A3/10"), [1, 2, 3])
        XCTAssertEqual(try numbers("2^B1:B3"), [2, 4, 8])
    }

    /// Two rectangles of the same shape pair off element by element.
    func testTwoRangesPairOff() throws {
        XCTAssertEqual(try numbers("A1:A3*B1:B3"), [10, 40, 90])
        XCTAssertEqual(try numbers("A1:A3-B1:B3"), [9, 18, 27])
    }

    /// **A row against a column is a matrix**, which is Excel's answer and surprises
    /// everyone once.
    func testARowAgainstAColumnIsAMatrix() throws {
        guard case .array(let matrix) = try evaluate("D1:F1*B1:B3") else {
            return XCTFail("expected a matrix")
        }
        XCTAssertEqual(matrix.rows, 3)
        XCTAssertEqual(matrix.columns, 3)
        XCTAssertEqual(matrix.elements, [.number(1), .number(2), .number(3),
                                         .number(2), .number(4), .number(6),
                                         .number(3), .number(6), .number(9)])
    }

    /// Where one side does not reach, the answer is `#N/A` rather than a guess.
    ///
    /// Not clipped to the shorter side and not repeated from its edge: Excel refuses to
    /// decide what was meant, and either alternative would produce a plausible number from
    /// a mistake.
    func testAShortfallIsNotAvailableRatherThanAGuess() throws {
        guard case .array(let matrix) = try evaluate("A1:A3+B1:B2") else {
            return XCTFail("expected a column")
        }
        XCTAssertEqual(matrix.elements, [.number(11), .number(22), .error(.na)])
    }

    // MARK: - Comparison

    /// A comparison against a rectangle is a rectangle of answers.
    ///
    /// The one that was wrong. `C1:C3="x"` was a single `FALSE`; it is three answers.
    func testAComparisonBroadcasts() throws {
        XCTAssertEqual(try numbers("C1:C3=\"x\""), [1, 0, 1])
        XCTAssertEqual(try numbers("A1:A3>=20"), [0, 1, 1])
        XCTAssertEqual(try numbers("A1:A3<>20"), [1, 0, 1])
    }

    /// `--` is how a spreadsheet turns those answers into numbers.
    func testDoubleNegationTurnsThemIntoOnesAndZeros() throws {
        XCTAssertEqual(try numbers("--(C1:C3=\"x\")"), [1, 0, 1])
        XCTAssertEqual(try numbers("-A1:A3"), [-10, -20, -30])
    }

    /// The idiom, end to end, which is what the corpus actually writes.
    ///
    /// Two conditions and a value column: the classic conditional sum, written before
    /// `SUMIFS` existed and still written by anyone who learned it then.
    func testTheSumproductIdiom() throws {
        XCTAssertEqual(try evaluate("SUMPRODUCT(--(C1:C3=\"x\"),A1:A3)"), .number(40))
        XCTAssertEqual(
            try evaluate("SUMPRODUCT(--(C1:C3=\"x\"),--(A1:A3>10),A1:A3)"), .number(30))
        XCTAssertEqual(try evaluate("SUMPRODUCT(--(C1:C3=\"z\"),A1:A3)"), .number(0))
    }

    // MARK: - Text

    /// Concatenation broadcasts too, which is how a column of labels is built.
    func testConcatenationBroadcasts() throws {
        guard case .array(let matrix) = try evaluate("C1:C3&\"!\"") else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(matrix.elements, [.text("x!"), .text("y!"), .text("x!")])
    }

    // MARK: - What did not change

    /// Two single values are still two single values.
    ///
    /// The whole risk of this change is that it turns scalar arithmetic into rectangles of
    /// one element, which would be a different type flowing through every formula in the
    /// package.
    func testScalarArithmeticIsUntouched() throws {
        XCTAssertEqual(try evaluate("2*3"), .number(6))
        XCTAssertEqual(try evaluate("A1+B1"), .number(11))
        XCTAssertEqual(try evaluate("A1>B1"), .bool(true))
        XCTAssertEqual(try evaluate("C1&C2"), .text("xy"))
    }

    /// An error in one element is that element's answer, not the rectangle's.
    func testAnErrorStaysInItsOwnCell() throws {
        guard case .array(let matrix) = try evaluate("A1:A3/G1:G3") else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(matrix.elements, [.number(10), .error(.div0), .number(15)])
    }
}
