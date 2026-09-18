import XCTest
@testable import WorkbookAudit
import SwiftExcelCore
import SwiftExcelFunctions
import SwiftXLSX

/// The oracle checker — step 5 of `PROPOSAL_workbook_validator.md`.
///
/// Every workbook here is built with **both halves of a formula cell**: the rule and the
/// value Excel last computed for it. That is what makes the fixture a fixture — a formula
/// with no cached value is not comparable to anything, and a test written without one would
/// pass by finding nothing whatever the checker did.
///
/// The false-positive half carries more weight than the true-positive half, as it does for
/// every checker here, and more so for this one: it is the only check that can report a
/// defect in someone's workbook on the strength of our own arithmetic.
final class StaleValueCheckerTests: XCTestCase {

    private func parse(_ formula: String) throws -> FormulaAST {
        try FormulaParser.parse(formula)
    }

    /// A one-sheet workbook whose formulas carry cached values.
    private func model(
        constants: [String: Double] = [:],
        formulas: [(ref: String, formula: String, cached: CellValue)]
    ) throws -> Workbook {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Model")
        for (ref, value) in constants.sorted(by: { $0.key < $1.key }) { sheet.write(value, to: ref) }
        for entry in formulas {
            sheet.write(try parse(entry.formula), to: entry.ref, cached: entry.cached)
        }
        return workbook
    }

    private func audit(_ workbook: Workbook) -> [Finding] {
        WorkbookAuditor(checkers: [StaleValueChecker()]).audit(workbook)
    }

    // MARK: - Finding one

    /// The defect this checker exists for: a number that no longer follows from its formula.
    func testAStaleCachedValueIsFound() throws {
        let workbook = try model(
            constants: ["B1": 10, "B2": 20],
            formulas: [("B3", "B1*B2", .number(999))])

        let findings = audit(workbook)
        XCTAssertEqual(findings.count, 1)
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.checker, "stale-value")
        XCTAssertEqual(finding.severity, .error)
        XCTAssertEqual(finding.address.cell, CellRef("B3"))

        // The finding carries its reasoning, which is what decides whether anyone acts on
        // it: both numbers and the formula that separates them.
        let detail = try XCTUnwrap(finding.detail)
        XCTAssertTrue(detail.contains("999"), "the finding must name what the file claims")
        XCTAssertTrue(detail.contains("200"), "and what the formula actually computes")
        XCTAssertTrue(detail.contains("B1*B2"), "and the formula itself")
    }

    /// A cached error that no longer follows is a warning rather than an error.
    ///
    /// Weaker deliberately. A half-built sheet is full of `#DIV/0!`, and this is also the
    /// direction in which our own gaps would show up.
    func testACachedErrorThatNoLongerFollowsIsAWarning() throws {
        let workbook = try model(
            constants: ["B1": 10, "B2": 2],
            formulas: [("B3", "B1/B2", .error(.div0))])

        let findings = audit(workbook)
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.severity, .warning)
    }

    // MARK: - Not finding one

    /// **The half that matters more.** A workbook whose cache is correct says nothing.
    func testACorrectCacheIsSilent() throws {
        let workbook = try model(
            constants: ["B1": 10, "B2": 20],
            formulas: [("B3", "B1*B2", .number(200)),
                       ("B4", "SUM(B1:B3)", .number(230)),
                       ("B5", "IF(B3>100,\"high\",\"low\")", .text("high"))])
        XCTAssertEqual(audit(workbook), [])
    }

    /// A cached error that *does* follow is agreement, not a finding.
    ///
    /// A model full of `#DIV/0!` is a model whose author left it that way, and reproducing
    /// that faithfully is the job.
    func testACachedErrorThatStillFollowsIsSilent() throws {
        let workbook = try model(
            constants: ["B1": 10, "B2": 0],
            formulas: [("B3", "B1/B2", .error(.div0))])
        XCTAssertEqual(audit(workbook), [])
    }

    /// **One stale edit is one finding, not a column of them.**
    ///
    /// The property that decides whether the report can be read. `B3` is stale; `B4` reads
    /// `B3` and its own cache agrees with the *stale* input, because that is the input
    /// Excel used too. So the cascade stays silent and the finding lands on the cell that
    /// was actually edited.
    func testOnlyTheOriginOfAStaleChainIsReported() throws {
        let workbook = try model(
            constants: ["B1": 10, "B2": 20],
            formulas: [("B3", "B1*B2", .number(999)),      // stale: should be 200
                       ("B4", "B3+1", .number(1000)),      // consistent with the stale B3
                       ("B5", "B4*2", .number(2000))])

        let findings = audit(workbook)
        XCTAssertEqual(findings.count, 1, "the cascade must not be reported")
        XCTAssertEqual(findings.first?.address.cell, CellRef("B3"))
    }

    /// A formula we cannot evaluate is our gap, not the workbook's defect.
    ///
    /// **`RTD` rather than something merely unimplemented.** This fixture used `FILTER`, and
    /// it worked until the day `FILTER` was implemented — at which point the test failed by
    /// finding a real disagreement, in a workbook built to have none. That is the sixth time
    /// a fixture in this project has encoded a temporary gap as though it were permanent.
    ///
    /// `RTD` asks a live data server for a value. There is no server here and there will not
    /// be one, so it is refused by design rather than by backlog, and this fixture cannot rot
    /// the same way twice.
    func testARefusalIsNotAFinding() throws {
        let workbook = try model(
            formulas: [("B3", "RTD(\"prog.id\",\"\",\"topic\")", .number(42))])
        XCTAssertEqual(audit(workbook), [])
    }

    /// A function where *Excel* is the imprecise party is passed over.
    ///
    /// `BESSELJ(0,0)` is exactly 1 by definition and Excel caches `1.00000000283141`. That
    /// is a fact about Excel; reporting it would bury the real findings under noise
    /// generated by being correct.
    func testExcelsOwnImprecisionIsNotAWorkbookDefect() throws {
        let workbook = try model(
            formulas: [("B3", "BESSELJ(0,0)", .number(1.00000000283141))])
        XCTAssertEqual(audit(workbook), [])
    }

    /// A function where *we* are the imprecise party is passed over too.
    ///
    /// `YEARFRAC` basis 0 misses the NASD February rule upstream, so a disagreement there is
    /// ours. Both directions of the honesty rule, and neither is a defect in the file.
    func testOurOwnKnownDefectsAreNotWorkbookDefects() throws {
        let workbook = try model(
            formulas: [("B3", "YEARFRAC(DATE(2020,2,29),DATE(2020,12,31),0)",
                        .number(301.0 / 360.0))])
        XCTAssertEqual(audit(workbook), [])
    }

    /// The exclusion list matches through Excel's version prefixes.
    ///
    /// A workbook saved by an older Excel writes `_xlfn.BESSELJ`. A list matching only the
    /// bare name would fire on old files and not on new ones, for the same formula.
    func testTheExclusionListSeesThroughTheModernPrefix() throws {
        let workbook = try model(
            formulas: [("B3", "_xlfn.BESSELJ(0,0)", .number(1.00000000283141))])
        XCTAssertEqual(audit(workbook), [])
    }

    /// A volatile function's cached value records an afternoon in 2013.
    func testAVolatileFormulaIsNotComparable() throws {
        let workbook = try model(formulas: [("B3", "TODAY()", .number(41_183))])
        XCTAssertEqual(audit(workbook), [])
    }

    /// **A cell holding a formula is never blank**, whatever the formula produced.
    ///
    /// `IF(…, A3, "")` leaves a cell whose result is the empty string, and `ISBLANK` of it
    /// is FALSE in Excel because there is a formula in there. Reading it as blank made
    /// `IF(NOT(ISBLANK(G3)),1,0)` answer 0 where Excel cached 1 — **147 cells in one
    /// workbook**, every one of which the checker was about to report as somebody's defect.
    ///
    /// The reader cannot distinguish an empty `<v/>` from a missing `<v>`, so the rule is
    /// applied at the point where a reference is read rather than at the point where the
    /// file is parsed.
    func testAFormulaCellIsNeverBlankHoweverEmptyItsResult() throws {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Model")
        // A formula whose cached result is empty — what `<c t="str"><f>…</f><v/></c>` is.
        sheet.write(try parse("IF(1=2,\"something\",\"\")"), to: "G3")
        sheet.write(try parse("IF(NOT(ISBLANK(G3)),1,0)"), to: "H3", cached: .number(1))
        // And a genuinely empty cell beside it, which *is* blank.
        sheet.write(try parse("IF(NOT(ISBLANK(G4)),1,0)"), to: "H4", cached: .number(0))

        XCTAssertEqual(audit(workbook), [], "neither cell is stale")
    }

    /// A name this package cannot turn into a reference is not comparable.
    ///
    /// A name the reader could not turn into a reference is not comparable.
    ///
    /// **Whole columns were this case until SwiftXLSX 0.26.0.** `amounts =
    /// Expenditures!$D:$D` failed the reader's reference test — which wanted a letter *and* a
    /// digit in each half, and `$D` has no digit — so the name evaluated to its own text and
    /// `SUMIFS(amounts, …)` summed nothing: **1,058 cells in one corpus workbook**, all of
    /// which the checker was about to report as somebody's stale values. Whole columns parse
    /// now, so this test uses `.unparsed` directly to stand for whatever the reader cannot
    /// read next.
    ///
    /// What belongs here is unchanged: declining to judge a formula we knowingly cannot
    /// evaluate. A cell we cannot compare is not a cell that disagrees.
    func testAnUnresolvableNameIsNotComparable() throws {
        let names = Names(targets: [
            "amounts": .unparsed("Expenditures!$D:$D"),            // read, but not understood
            "label": .formula(.text("\"Total\"")),                // a text constant
            "rate": .cell(CellRef("B1")),                         // an ordinary name
        ])
        let sumifs = try parse("SUMIFS(amounts,amounts,\">1\")")
        XCTAssertEqual(
            WorkbookOracle.unresolvableName(in: sumifs, names: names, sheet: "Model"),
            "amounts")

        // A text constant resolves, and an ordinary reference resolves.
        XCTAssertNil(WorkbookOracle.unresolvableName(
            in: try parse("label&rate"), names: names, sheet: "Model"))

        // A name with no definition at all: Excel cached a value, so it resolved for Excel.
        XCTAssertEqual(
            WorkbookOracle.unresolvableName(in: try parse("missing+1"),
                                            names: names, sheet: "Model"),
            "missing")
    }

    private struct Names: NameResolver {
        let targets: [String: NamedRangeTarget]
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { targets[name] }
    }

    // MARK: - What was passed over, and why

    /// The silence is counted rather than assumed.
    ///
    /// A checker that drops most of what it sees looks identical to one that found nothing,
    /// and the whole claim here rests on dropping the right things.
    func testWhatIsSkippedIsCounted() throws {
        let workbook = try model(
            constants: ["B1": 10, "B2": 20],
            formulas: [("B3", "B1*B2", .number(999)),                       // reported
                       ("B4", "BESSELJ(0,0)", .number(1.00000000283141)),   // Excel's
                       ("B5", "RTD(\"prog.id\",\"\",\"t\")", .number(42))])        // ours

        let (findings, skipped) = StaleValueChecker.findings(in: WorkbookOracle.audit(workbook))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(skipped.unattributable, 1)
        XCTAssertEqual(skipped.byFunction["BESSELJ"], 1)
        XCTAssertEqual(skipped.ours, 1)
        XCTAssertEqual(skipped.total, 2)
    }

    // MARK: - Running at all

    /// A checker that skips is not a checker that passed.
    ///
    /// Assembled without a workbook, this one cannot run — and says so, rather than
    /// returning nothing and letting the report look clean.
    func testAModelWithNoWorkbookSaysSoRatherThanPassing() {
        let provider = EmptyProvider()
        let model = AuditModel(cells: provider, addresses: [],
                               graph: DependencyGraph(cells: [], provider: provider))
        let findings = StaleValueChecker().check(model)

        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.severity, .note)
        XCTAssertTrue(findings.first?.summary.contains("did not run") ?? false)
    }

    private struct EmptyProvider: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }

    // MARK: - Determinism

    /// The same workbook produces the same findings in the same order.
    ///
    /// A validator whose output moves between runs cannot be diffed in CI, and one nobody
    /// can diff is one nobody wires up.
    func testTheReportIsStableAcrossRuns() throws {
        let workbook = try model(
            constants: ["B1": 10, "B2": 20],
            formulas: [("B3", "B1*B2", .number(999)),
                       ("C3", "B1+B2", .number(1)),
                       ("A3", "B1-B2", .number(2))])
        let first = audit(workbook)
        XCTAssertEqual(first.count, 3)
        XCTAssertEqual(first, audit(workbook))
        XCTAssertEqual(first.map(\.address.cell.reference), ["A3", "B3", "C3"])
    }
}
