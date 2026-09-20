import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// `GETPIVOTDATA` — a lookup into a table already rendered on the sheet.
///
/// **3,802 corpus cells, 90% of everything a 300-workbook run still disagreed on** — of which
/// the two-argument form measured here is 228, and all 228 now agree. The
/// function reads a pivot table's *rendered* values: Excel writes them into cells and caches
/// them there like any other formula result, so nothing here aggregates and `xl/pivotCache/`
/// is never opened. One corpus workbook carries 76 cache parts and needs none of them.
///
/// The fixture is the corpus's own shape. `Amazon Reporting thru 05-15-18.xlsx` renders a
/// pivot at `M1:O253` on `W-E Nov 18`, and Excel's cached answer for
/// `GETPIVOTDATA("Sum of # Minutes Streamed", 'W-E Nov 18'!$M$1)` is the value at `O253`.
final class GetPivotDataTests: XCTestCase {

    /// A sheet holding a small pivot of the same shape: labels in `M`, two data columns.
    ///
    /// ```
    ///        M              N                  O
    ///   1    Row Labels     Sum of # Streams   Sum of # Minutes Streamed
    ///   2    Drama          10                 100
    ///   3    Comedy         20                 200
    ///   4    Grand Total    30                 300
    /// ```
    private struct Book: CellValueProvider {
        private static let cells: [String: CellValue] = [
            "M1": .text("Row Labels"), "N1": .text("Sum of # Streams"),
            "O1": .text("Sum of # Minutes Streamed"),
            "M2": .text("Drama"), "N2": .number(10), "O2": .number(100),
            "M3": .text("Comedy"), "N3": .number(20), "O3": .number(200),
            "M4": .text("Grand Total"), "N4": .number(30), "O4": .number(300),
        ]
        let layouts: [PivotTableLayout]

        func value(at ref: CellRef) -> CellValue? { Self.cells[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { Self.cells[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("O4") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("O4") }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { Self.cells[$0.reference] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
        func sheetNames() -> [String] { ["W-E Nov 18"] }
        func pivotTables() -> [PivotTableLayout] { layouts }
    }

    private static let layout = PivotTableLayout(
        sheet: "W-E Nov 18",
        range: CellRange(from: CellRef("M1"), to: CellRef("O4")),
        firstDataRow: 1, firstDataCol: 1,
        dataFields: ["Sum of # Streams", "Sum of # Minutes Streamed"],
        hasRowGrandTotals: true, hasColumnGrandTotals: true)

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func evaluate(_ formula: String,
                          layouts: [PivotTableLayout] = [layout]) throws -> CellValue {
        try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                      cells: Book(layouts: layouts), names: NoNames(),
                                      inSheet: "W-E Nov 18")
    }

    // MARK: - The shape the corpus is full of

    /// Two arguments: the grand total of a named data field.
    func testTheGrandTotalOfADataField() throws {
        XCTAssertEqual(try evaluate("GETPIVOTDATA(\"Sum of # Minutes Streamed\", M1)"),
                       .number(300))
        XCTAssertEqual(try evaluate("GETPIVOTDATA(\"Sum of # Streams\", M1)"), .number(30),
                       "the first data field, so the column is found by name and not position")
    }

    /// The second argument identifies the table and nothing else, so any cell of it serves.
    func testAnyCellOfTheTableIdentifiesIt() throws {
        XCTAssertEqual(try evaluate("GETPIVOTDATA(\"Sum of # Streams\", O3)"), .number(30),
                       "a cell in the middle of the pivot names the same table as its anchor")
    }

    /// **Sheet-qualified, which is how the corpus writes it.**
    ///
    /// `GETPIVOTDATA("Sum of # Minutes Streamed", 'W-E Nov 18'!$M$1)` — and one corpus
    /// workbook renders a pivot at `M1` on dozens of sheets, one per week, so the sheet is
    /// what tells them apart. Matching on the address alone would answer from whichever was
    /// read first.
    func testTheSheetIsPartOfIdentifyingTheTable() throws {
        XCTAssertEqual(
            try evaluate("GETPIVOTDATA(\"Sum of # Minutes Streamed\", 'W-E Nov 18'!$M$1)"),
            .number(300))

        let elsewhere = PivotTableLayout(
            sheet: "W-E Aug 12",
            range: CellRange(from: CellRef("M1"), to: CellRef("O4")),
            firstDataRow: 1, firstDataCol: 1,
            dataFields: ["Sum of # Streams", "Sum of # Minutes Streamed"],
            hasRowGrandTotals: true, hasColumnGrandTotals: true)
        XCTAssertEqual(
            try evaluate("GETPIVOTDATA(\"Sum of # Streams\", 'W-E Nov 18'!$M$1)",
                         layouts: [elsewhere]),
            .error(.ref),
            "the same address on another sheet is a different table, and is refused")
    }

    // MARK: - Refusing rather than guessing

    func testACellInNoPivotIsARefError() throws {
        XCTAssertEqual(try evaluate("GETPIVOTDATA(\"Sum of # Streams\", A1)"), .error(.ref))
    }

    func testADataFieldThatIsNotInTheTableIsARefError() throws {
        XCTAssertEqual(try evaluate("GETPIVOTDATA(\"Sum of Nothing\", M1)"), .error(.ref))
    }

    /// A provider with no pivots answers `#REF!` — which is what this package answered before
    /// any of this existed, so nothing that does not model a workbook changes behaviour.
    func testAProviderWithoutPivotsRefuses() throws {
        XCTAssertEqual(try evaluate("GETPIVOTDATA(\"Sum of # Streams\", M1)", layouts: []),
                       .error(.ref))
    }

    /// **A table with no grand total row cannot answer the two-argument form.**
    ///
    /// Measured: a pivot with `rowGrandTotals="0"` ends on an ordinary row — in the corpus,
    /// one reading `"KEY Total"`, a *subtotal*. Returning that would be a wrong number
    /// reported quietly, which is worse than refusing.
    func testATableWithNoGrandTotalRefusesTheTwoArgumentForm() throws {
        let noTotals = PivotTableLayout(
            sheet: "W-E Nov 18",
            range: CellRange(from: CellRef("M1"), to: CellRef("O4")),
            firstDataRow: 1, firstDataCol: 1,
            dataFields: ["Sum of # Streams", "Sum of # Minutes Streamed"],
            hasRowGrandTotals: false, hasColumnGrandTotals: false)
        XCTAssertEqual(try evaluate("GETPIVOTDATA(\"Sum of # Streams\", M1)",
                                    layouts: [noTotals]),
                       .error(.ref))
    }

    /// Field/item pairs are **phase two** and refused for now.
    ///
    /// **3,574 corpus cells** use them — every `GETPIVOTDATA` finding that survives the
    /// two-argument form, carrying three to five pairs, and all of them in one workbook. The
    /// first count of this said 2,002: it came from a regex that stopped at the comma inside
    /// `TEXT($B87,"")` and read five-pair calls as two-argument ones.
    ///
    /// They need the row labels matched against item values — in a multi-field pivot laid out
    /// hierarchically, with subtotal rows to tell apart from data rows. Refusing is honest;
    /// guessing at a row would not be.
    func testFieldItemPairsAreRefusedForNow() throws {
        XCTAssertEqual(
            try evaluate("GETPIVOTDATA(\"Sum of # Streams\", M1, \"Genre\", \"Drama\")"),
            .error(.ref))
    }
}
