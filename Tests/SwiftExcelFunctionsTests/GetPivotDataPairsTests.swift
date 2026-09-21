import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// `GETPIVOTDATA` with field/item pairs — **3,574 corpus cells, all in one workbook.**
///
/// ## The fixture is the corpus's own shape
///
/// `pivotTable8` in `Dot Com YTD Performance Report 6 20.xlsx`, rendered at `C134:L243` on
/// `NED Mix`, with four row fields, one column field and two page fields:
///
/// ```
/// 131  SalesChannelRollUp | (All)                                       ← page fields, above
/// 132  ActivityDetail     | Connect                                        the range
/// 133                                                                   ← a blank separator
/// 134  Sum of Subs        |        |             |        | FME_Calc    ← captions
/// 135  Scenario | Region  | LOBMix_noXH | BP/IP  | 20  | 21  | 22       ← names + col items
/// 136  CY       | GBR     | V           |        | 303 | 301 | 256
/// 137           |         | D           |        | 1633| 1233| 944
/// 139           |         | VD          | BP     | 487 | 319 | 390
/// 140           |         |             | IP     | 183 | 218 | 238
/// 141           |         |             | (blank)| 1406| 1315| 1361
/// 142           |         | VD Total    |        | 2076| 1852| 1989     ← a subtotal
/// 146           | GBR Total                      | 5011| 4130| 4038     ← an outer subtotal
/// 243  Grand Total                               |48095|47039|45282     ← the grand total
/// ```
///
/// Three things in that picture are the whole problem. **Row labels are sparse** — written
/// once and inherited by the rows beneath, so a scan for `GBR` finds row 136 and nothing else.
/// **Subtotals are answers, not noise**: 420 corpus cells at one anchor constrain three of the
/// four row fields, and row 142 is what Excel returns for them. And an **empty item renders as
/// the literal text `(blank)`**, which is a value, not a gap.
final class GetPivotDataPairsTests: XCTestCase {

    /// The sheet above, as cells.
    private struct Book: CellValueProvider {
        static let cells: [String: CellValue] = [
            "C131": .text("SalesChannelRollUp"), "D131": .text("(All)"),
            "C132": .text("ActivityDetail"), "D132": .text("Connect"),

            "C134": .text("Sum of Subs"), "G134": .text("FME_Calc"),

            "C135": .text("Scenario"), "D135": .text("Region"),
            "E135": .text("LOBMix_noXH"), "F135": .text("BP/IP"),
            "G135": .number(20), "H135": .number(21), "I135": .number(22),

            "C136": .text("CY"), "D136": .text("GBR"), "E136": .text("V"),
            "G136": .number(303), "H136": .number(301), "I136": .number(256),

            "E137": .text("D"),
            "G137": .number(1633), "H137": .number(1233), "I137": .number(944),

            "E139": .text("VD"), "F139": .text("BP"),
            "G139": .number(487), "H139": .number(319), "I139": .number(390),

            "F140": .text("IP"),
            "G140": .number(183), "H140": .number(218), "I140": .number(238),

            "F141": .text("(blank)"),
            "G141": .number(1406), "H141": .number(1315), "I141": .number(1361),

            "E142": .text("VD Total"),
            "G142": .number(2076), "H142": .number(1852), "I142": .number(1989),

            "D146": .text("GBR Total"),
            "G146": .number(5011), "H146": .number(4130), "I146": .number(4038),

            "C243": .text("Grand Total"),
            "G243": .number(48095), "H243": .number(47039), "I243": .number(45282),
        ]
        let layouts: [PivotTableLayout]
        func value(at ref: CellRef) -> CellValue? { Self.cells[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { Self.cells[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("L243") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("L243") }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { Self.cells[$0.reference] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
        func sheetNames() -> [String] { ["NED Mix"] }
        func pivotTables() -> [PivotTableLayout] { layouts }
    }

    private static let mix = PivotTableLayout(
        sheet: "NED Mix",
        range: CellRange(from: CellRef("C134"), to: CellRef("L243")),
        firstHeaderRow: 1, firstDataRow: 2, firstDataCol: 4,
        dataFields: ["Sum of Subs"], dataFieldSources: ["Subs"],
        rowFields: [.field("Scenario"), .field("Region"),
                    .field("LOBMix_noXH"), .field("BP/IP")],
        columnFields: [.field("FME_Calc")],
        pageFields: ["SalesChannelRollUp", "ActivityDetail"],
        pageFieldRowCount: 2,
        // `colGrandTotals="0"` in the file, which is why `L135` reads a date rather than
        // `"Grand Total"` and `L243` is one week's figure rather than the table's total.
        hasRowGrandTotals: true, hasColumnGrandTotals: false)

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func evaluate(_ formula: String,
                          layouts: [PivotTableLayout] = [mix]) throws -> CellValue {
        try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                      cells: Book(layouts: layouts), names: NoNames(),
                                      inSheet: "NED Mix")
    }

    // MARK: - Every row field constrained

    /// The shape 120 corpus cells at one anchor use: all four row fields and the column field.
    func testAllRowFieldsAndTheColumn() throws {
        XCTAssertEqual(
            try evaluate("""
            GETPIVOTDATA("Subs",C134,"Scenario","CY","Region","GBR",\
            "LOBMix_noXH","VD","BP/IP","IP","FME_Calc",20)
            """),
            .number(183), "row 140, column G")
    }

    /// **Labels are inherited.** `Scenario` and `Region` are written only on row 136, and the
    /// answer is on row 140 — a scan that requires a literal match in every column finds
    /// nothing at all here.
    func testLabelsAreCarriedDownFromTheRowThatWroteThem() throws {
        XCTAssertEqual(
            try evaluate("""
            GETPIVOTDATA("Subs",C134,"Scenario","CY","Region","GBR",\
            "LOBMix_noXH","D","FME_Calc",21)
            """),
            .number(1233), "row 137, whose C and D are blank on the sheet")
    }

    /// The pairs may be written in any order; Excel matches by name, not by position.
    func testPairsAreMatchedByNameNotByPosition() throws {
        XCTAssertEqual(
            try evaluate("""
            GETPIVOTDATA("Subs",C134,"FME_Calc",22,"Region","GBR",\
            "BP/IP","BP","Scenario","CY","LOBMix_noXH","VD")
            """),
            .number(390), "row 139, column I")
    }

    // MARK: - Subtotals, which are answers

    /// **420 corpus cells at `$C$134` leave the innermost row field unconstrained.**
    ///
    /// Three of four row fields named, and the answer is the subtotal row Excel renders for
    /// exactly that grouping — row 142, labelled `VD Total`. Skipping subtotal rows as "not
    /// data" would refuse every one of those cells.
    func testAnUnconstrainedInnerFieldIsAnsweredByItsSubtotal() throws {
        XCTAssertEqual(
            try evaluate("""
            GETPIVOTDATA("Subs",C134,"Scenario","CY","Region","GBR",\
            "LOBMix_noXH","VD","FME_Calc",20)
            """),
            .number(2076), "row 142 — `VD Total`, not row 139")
    }

    /// Two levels up: only the outermost two constrained, so the `GBR Total` row answers.
    func testAnOuterSubtotalAnswersWhenTwoFieldsAreFree() throws {
        XCTAssertEqual(
            try evaluate("""
            GETPIVOTDATA("Subs",C134,"Scenario","CY","Region","GBR","FME_Calc",20)
            """),
            .number(5011), "row 146 — `GBR Total`")
    }

    /// **No pairs against a column axis with no column total is `#REF!`.**
    ///
    /// This test first asserted `48095`, the figure at `G243`. That is the total for *one*
    /// column — `FME_Calc` = 20 — and not the table's overall total, which this pivot holds
    /// in no cell at all: it is written `colGrandTotals="0"`, so `L135` reads a date and
    /// `L243` is another week's figure. Returning `G243` would have reported one week's number
    /// as the total of twenty-six.
    func testNoPairsWithNoColumnTotalRefuses() throws {
        XCTAssertEqual(try evaluate("GETPIVOTDATA(\"Subs\",C134)"), .error(.ref),
                       "the overall total is rendered nowhere, so there is nothing to return")
    }

    /// And where the table **does** render one, the grand total column answers.
    ///
    /// `pivotTable50` of the same workbook, at `B41:H45`, leaves `colGrandTotals` at its
    /// default and writes `"Grand Total"` into `H42` with the overall figure at `H45`.
    func testNoPairsReadsTheGrandTotalColumnWhenThereIsOne() throws {
        struct Totals: CellValueProvider {
            static let cells: [String: CellValue] = [
                "B41": .text("Sum of Subs"), "C42": .text("GBR"), "H42": .text("Grand Total"),
                "B42": .text("Scenario"), "B43": .text("CY"), "C43": .number(11),
                "H43": .number(30000), "B44": .text("PY"), "C44": .number(12),
                "H44": .number(41471),
                "B45": .text("Grand Total"), "C45": .number(23), "H45": .number(71471),
            ]
            let layout: PivotTableLayout
            func value(at ref: CellRef) -> CellValue? { Self.cells[ref.reference] }
            func value(at ref: CellRef, inSheet: String) -> CellValue? {
                Self.cells[ref.reference]
            }
            func lastPopulatedCell() -> CellRef? { CellRef("H45") }
            func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("H45") }
            func values(in range: CellRange) -> [CellValue] {
                range.cells.map { Self.cells[$0.reference] ?? .blank }
            }
            func values(in range: CellRange, inSheet: String) -> [CellValue] {
                values(in: range)
            }
            func sheetNames() -> [String] { ["Exec Summary"] }
            func pivotTables() -> [PivotTableLayout] { [layout] }
        }
        let layout = PivotTableLayout(
            sheet: "Exec Summary",
            range: CellRange(from: CellRef("B41"), to: CellRef("H45")),
            firstHeaderRow: 1, firstDataRow: 2, firstDataCol: 1,
            dataFields: ["Sum of Subs"], dataFieldSources: ["Subs"],
            rowFields: [.field("Scenario")], columnFields: [.field("Region")],
            pageFields: [], pageFieldRowCount: 0,
            hasRowGrandTotals: true, hasColumnGrandTotals: true)
        XCTAssertEqual(
            try FormulaEvaluator.evaluate(try FormulaParser.parse("GETPIVOTDATA(\"Subs\",B41)"),
                                          cells: Totals(layout: layout), names: NoNames(),
                                          inSheet: "Exec Summary"),
            .number(71471), "H45 — the grand total row meeting the grand total column")
    }

    // MARK: - Items that are not text

    /// **Column items here are numbers**, and `"20"` is not `20`. Comparing the rendered text
    /// would match nothing; comparing values matches the column.
    func testItemsAreComparedByValue() throws {
        XCTAssertEqual(
            try evaluate("""
            GETPIVOTDATA("Subs",C134,"Scenario","CY","Region","GBR",\
            "LOBMix_noXH","V","FME_Calc",20)
            """),
            .number(303))
    }

    /// **An empty item renders as the literal text `(blank)`** and is a real item.
    func testTheBlankItemIsAnItem() throws {
        XCTAssertEqual(
            try evaluate("""
            GETPIVOTDATA("Subs",C134,"Scenario","CY","Region","GBR",\
            "LOBMix_noXH","VD","BP/IP","(blank)","FME_Calc",20)
            """),
            .number(1406), "row 141")
    }

    /// **An omitted item names the blank one**, which is 204 corpus cells.
    ///
    /// They are written `GETPIVOTDATA("Subs",$C$134,…,"BP/IP",)` — a trailing comma with
    /// nothing after it. Excel reads the empty argument as the empty item and answers from the
    /// row it renders as `(blank)`; we answered `#REF!`, which `IFERROR` turned into `0`, so
    /// the finding read `ours=0 excel=1476` and looked like an arithmetic disagreement rather
    /// than a refusal.
    func testAnOmittedItemNamesTheBlankItem() throws {
        XCTAssertEqual(
            try evaluate("""
            GETPIVOTDATA("Subs",C134,"Scenario","CY","Region","GBR",\
            "LOBMix_noXH","VD","BP/IP",,"FME_Calc",20)
            """),
            .number(1406), "row 141, the row labelled `(blank)`")
    }

    // MARK: - Page fields

    /// A page field pair must agree with the filter actually applied, which is rendered above
    /// the table. `ActivityDetail` is filtered to `Connect`, so naming `Connect` is consistent
    /// and constrains nothing further.
    func testAPageFieldPairThatAgreesWithTheFilterIsAccepted() throws {
        XCTAssertEqual(
            try evaluate("""
            GETPIVOTDATA("Subs",C134,"ActivityDetail","Connect","Scenario","CY",\
            "Region","GBR","LOBMix_noXH","V","FME_Calc",20)
            """),
            .number(303))
    }

    /// **Naming an item the filter excludes is `#REF!`.** The table does not contain the
    /// number asked for — it was filtered out before rendering — and answering from the rows
    /// that *are* there would report a `Disconnect` figure as a `Connect` one.
    func testAPageFieldPairThatContradictsTheFilterRefuses() throws {
        XCTAssertEqual(
            try evaluate("""
            GETPIVOTDATA("Subs",C134,"ActivityDetail","Disconnect","Scenario","CY",\
            "Region","GBR","LOBMix_noXH","V","FME_Calc",20)
            """),
            .error(.ref))
    }

    // MARK: - Refusing rather than guessing

    func testAFieldThatIsOnNoAxisRefuses() throws {
        XCTAssertEqual(
            try evaluate("GETPIVOTDATA(\"Subs\",C134,\"Fiber\",\"Y\",\"FME_Calc\",20)"),
            .error(.ref))
    }

    func testAnItemThatIsNotInTheTableRefuses() throws {
        XCTAssertEqual(
            try evaluate("""
            GETPIVOTDATA("Subs",C134,"Scenario","CY","Region","ZZZ","FME_Calc",20)
            """),
            .error(.ref))
    }

    /// A pair naming a field with no item to match it — an odd argument count — is `#REF!`.
    func testADanglingFieldWithNoItemRefuses() throws {
        XCTAssertEqual(
            try evaluate("GETPIVOTDATA(\"Subs\",C134,\"Scenario\")"), .error(.ref))
    }

    /// **An outer field left free while an inner one is constrained has no row.**
    ///
    /// `Region` = `GBR` with `Scenario` unconstrained asks for a total Excel never rendered:
    /// the subtotals nest outermost-first, so there is no `GBR across all scenarios` row.
    /// Refusing is honest; the `CY`/`GBR` row would be a different number.
    func testConstrainingAnInnerFieldWithoutTheOuterOneRefuses() throws {
        XCTAssertEqual(
            try evaluate("GETPIVOTDATA(\"Subs\",C134,\"Region\",\"GBR\",\"FME_Calc\",20)"),
            .error(.ref))
    }

    /// A layout with no axis detail — read from a workbook whose cache could not be reached —
    /// refuses pairs rather than guessing at columns.
    func testALayoutWithoutAxesRefusesPairs() throws {
        let bare = PivotTableLayout(
            sheet: "NED Mix",
            range: CellRange(from: CellRef("C134"), to: CellRef("L243")),
            firstDataRow: 2, firstDataCol: 4,
            dataFields: ["Sum of Subs"],
            hasRowGrandTotals: true, hasColumnGrandTotals: true)
        XCTAssertEqual(
            try evaluate("GETPIVOTDATA(\"Sum of Subs\",C134,\"Scenario\",\"CY\")",
                         layouts: [bare]),
            .error(.ref))
    }
}
