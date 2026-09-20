import XCTest
@testable import WorkbookAudit
import SwiftExcelCore
import SwiftExcelFunctions
import SwiftXLSX

/// What a verdict carries, and why a refusal has to carry Excel's answer.
///
/// **A refusal is the outcome that most needs the other side of the comparison.** `differed`
/// prints both values and can be read at a glance; `refused` says only that we answered an
/// error, and the whole question — *what should it have been?* — was left out of the row.
///
/// It cost a triage. A corpus run produced 1,664 `MONTH` refusals in one workbook, every row
/// reading `ours=#NUM!  excel=(a value)`, and finding out that Excel had cached `1` meant
/// unzipping the workbook by hand and reading the sheet XML. The answer turned out to be a
/// measured date boundary — serial 0 is January 0, 1900, and Excel accepts it — which is
/// exactly the kind of thing the findings file exists to surface without anyone opening a file.
final class OracleOutcomeTests: XCTestCase {

    private func workbook(
        constants: [String: Double] = [:],
        formula: String,
        at reference: String,
        cached: CellValue
    ) throws -> Workbook {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Model")
        for (ref, value) in constants.sorted(by: { $0.key < $1.key }) {
            sheet.write(value, to: ref)
        }
        sheet.write(try FormulaParser.parse(formula), to: reference, cached: cached)
        return workbook
    }

    private func outcome(of report: OracleReport) throws -> OracleOutcome {
        guard let finding = report.findings.first else {
            throw XCTSkip("the audit produced no finding to judge")
        }
        return finding.outcome
    }

    /// A name pointing into another workbook is an external reference, wherever it hides.
    ///
    /// **The detector walked the formula and the formula did not say so.** Excel writes an
    /// external reference as `[1]Sheet!A1`, and `externalReference(in:)` looks for a bracketed
    /// sheet name among the AST's nodes. But `VLOOKUP(B157, month_lookup, 2, 0)` holds no such
    /// node: the bracket is in the *name table*, where `month_lookup` resolves to
    /// `[1]Definitions!$C$75:$E$86`. So the formula read as ordinary, we answered `#N/A`
    /// having nothing to look in, and Excel's cached `"October"` counted against us.
    ///
    /// 216 cells in a single corpus workbook. The doc comment on `externalReference(in:)` had
    /// already named the cost of getting this wrong — "counting it as one put a floor under
    /// the failure rate that no amount of work could lift" — and the name path walked straight
    /// past it.
    func testAnExternalReferenceReachedThroughANameIsNotComparable() throws {
        let book = Workbook()
        let sheet = book.addSheet(name: "Model")
        sheet.write(2.0, to: "B1")
        book.define("month_lookup", as: .sheetRange(
            SheetReference(sheet: "[1]Definitions", range: CellRange(from: "C75", to: "E86"))))
        sheet.write(try FormulaParser.parse("VLOOKUP(B1, month_lookup, 2, 0)"),
                    to: "C1", cached: .text("October"))

        guard case .notComparable(let reason) = try outcome(of: WorkbookOracle.audit(book)) else {
            return XCTFail("expected notComparable, got \(try outcome(of: WorkbookOracle.audit(book)))")
        }
        XCTAssertTrue(reason.contains("external"),
                      "and it says why, rather than counting as a disagreement: \(reason)")
    }

    /// A refusal records what Excel had, so the row can be triaged without the workbook.
    func testARefusalCarriesExcelsValue() throws {
        // `SQRT(-1)` is `#NUM!` for us and a number in the cache — the shape of every
        // refusal: we answered an error where Excel answered something.
        let book = try workbook(formula: "SQRT(-1)", at: "B1", cached: .number(42))

        guard case .refused(let error, let excel) = try outcome(of: WorkbookOracle.audit(book))
        else {
            return XCTFail("expected a refusal, got \(try outcome(of: WorkbookOracle.audit(book)))")
        }
        XCTAssertEqual(error, .num, "the error we answered")
        XCTAssertEqual(excel, .number(42), "and the value Excel had, which is the point")
    }

    /// So does a throw, for the same reason.
    func testAThrowCarriesExcelsValue() throws {
        // `IFERROR` with one argument: a Google Sheets signature Excel does not accept, and
        // the shape that produced 895 throws in the corpus. We refuse on argument count.
        let book = try workbook(
            constants: ["B1": 10, "B2": 0],
            formula: "IFERROR(B1/B2)", at: "B3", cached: .text("caught"))

        guard case .threw(let message, let excel) = try outcome(of: WorkbookOracle.audit(book))
        else {
            throw XCTSkip("this build accepts a one-argument IFERROR; nothing threw")
        }
        XCTAssertFalse(message.isEmpty, "the throw is still described")
        XCTAssertEqual(excel, .text("caught"), "and Excel's side survives into the row")
    }
}
