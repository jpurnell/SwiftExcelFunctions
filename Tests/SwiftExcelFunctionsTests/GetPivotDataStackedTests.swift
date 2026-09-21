import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// `GETPIVOTDATA` against a pivot with **two column fields** — the last 960 corpus cells.
///
/// ## The fixture
///
/// `pivotTable47` of `Dot Com YTD Performance Report 6 20.xlsx`, at `D92:R247` on `Forecast`,
/// trimmed to the same shape with its own numbers. Its column items stack down two header
/// rows, and the outer one is sparse **across** the columns exactly as row labels are sparse
/// **down** the rows — the two renderings are transposes of each other:
///
/// ```
///  92                                        | Scenario | Region |
///  93                                        | CY       |        | CY Total | PY   |     | PY Total
///  94  Values    | Last21Flag     | Report_Date | GBR   | WNE    |          | GBR  | WNE |
///  95   B1       | L21            | 2014-06-02  | 223   | 85     | 308      | 203  | 70  | 273
///  96            |                | 2014-06-03  | 245   | 108    | 353      | 213  | 111 | 324
///  97            | L21 Total      |             | 468   | 193    | 661      | 416  | 181 | 597
///  98            | (blank)        | 2014-05-19  | 109   | 40     | 149      | 90   | 30  | 120
///  99            | (blank) Total  |             | 109   | 40     | 149      | 90   | 30  | 120
/// 100   HSI      | L21            | 2014-06-02  | 293   | 158    | 451      | 250  | 120 | 370
/// 101            | L21 Total      |             | 293   | 158    | 451      | 250  | 120 | 370
/// 102  Total  B1                  |             | 577   | 233    | 810      | 506  | 211 | 717
/// 103  Total  HSI                 |             | 293   | 158    | 451      | 250  | 120 | 370
/// ```
///
/// Two further things this pivot shows that the first one did not.
///
/// **A subtotal caption can be written either way round.** `"L21 Total"` puts the word after
/// the item; `"Total  B1"` puts it before — and both are in this one table. The second is how
/// the values pseudo-field renders, and the doubled space is real: the caption is `" B1"`,
/// with a leading space of its own.
///
/// **`rowGrandTotals` is on, and there is more than one grand total row.** With the data field
/// names on the row axis Excel writes one per data field, so the last row of the range is
/// `"Total  HSI"` and a reader taking it for *the* grand total answers `HSI` to every question.
final class GetPivotDataStackedTests: XCTestCase {

    private struct Book: CellValueProvider {
        static let cells: [String: CellValue] = [
            "G92": .text("Scenario"), "H92": .text("Region"),

            "G93": .text("CY"), "I93": .text("CY Total"),
            "J93": .text("PY"), "L93": .text("PY Total"),

            "D94": .text("Values"), "E94": .text("Last21Flag"), "F94": .text("Report_Date"),
            "G94": .text("GBR"), "H94": .text("WNE"), "J94": .text("GBR"), "K94": .text("WNE"),

            "D95": .text(" B1"), "E95": .text("L21"), "F95": .text("2014-06-02"),
            "G95": .number(223), "H95": .number(85), "I95": .number(308),
            "J95": .number(203), "K95": .number(70), "L95": .number(273),

            "F96": .text("2014-06-03"),
            "G96": .number(245), "H96": .number(108), "I96": .number(353),
            "J96": .number(213), "K96": .number(111), "L96": .number(324),

            "E97": .text("L21 Total"),
            "G97": .number(468), "H97": .number(193), "I97": .number(661),
            "J97": .number(416), "K97": .number(181), "L97": .number(597),

            "E98": .text("(blank)"), "F98": .text("2014-05-19"),
            "G98": .number(109), "H98": .number(40), "I98": .number(149),
            "J98": .number(90), "K98": .number(30), "L98": .number(120),

            "E99": .text("(blank) Total"),
            "G99": .number(109), "H99": .number(40), "I99": .number(149),
            "J99": .number(90), "K99": .number(30), "L99": .number(120),

            "D100": .text(" HSI"), "E100": .text("L21"), "F100": .text("2014-06-02"),
            "G100": .number(293), "H100": .number(158), "I100": .number(451),
            "J100": .number(250), "K100": .number(120), "L100": .number(370),

            "E101": .text("L21 Total"),
            "G101": .number(293), "H101": .number(158), "I101": .number(451),
            "J101": .number(250), "K101": .number(120), "L101": .number(370),

            "D102": .text("Total  B1"),
            "G102": .number(577), "H102": .number(233), "I102": .number(810),
            "J102": .number(506), "K102": .number(211), "L102": .number(717),

            "D103": .text("Total  HSI"),
            "G103": .number(293), "H103": .number(158), "I103": .number(451),
            "J103": .number(250), "K103": .number(120), "L103": .number(370),
        ]
        let layouts: [PivotTableLayout]
        func value(at ref: CellRef) -> CellValue? { Self.cells[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { Self.cells[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("L103") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("L103") }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { Self.cells[$0.reference] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
        func sheetNames() -> [String] { ["Forecast"] }
        func pivotTables() -> [PivotTableLayout] { layouts }
    }

    private static let forecast = PivotTableLayout(
        sheet: "Forecast",
        range: CellRange(from: CellRef("D92"), to: CellRef("L103")),
        firstHeaderRow: 1, firstDataRow: 3, firstDataCol: 3,
        dataFields: [" B1", " HSI"], dataFieldSources: ["B1", "HSI"],
        rowFields: [.dataFieldNames, .field("Last21Flag"), .field("Report_Date")],
        columnFields: [.field("Scenario"), .field("Region")],
        pageFields: [], pageFieldRowCount: 0,
        // `colGrandTotals="0"` — `PY Total` is a column *subtotal*, not the table's total.
        hasRowGrandTotals: true, hasColumnGrandTotals: false)

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func evaluate(_ formula: String,
                          layouts: [PivotTableLayout] = [forecast]) throws -> CellValue {
        try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                      cells: Book(layouts: layouts), names: NoNames(),
                                      inSheet: "Forecast")
    }

    // MARK: - The column axis, stacked

    /// Both column fields named: the outer one is inherited across, the inner one picks out
    /// the column. `H95` sits under `CY` (written at `G93`) and `WNE`.
    func testBothColumnFieldsNameOneColumn() throws {
        XCTAssertEqual(
            try evaluate(#"""
            GETPIVOTDATA(" B1",D92,"Last21Flag","L21","Report_Date","2014-06-02",\
            "Scenario","CY","Region","WNE")
            """#.replacingOccurrences(of: "\\\n", with: "")),
            .number(85))
    }

    /// **The outer column item is sparse.** `PY` is written once at `J93` and covers `J` and
    /// `K`; asking for `PY`/`WNE` must reach `K95`, whose own header row says only `WNE`.
    func testTheOuterColumnItemIsCarriedAcross() throws {
        XCTAssertEqual(
            try evaluate(#"""
            GETPIVOTDATA(" B1",D92,"Last21Flag","L21","Report_Date","2014-06-02",\
            "Scenario","PY","Region","WNE")
            """#.replacingOccurrences(of: "\\\n", with: "")),
            .number(70), "K95 — `PY` was written two columns to its left")
    }

    /// Naming only the outer column field asks for its total across the inner one, which is
    /// the column Excel headed `CY Total`.
    func testNamingOnlyTheOuterColumnFieldReadsItsSubtotal() throws {
        XCTAssertEqual(
            try evaluate(#"""
            GETPIVOTDATA(" B1",D92,"Last21Flag","L21","Report_Date","2014-06-02","Scenario","CY")
            """#),
            .number(308), "I95 — the `CY Total` column")
    }

    // MARK: - A gap in the row constraints

    /// **930 corpus cells leave `Last21Flag` unconstrained**, naming only `Report_Date` of the
    /// two. That is a *gap*, not a prefix: the field above the named one is free.
    ///
    /// It resolves because the flag partitions the dates rather than subdividing them — `L21`
    /// marks the last 21 days and the blank item holds the rest, so each date appears under
    /// exactly one of them. Measured: 48 distinct dates in one group of the real pivot, none
    /// repeated across the split.
    func testAGapResolvesWhenExactlyOneRowMatches() throws {
        XCTAssertEqual(
            try evaluate(#"""
            GETPIVOTDATA(" B1",D92,"Report_Date","2014-05-19","Scenario","CY","Region","GBR")
            """#),
            .number(109), "row 98, which is the only `B1` row carrying that date")
    }

    /// And where a gap leaves **two** rows matching, there is no answer to give.
    ///
    /// The real pivot resolves because `Last21Flag` partitions the dates. A table where it did
    /// not — where the same date appeared under both items — would have the figure split
    /// across two rows and their total written nowhere, so returning either would be one half
    /// reported as the whole.
    func testAnAmbiguousGapRefuses() throws {
        /// The same shape, with `2014-06-02` appearing under **both** flag items.
        struct Split: CellValueProvider {
            static let cells: [String: CellValue] = [
                "G92": .text("Scenario"),
                "G93": .text("CY"),
                "D94": .text("Values"), "E94": .text("Last21Flag"),
                "F94": .text("Report_Date"), "G94": .text("GBR"),
                "D95": .text(" B1"), "E95": .text("L21"), "F95": .text("2014-06-02"),
                "G95": .number(223),
                "E96": .text("(blank)"), "F96": .text("2014-06-02"), "G96": .number(109),
                "D97": .text("Total  B1"), "G97": .number(332),
            ]
            let layout: PivotTableLayout
            func value(at ref: CellRef) -> CellValue? { Self.cells[ref.reference] }
            func value(at ref: CellRef, inSheet: String) -> CellValue? {
                Self.cells[ref.reference]
            }
            func lastPopulatedCell() -> CellRef? { CellRef("G97") }
            func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("G97") }
            func values(in range: CellRange) -> [CellValue] {
                range.cells.map { Self.cells[$0.reference] ?? .blank }
            }
            func values(in range: CellRange, inSheet: String) -> [CellValue] {
                values(in: range)
            }
            func sheetNames() -> [String] { ["Forecast"] }
            func pivotTables() -> [PivotTableLayout] { [layout] }
        }
        let layout = PivotTableLayout(
            sheet: "Forecast",
            range: CellRange(from: CellRef("D92"), to: CellRef("G97")),
            firstHeaderRow: 1, firstDataRow: 3, firstDataCol: 3,
            dataFields: [" B1"], dataFieldSources: ["B1"],
            rowFields: [.dataFieldNames, .field("Last21Flag"), .field("Report_Date")],
            columnFields: [.field("Scenario")],
            pageFields: [], pageFieldRowCount: 0,
            hasRowGrandTotals: true, hasColumnGrandTotals: false)

        func ask(_ formula: String) throws -> CellValue {
            try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                          cells: Split(layout: layout), names: NoNames(),
                                          inSheet: "Forecast")
        }
        XCTAssertEqual(
            try ask(#"GETPIVOTDATA(" B1",D92,"Report_Date","2014-06-02","Scenario","CY")"#),
            .error(.ref),
            "rows 95 and 96 both carry that date, and their sum is written nowhere")
        XCTAssertEqual(
            try ask(#"""
            GETPIVOTDATA(" B1",D92,"Last21Flag","L21","Report_Date","2014-06-02","Scenario","CY")
            """#),
            .number(223),
            "naming the field that was free picks out one of them again")
    }

    // MARK: - Subtotals written the other way round

    /// A middle level's subtotal, captioned **after** the item: `"L21 Total"`.
    func testAMiddleLevelSubtotalUsesTheSuffixForm() throws {
        XCTAssertEqual(
            try evaluate(#"GETPIVOTDATA(" B1",D92,"Last21Flag","L21","Scenario","CY","Region","GBR")"#),
            .number(468), "row 97 — `Report_Date` free, so the `L21 Total` row")
    }

    /// The values pseudo-field's total, captioned **before** the item: `"Total  B1"`.
    ///
    /// Both row fields below it are free, so this is that data field's grand total — one of
    /// several, since Excel writes one per data field when their names are on the row axis.
    func testTheValuesTotalUsesThePrefixForm() throws {
        XCTAssertEqual(
            try evaluate(#"GETPIVOTDATA(" B1",D92,"Scenario","CY","Region","GBR")"#),
            .number(577), "row 102 — `Total  B1`")
    }

    /// **The last row of the range is not *the* grand total here.**
    ///
    /// It reads `"Total  HSI"`, and a lookup that took it for the table's total would answer
    /// `HSI` to every question asked of the table. The data field selects among them.
    func testEachDataFieldHasItsOwnGrandTotalRow() throws {
        XCTAssertEqual(
            try evaluate(#"GETPIVOTDATA(" HSI",D92,"Scenario","CY","Region","GBR")"#),
            .number(293), "row 103, not row 102")
    }

    /// By source name as well as caption, and the leading space is not trimmed away.
    func testTheSourceNameSelectsTheSameRow() throws {
        XCTAssertEqual(
            try evaluate(#"GETPIVOTDATA("B1",D92,"Scenario","CY","Region","GBR")"#),
            .number(577), "`B1` is the source field behind the caption ` B1`")
    }
}
