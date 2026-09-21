import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// A **blank lookup value** finds nothing in an exact-match `VLOOKUP`.
///
/// ## Measured
///
/// Three corpus cells across the `Goals Template` workbooks read
///
/// ```
/// VLOOKUP(template_person, Name_Lookup, 2, 0) & " " & VLOOKUP(template_person, Name_Lookup, 3, 0)
/// ```
///
/// where `template_person` is `Template!$M$1` — an **empty cell**, the template's unfilled
/// name field. Excel answers `#N/A`. We answered a lone space: both lookups matched the blank
/// sitting in the table's own first column, returned empty, and `&` joined them into something
/// that looks like a name badge with nobody on it.
///
/// That is the same defect `MATCH` had, measured in round fifteen at a cost of 82 cells. The
/// rule is applied here **only to exact match**, which is what these cells use and what has
/// been measured. Approximate match is left alone deliberately — nothing in the corpus
/// exercises it, and it already answers `#N/A` for its own reason.
final class LookupBlankValueTests: XCTestCase {

    private struct Book: CellValueProvider {
        static let cells: [String: CellValue] = [
            // `C2` is blank, exactly as the corpus table's first row is.
            "D2": .text("nobody"), "E2": .text("here"),
            "C3": .text("Viola"), "D3": .text("Viola"), "E3": .text("Davis"),
            "C4": .text("Courtney"), "D4": .text("Courtney"), "E4": .text("Vance"),
            // A sorted numeric key, for the approximate case.
            "G1": .number(0), "H1": .text("zero"),
            "G2": .number(10), "H2": .text("ten"),
        ]
        func value(at ref: CellRef) -> CellValue? { Self.cells[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { Self.cells[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("H4") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("H4") }
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

    /// **The corpus cell.** `M1` is empty, so both lookups are `#N/A` and so is the join.
    func testTheUnfilledTemplateFieldIsNotFound() throws {
        XCTAssertEqual(try evaluate("VLOOKUP(M1,C2:E4,2,0)"), .error(.na))
        XCTAssertEqual(try evaluate("VLOOKUP(M1,C2:E4,2,0)&\" \"&VLOOKUP(M1,C2:E4,3,0)"),
                       .error(.na), "and the concatenation carries the error, not a space")
    }

    /// It must not match the blank the table itself carries in `C2`.
    func testItDoesNotMatchABlankInsideTheTable() throws {
        XCTAssertNotEqual(try evaluate("VLOOKUP(M1,C2:E4,2,0)"), .text("nobody"))
    }

    /// A real key still resolves, which is the whole point of not refusing more broadly.
    func testARealKeyStillResolves() throws {
        XCTAssertEqual(try evaluate("VLOOKUP(\"Viola\",C2:E4,3,0)"), .text("Davis"))
    }

    /// `HLOOKUP` has the same shape and the same answer.
    func testHlookupAgrees() throws {
        XCTAssertEqual(try evaluate("HLOOKUP(M1,C2:E2,1,0)"), .error(.na))
    }

    /// **Approximate match is not changed by this**, which is what this pins.
    ///
    /// It already answered `#N/A`: a blank is not comparable to a number here, so no key is
    /// ever taken as the largest one not exceeding it. This test first asserted `"zero"` — a
    /// guess that Excel reads a blank as `0` against a sorted numeric key — and that guess was
    /// never measured against Excel *or* against this code. No corpus cell exercises the
    /// combination, so the behaviour is recorded rather than claimed correct, and the fix
    /// beside it deliberately leaves this path alone.
    func testApproximateMatchIsUnchanged() throws {
        XCTAssertEqual(try evaluate("VLOOKUP(M1,G1:H2,2,1)"), .error(.na),
                       "unmeasured against Excel; pinned so the exact-match fix cannot move it")
    }
}
