import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX
import BusinessMath

/// Everything, on a real file: read the workbook, recognise the model, order it, run the
/// trials, read the statistics back.
///
/// This is the first test where all of it is load-bearing at once. The pieces have each
/// been checked in isolation — recogniser, survey, order validation, trial loop, the
/// statistics seam — and isolation is exactly where the seams between them do not show.
///
/// The evaluation order comes from `SwiftXLSX.DependencyGraph`, which the *test target*
/// may depend on even though the library may not. That is the whole point of taking the
/// order as a parameter: the library keeps its promise and the test still gets a real
/// order from the real implementation, rather than a second topological sort written to
/// avoid the dependency.
///
/// ```
/// RISK_SOLVER_WORKBOOKS=<dir> swift test --filter EndToEndSimulation
/// ```
final class EndToEndSimulationTests: XCTestCase {

    /// Adds enumeration to SwiftXLSX's own workbook-backed provider.
    ///
    /// `WorkbookValueProvider` already reads formulas *and* constants, which is what a
    /// trial loop needs — `RiskSolverWorkbookTests.SheetProvider` returns only formulas,
    /// which is right for surveying and wrong for running: a trial that cannot read the
    /// constants its model multiplies by is computing a different model.
    ///
    /// What it cannot do is enumerate, because `CellValueProvider` has no way to express
    /// that. This is the gap `PROPOSAL_dependency_graph_over_a_provider.md` §3.1 is about,
    /// met here in the smallest possible form: the sheet knows its own keys, so the
    /// wrapper hands them over.
    private struct EnumerableSheet: CellValueProvider, PopulatedCellProvider {
        let inner: WorkbookValueProvider
        let refs: [CellRef]

        init(workbook: Workbook, sheet: Worksheet) {
            self.inner = WorkbookValueProvider(workbook: workbook, currentSheet: sheet.name)
            self.refs = sheet.cellReferences.map { CellRef($0) }
        }

        func populatedCells() -> [CellRef] { refs }
        func value(at ref: CellRef) -> CellValue? { inner.value(at: ref) }
        func value(at ref: CellRef, inSheet: String) -> CellValue? {
            inner.value(at: ref, inSheet: inSheet)
        }
        func values(in range: CellRange) -> [CellValue] { inner.values(in: range) }
        func values(in range: CellRange, inSheet: String) -> [CellValue] {
            inner.values(in: range, inSheet: inSheet)
        }
        func lastPopulatedCell() -> CellRef? { inner.lastPopulatedCell() }
        func lastPopulatedCell(inSheet: String) -> CellRef? { inner.lastPopulatedCell(inSheet: inSheet) }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func workbooks() throws -> [(name: String, workbook: Workbook)] {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["RISK_SOLVER_WORKBOOKS"], !root.isEmpty else {
            throw XCTSkip("Set RISK_SOLVER_WORKBOOKS to a directory of Risk Solver models.")
        }
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let paths = ((try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.hasSuffix(".xlsx") && !$0.hasPrefix("~$") }
            .sorted()

        return paths.compactMap { path in
            guard let data = try? Data(contentsOf: url.appendingPathComponent(path)),
                  let workbook = try? Workbook(xlsxData: data) else { return nil }
            return (path, workbook)
        }
    }

    /// The order for one sheet, from the real graph, narrowed to that sheet.
    private func order(for sheet: Worksheet, in workbook: Workbook) -> [CellRef] {
        DependencyGraph(workbook: workbook)
            .evaluationOrder
            .filter { $0.sheet == sheet.name }
            .map(\.cell)
    }

    // MARK: - The whole path

    /// Reads every model, runs the ones that can run, and reports what stopped the rest.
    ///
    /// Deliberately a report rather than a pass/fail on any particular model: what a real
    /// corpus can and cannot do is a fact to discover, and asserting a count would fail the
    /// moment someone added a workbook.
    func testRunsEveryModelItCan() throws {
        var ran = 0, refused = 0
        var reasons: [String: Int] = [:]
        var report = ""

        for (name, workbook) in try workbooks() {
            for sheet in workbook.sheets {
                let cells = EnumerableSheet(workbook: workbook, sheet: sheet)
                let survey = ModelSurveyor().survey(cells)
                guard survey.isSimulable else { continue }

                do {
                    let run = try InterpretedRun(
                        survey: survey,
                        evaluationOrder: order(for: sheet, in: workbook),
                        trials: 200,
                        seed: 42
                    ).run(over: cells, names: NoNames())

                    ran += 1
                    let collected = run.outputs.values.map(\.values.count)
                    let short = collected.filter { $0 < 200 }.count
                    report += "  ✓ \(name) / \(sheet.name): \(run.outputs.count) output(s)"
                        + (short > 0 ? ", \(short) with errored trials" : "")
                        + "\n"
                } catch let error as TrialRunError {
                    refused += 1
                    let kind = "\(error)".prefix(while: { $0 != "(" })
                    reasons[String(kind), default: 0] += 1
                    report += "  ✗ \(name) / \(sheet.name): \(error)\n"
                }
            }
        }

        print("""

        ── End to end, real workbooks ──────────────────────────────
        \(report)
          ran \(ran), refused \(refused)
          refusals: \(reasons.isEmpty ? "none" : "\(reasons)")
        ────────────────────────────────────────────────────────────

        """)

        XCTAssertGreaterThan(ran, 0, "no real model ran end to end")
    }

    /// A seeded run of a real model reproduces exactly.
    ///
    /// The property every downstream number depends on, asserted on a real model rather
    /// than a fixture — real ones have lookups, blanks and cached errors that a
    /// hand-written sheet does not.
    func testARealModelReproducesUnderTheSameSeed() throws {
        var checked = 0

        for (_, workbook) in try workbooks() {
            for sheet in workbook.sheets {
                let cells = EnumerableSheet(workbook: workbook, sheet: sheet)
                let survey = ModelSurveyor().survey(cells)
                guard survey.isSimulable else { continue }
                let ordering = order(for: sheet, in: workbook)

                guard let first = try? InterpretedRun(
                        survey: survey, evaluationOrder: ordering, trials: 100, seed: 99)
                        .run(over: cells, names: NoNames()),
                      let second = try? InterpretedRun(
                        survey: survey, evaluationOrder: ordering, trials: 100, seed: 99)
                        .run(over: cells, names: NoNames())
                else { continue }

                for (ref, results) in first.outputs {
                    XCTAssertEqual(results.values, second.outputs[ref]?.values,
                                   "\(sheet.name)!\(ref.reference) did not reproduce")
                }
                checked += 1
            }
        }

        XCTAssertGreaterThan(checked, 0, "no real model was checked for reproducibility")
    }
}
