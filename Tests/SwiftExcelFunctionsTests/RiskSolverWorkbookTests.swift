import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// The recognizer and surveyor, run against real Risk Solver workbooks.
///
/// Everything else testing this code uses formulas written for the purpose, which proves
/// only that the recognizer agrees with whoever wrote the test. These are models built by
/// people solving actual problems, saved by Frontline's own add-in, and they carry shapes
/// nobody would have thought to invent.
///
/// ## Running it
///
/// The workbooks are private coursework and are not in this repository. Point
/// `RISK_SOLVER_WORKBOOKS` at a directory to run against whatever it holds:
///
/// ```
/// RISK_SOLVER_WORKBOOKS="/path/to/models" swift test --filter RiskSolverWorkbook
/// ```
///
/// Skipped otherwise, on the same principle as `ExcelOracleTests` — a test that cannot
/// see its data reports that, rather than passing vacuously.
final class RiskSolverWorkbookTests: XCTestCase {

    private struct Model {
        let name: String
        let workbook: Workbook
    }

    /// Every `.xlsx` under the configured root that carries at least one `Psi` call.
    private func models() throws -> [Model] {
        let environment = ProcessInfo.processInfo.environment
        guard let root = environment["RISK_SOLVER_WORKBOOKS"], !root.isEmpty else {
            throw XCTSkip("""
                Set RISK_SOLVER_WORKBOOKS to a directory of Risk Solver models to run this.
                The workbooks are private and are not in this repository.
                """)
        }

        let url = URL(fileURLWithPath: root, isDirectory: true)
        let contents = (try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? []
        let paths = contents
            .filter { $0.hasSuffix(".xlsx") && !$0.hasPrefix("~$") }
            .sorted()

        var found: [Model] = []
        for path in paths {
            let fileURL = url.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: fileURL),
                  let workbook = try? Workbook(xlsxData: data) else { continue }
            if Self.carriesPsi(workbook) {
                found.append(Model(name: path, workbook: workbook))
            }
        }

        guard !found.isEmpty else {
            throw XCTSkip("RISK_SOLVER_WORKBOOKS is set but no workbook under it carries a Psi call")
        }
        return found
    }

    private static func carriesPsi(_ workbook: Workbook) -> Bool {
        for sheet in workbook.sheets {
            for ref in sheet.cellReferences where sheet.formulaAST(at: ref) != nil {
                if let ast = sheet.formulaAST(at: ref), containsPsi(ast) { return true }
            }
        }
        return false
    }

    private static func containsPsi(_ ast: FormulaAST) -> Bool {
        var carries = false
        PsiRecognizer.visitFunctionNames(ast) { name in
            if name.hasPrefix("PSI") { carries = true }
        }
        return carries
    }

    // MARK: - What the recognizer meets in the wild

    /// The census this prints is the Phase 2 work list, gathered early.
    ///
    /// It is deliberately not an assertion. What a real corpus contains is a fact to be
    /// discovered, and a test that asserted a particular census would fail the moment
    /// someone added a workbook — which is not a defect.
    func testCensusOfPsiFunctionsInTheWild() throws {
        var byFunction: [String: Int] = [:]
        var byWorkbook: [String: Set<String>] = [:]

        for model in try models() {
            for sheet in model.workbook.sheets {
                for ref in sheet.cellReferences {
                    guard let ast = sheet.formulaAST(at: ref) else { continue }
                    PsiRecognizer.visitFunctionNames(ast) { name in
                        guard name.hasPrefix("PSI") else { return }
                        byFunction[name, default: 0] += 1
                        byWorkbook[name, default: []].insert(model.name)
                    }
                }
            }
        }

        let rows = byFunction.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        var table = ""
        for (name, calls) in rows {
            let books = byWorkbook[name]?.count ?? 0
            table += "  \(name.padding(toLength: 22, withPad: " ", startingAt: 0))"
                + "\(calls) calls, \(books) workbook(s)\n"
        }
        print("\n── Psi census, real workbooks ──────────────────\n\(table)")
        XCTAssertFalse(rows.isEmpty)
    }

    /// **The claim that matters: nothing is silently misread.**
    ///
    /// Every `Psi` name a real workbook uses must be one this recognizer has classified —
    /// a marker, a registered distribution, or a property it reports by name. A name that
    /// is none of those is a name the surveyor would ignore entirely, and ignoring a
    /// `PsiMean` is how a model gets simulated with a statistic treated as a constant.
    func testEveryPsiNameInTheWildIsAccountedFor() throws {
        let distributions = Set(
            PsiRecognizer.defaultDistributions.map { FunctionRegistry.canonical($0.name) })
        var unaccounted: [String: Int] = [:]

        for model in try models() {
            for sheet in model.workbook.sheets {
                for ref in sheet.cellReferences {
                    guard let ast = sheet.formulaAST(at: ref) else { continue }
                    PsiRecognizer.visitFunctionNames(ast) { name in
                        guard name.hasPrefix("PSI") else { return }
                        guard !PsiRecognizer.markers.contains(name),
                              !distributions.contains(name) else { return }
                        unaccounted[name, default: 0] += 1
                    }
                }
            }
        }

        print("\n── Psi names this recognizer does not classify ──\n  "
              + (unaccounted.isEmpty ? "(none)"
                 : unaccounted.sorted { $0.value > $1.value }
                    .map { "\($0.key) × \($0.value)" }.joined(separator: "\n  "))
              + "\n")

        // Statistics are known-unclassified until §6.4's provider lands. They are the
        // read-out surface, not something the recognizer should treat as a draw, and
        // listing them here records what Phase 5 has to cover.
        let knownStatistics: Set<String> = [
            "PSIMEAN", "PSISTDDEV", "PSICVAR", "PSIBVAR", "PSITARGET", "PSIPERCENTILE"
        ]
        let surprises = unaccounted.keys.filter { !knownStatistics.contains($0) }.sorted()
        XCTAssertEqual(surprises, [],
                       "Psi names in the wild that are neither classified nor known statistics")
    }

    /// The surveyor, end to end, on every sheet of every model.
    ///
    /// Asserts the index contract rather than any particular model's shape: contiguous
    /// from zero, and one index per call site.
    func testSurveyorAssignsAContiguousIndexPerCallSite() throws {
        let surveyor = ModelSurveyor()
        var simulable = 0

        for model in try models() {
            for sheet in model.workbook.sheets {
                let survey = surveyor.survey(SheetProvider(sheet: sheet))
                XCTAssertEqual(
                    survey.uncertain.map(\.inputIndex), Array(0..<survey.uncertain.count),
                    "\(model.name) / \(sheet.name): indices are not contiguous from zero")
                if survey.isSimulable { simulable += 1 }

                if !survey.isFullyModelled {
                    print("  \(model.name) / \(sheet.name): unmodelled "
                          + "\(survey.unhandledProperties.values.flatMap { $0 }.sorted())")
                }
            }
        }
        print("\n── \(simulable) sheet(s) surveyed as simulable ──\n")
    }

    /// Adapts one `Worksheet` to the provider the surveyor reads.
    private struct SheetProvider: CellValueProvider, PopulatedCellProvider {
        func populatedCells() -> [CellRef] { sheet.cellReferences.map { CellRef($0) } }

        let sheet: Worksheet

        func value(at ref: CellRef) -> CellValue? {
            guard let ast = sheet.formulaAST(at: ref.reference) else { return nil }
            return .formula(ast, cached: nil)
        }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { value(at: ref) }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
        func lastPopulatedCell() -> CellRef? {
            let refs = sheet.cellReferences.map { CellRef($0) }
            guard let maxColumn = refs.map(\.column).max(),
                  let maxRow = refs.map(\.row).max() else { return nil }
            return CellRef(column: maxColumn, row: maxRow)
        }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
    }
}
