import Foundation
import SwiftExcelCore
import SwiftXLSX
import XCTest
@testable import SwiftExcelFunctions

/// Semantics found by putting real workbooks to the checker, rather than by writing tests.
///
/// Each of these is a rule Excel has always had and this package did not, and each was
/// invisible to the suite because **nobody writes these formulas on purpose in a test** —
/// they write them in a spreadsheet. An empty cell compared to `""`, a date concatenated
/// into a criterion, a blank cell formatted as a date: the stuff of real files.
final class CorpusFoundSemanticsTests: XCTestCase {

    private struct Cells: CellValueProvider {
        let values: [String: CellValue]
        func value(at ref: CellRef) -> CellValue? { values[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { values[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("H9") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("H9") }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { values[$0.reference] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    /// `E20` is empty, `G20` holds "No", `D1` holds a date, `B1:B3` hold date serials.
    private let sheet = Cells(values: [
        "G20": .text("No"),
        "D1": .date(Date(timeIntervalSince1970: 1_700_000_000)),  // 14 November 2023
        "B1": .number(45_000), "B2": .number(45_100), "B3": .number(45_200),
        "C1": .number(10), "C2": .number(20), "C3": .number(30),
    ])

    private func evaluate(_ formula: String) throws -> CellValue {
        try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                      cells: sheet, names: NoNames())
    }

    // MARK: - An empty cell is both 0 and ""

    /// `A1=""` is TRUE for an empty `A1`, and so is `A1=0`.
    ///
    /// No single normalisation does both — mapping blank to `0` made `A1=""` a number
    /// against a text, and Excel's type ordering puts numbers before text, so it was FALSE.
    /// Which one a blank reads as depends on what it is being compared against.
    ///
    /// `IF(AND(E20="",G20="No"),1,2)` is how a spreadsheet asks "has this been filled in
    /// yet". It answered 2 where Excel cached 1.
    func testAnEmptyCellIsBothZeroAndEmptyText() throws {
        XCTAssertEqual(try evaluate("E20=\"\""), .bool(true))
        XCTAssertEqual(try evaluate("E20=0"), .bool(true))
        XCTAssertEqual(try evaluate("IF(AND(E20=\"\",G20=\"No\"),1,2)"), .number(1))

        // And the negations, which a half-filled template uses just as often.
        XCTAssertEqual(try evaluate("E20<>\"\""), .bool(false))
        XCTAssertEqual(try evaluate("G20=\"\""), .bool(false))
    }

    /// A blank still orders against text and numbers the way Excel orders them.
    func testABlankStillOrdersSensibly() throws {
        XCTAssertEqual(try evaluate("E20<1"), .bool(true))
        XCTAssertEqual(try evaluate("E20>-1"), .bool(true))
    }

    // MARK: - A date is a number

    /// `"x" & a_date` is the **serial**, because that is what a date is in Excel.
    ///
    /// An ISO string here made `">=" & I4` a criterion no date could ever match, so
    /// `SUMIFS(amounts, dates, ">="&I$4, …)` summed nothing while looking entirely right.
    func testADateConcatenatesAsItsSerial() throws {
        guard case .text(let joined) = try evaluate("\">=\"&D1") else {
            return XCTFail("expected text")
        }
        XCTAssertEqual(joined, ">=45244")
        XCTAssertFalse(joined.contains("-"), "an ISO date is not what Excel writes here")
    }

    /// And the criterion built that way selects the dates it should.
    func testACriterionBuiltFromADateSelects() throws {
        XCTAssertEqual(try evaluate("SUMIFS(C1:C3,B1:B3,\">=45100\")"), .number(50))
        XCTAssertEqual(try evaluate("SUMIFS(C1:C3,B1:B3,\">=\"&B2,B1:B3,\"<=\"&B3)"), .number(50))
        XCTAssertEqual(try evaluate("COUNTIFS(B1:B3,\"<\"&B3)"), .number(2))
    }

    // MARK: - Serial zero is a date Excel will show

    /// `TEXT(0, "yyyy-mm-dd")` is `"1900-01-00"` — a day that does not exist.
    ///
    /// It is what an empty cell formatted as a date renders as, which a template full of
    /// unfilled date cells produces by the hundred. Refusing it sent the call down the
    /// numeric path, where the answer was `"0"`.
    func testSerialZeroFormatsAsExcelShowsIt() throws {
        XCTAssertEqual(try evaluate("TEXT(0,\"yyyy-mm-dd\")"), .text("1900-01-00"))
        XCTAssertEqual(try evaluate("TEXT(0,\"yyyy-mm-ddThh:mm:ss\")"),
                       .text("1900-01-00T00:00:00"))
        // Serial 1 is the first day Excel has, and is unaffected.
        XCTAssertEqual(try evaluate("TEXT(1,\"yyyy-mm-dd\")"), .text("1900-01-01"))
        // A negative serial is no date at all.
        XCTAssertEqual(try evaluate("TEXT(-1,\"yyyy-mm-dd\")"), .text("-1"))
    }

    // MARK: - IPMT and PPMT, which had swapped places

    /// Microsoft's published examples, and the identity that ties them together.
    ///
    /// A positive present value is money owed, so both parts of the payment are negative.
    /// The sign was inverted here, and the two errors cancelled in `IPMT + PPMT = PMT` —
    /// which is why the identity test beside them passed throughout.
    func testTheTwoHalvesOfAPaymentHaveExcelsSigns() throws {
        XCTAssertEqual(try number("IPMT(0.1/12,1,36,8000)"), -66.67, accuracy: 0.01)
        XCTAssertEqual(try number("PPMT(0.1/12,1,24,2000)"), -75.62, accuracy: 0.01)

        // Later in a mortgage the principal overtakes the interest; early on it does not.
        // Getting them the wrong way round is invisible in the total and obvious here.
        let earlyInterest = try number("IPMT(0.05/12,18,360,500000)")
        let earlyPrincipal = try number("PPMT(0.05/12,18,360,500000)")
        XCTAssertLessThan(earlyInterest, earlyPrincipal,
                          "eighteen months into a thirty-year loan, interest is the larger part")
        XCTAssertEqual(earlyInterest + earlyPrincipal,
                       try number("PMT(0.05/12,360,500000)"), accuracy: 1e-9)
    }

    private func number(_ formula: String) throws -> Double {
        guard case .number(let value) = try evaluate(formula) else {
            XCTFail("\(formula) did not produce a number"); return .nan
        }
        return value
    }
}
