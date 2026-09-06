import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// Every formula we can evaluate, checked against the value Excel recorded for it.
///
/// A saved workbook caches the result of every formula cell. That cache is the
/// strongest oracle this project has: produced by the specification itself, on
/// files written by people who were not thinking about us. It finds the cases
/// nobody would invent — the day-count bug that started this arrived because a
/// lease happened to begin on a leap day.
///
/// ## Each formula is judged alone
///
/// Precedents resolve to **Excel's** cached values, not to ours. So a formula is
/// evaluated against ground-truth inputs and its verdict is about that formula and
/// nothing else. There is no cascade to attribute: a wrong cell cannot poison its
/// dependents, because its dependents never see our answer.
///
/// This is a deliberate narrowing. It tests evaluation, not the model — a workbook
/// where every formula is individually right could still recalculate to something
/// different end to end. That is a separate check and belongs with the recalculation
/// work, not here.
///
/// ## Not a gate checker
///
/// This is a measurement. It needs private workbooks the repository cannot hold, so
/// it skips unless configured, and a checker that silently skips reports green —
/// which is worse than no checker. Individual findings graduate into ordinary
/// regression tests once they have a fixture small enough to commit, the way
/// `testTheFebruaryEndOfMonthRule` did.
///
/// ## Configuring it
///
/// Roots come from `BUSINESSMATHEXCEL_CORPUS` (colon-separated), or from an
/// `.excel-corpus` file found by walking up from the package. Either way the run is
/// opt-in — see ``corpusRoots()``.
final class ExcelOracleTests: XCTestCase {

    // MARK: - Volatility

    /// Functions whose value cannot be compared to a cached one.
    ///
    /// A cached `RAND()` records what Excel drew on some afternoon in 2013. Nothing
    /// we compute can match it and nothing should try, so these are excluded by name
    /// rather than by a tolerance wide enough to hide real defects.
    private static let volatile: Set<String> = [
        "RAND", "RANDBETWEEN", "RANDARRAY", "NOW", "TODAY", "OFFSET", "INDIRECT",
        "INFO", "CELL",
    ]

    /// Whether a function's cached value is a draw rather than an answer.
    ///
    /// Risk Solver's `Psi*` family is Monte Carlo. A cached `PsiTriangular(…)` is
    /// one sample from one simulation run, and `PsiMean(…)` or `PsiPercentile(…)`
    /// are statistics *of* that run — with no seed anybody published, so nothing can
    /// reproduce them. Excel writes the names as `_xll.PsiTriangular` when the
    /// add-in is not loaded, which is how they reach us.
    ///
    /// Counting these as disagreements would hold the agreement number down by
    /// something no amount of work could fix, which is the fastest way to make a
    /// measurement worth ignoring. They are excluded, and what they *can* tell us —
    /// which functions appear, with which argument shapes — is structural and is
    /// measured separately.
    ///
    /// - Parameter name: The function name, uppercased.
    /// - Returns: `true` when its value cannot be reproduced.
    private static func isStochastic(_ name: String) -> Bool {
        let bare = name.hasPrefix("_XLL.") ? String(name.dropFirst(5)) : name
        return bare.hasPrefix("PSI")
    }

    // MARK: - Reading Excel's answers

    /// A provider whose references resolve to the value Excel recorded.
    ///
    /// The two things that make the oracle meaningful. `resolved` turns a formula
    /// cell into its cached value, so a reference yields a value rather than the
    /// formula object — without it every reference to a computed cell is wrong.
    /// And because those values are Excel's, each formula is judged against inputs
    /// that are correct by definition.
    private struct ExcelCached: CellValueProvider {
        let inner: WorkbookValueProvider

        func value(at ref: CellRef) -> CellValue? { inner.value(at: ref)?.resolved }

        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? {
            inner.value(at: ref, inSheet: sheet)?.resolved
        }

        func lastPopulatedCell() -> CellRef? { inner.lastPopulatedCell() }

        func lastPopulatedCell(inSheet sheet: String) -> CellRef? {
            inner.lastPopulatedCell(inSheet: sheet)
        }

        func values(in range: CellRange) -> [CellValue] {
            inner.values(in: range).map(\.resolved)
        }

        func values(in range: CellRange, inSheet sheet: String) -> [CellValue] {
            inner.values(in: range, inSheet: sheet).map(\.resolved)
        }
    }

    // MARK: - Judging one workbook

    private func audit(_ workbook: Workbook) -> OracleReport {
        var report = OracleReport()
        for sheet in workbook.sheets {
            let cells = ExcelCached(
                inner: WorkbookValueProvider(workbook: workbook, currentSheet: sheet.name))
            for reference in sheet.cellReferences {
                guard case .formula(let ast, let cached)? = sheet.cell(at: reference) else {
                    continue
                }
                let cell = CellRef(reference)
                let outcome = judge(ast, cached: cached, cells: cells,
                                    names: workbook.namedRanges, sheet: sheet.name, cell: cell)
                report.record(OracleFinding(sheet: sheet.name, cell: cell,
                                            formula: ast, outcome: outcome))
            }
        }
        return report
    }

    private func judge(
        _ ast: FormulaAST, cached: CellValue?, cells: CellValueProvider,
        names: NameResolver, sheet: String, cell: CellRef
    ) -> OracleOutcome {
        // Markers the reader leaves for structure rather than for arithmetic.
        if case .function(let name, _) = ast,
           name == "_RAW" || name == "_ARRAY" || name == "_DATATABLE" {
            return .notComparable(name)
        }
        let named = Set(OracleFinding.functionNames(in: ast))
        if let volatile = named.first(where: { Self.volatile.contains($0) }) {
            return .notComparable("volatile: \(volatile)")
        }
        if let stochastic = named.first(where: { Self.isStochastic($0) }) {
            return .notComparable("stochastic: \(stochastic)")
        }
        guard let excel = cached else { return .notComparable("no cached value") }

        do {
            let ours = try FormulaEvaluator.evaluate(
                ast, cells: cells, names: names,
                at: CellAddress(sheet: sheet, cell: cell), inSheet: sheet)

            if case .error(let excelError) = excel {
                if case .error(let ourError) = ours, ourError == excelError {
                    return .agreedOnError(excelError)
                }
                return .differed(ours: ours, excel: excel)
            }
            // An iterative solver is compared against the band Excel documents for
            // itself, not against the general float tolerance.
            let tolerance = named.contains(where: {
                OracleTolerance.iterativeFunctions.contains($0)
            }) ? OracleTolerance.iterative : nil
            if OracleTolerance.agree(ours, excel, tolerance: tolerance) { return .agreed }
            if case .error(let kind) = ours { return .refused(kind) }
            return .differed(ours: ours, excel: excel)
        } catch {
            return .threw("\(error)")
        }
    }

    // MARK: - The measurement

    func testHowWellWeAgreeWithExcel() throws {
        let workbooks = try Self.corpusWorkbooks()
        var report = OracleReport()
        var read = 0

        for url in workbooks {
            guard let workbook = try? Workbook(contentsOf: url) else { continue }
            read += 1
            report.absorb(audit(workbook))
        }

        let tally = report.tally
        print("""
            ORACLE  workbooks read: \(read)
            ORACLE  comparable: \(report.comparable)
            ORACLE  agreement: \((report.agreement * 100).formatted(.number.precision(.fractionLength(2))))%
            ORACLE    agreed \(tally.agreed)  agreedOnError \(tally.agreedOnError)
            ORACLE    differed \(tally.differed)  refused \(tally.refused)  threw \(tally.threw)
            ORACLE    notComparable \(tally.notComparable)
            """)
        print("ORACLE  disagreements by function:")
        for (name, count) in report.byFunction.sorted(by: { $0.value > $1.value }).prefix(20) {
            print("ORACLE    \(count)  \(name)")
        }

        // A floor, not a target. It exists so that a change which halves agreement
        // fails loudly instead of being read past in a log.
        XCTAssertGreaterThan(report.agreement, 0.5,
                             "agreement collapsed; see the by-function list above")
    }

    /// The harness has to be able to see a defect we already know about.
    ///
    /// `Lease Renewal!L77` is `YEARFRAC(2020-02-29, 2020-12-31)`; Excel caches
    /// 301/360 and BusinessMath 2.9.0 computes 302/360. A run that reports this cell
    /// as agreeing is not measuring anything.
    ///
    /// It flips when BusinessMath ships the NASD February rule, which also proves
    /// the harness notices a fix and not only a break.
    func testTheHarnessSeesTheFebruaryDefect() throws {
        let roots = try Self.corpusRoots()
        let name = "Long Acre Team 2013 Probabilistic All.xlsx"
        guard let url = Self.find(name, under: roots) else {
            throw XCTSkip("\(name) is not in the configured roots")
        }
        let workbook = try Workbook(contentsOf: url)
        let report = audit(workbook)

        let cell = report.findings.first {
            $0.sheet == "Lease Renewal" && $0.cell.reference == "L77"
        }
        let finding = try XCTUnwrap(cell, "L77 was not audited")
        switch finding.outcome {
        case .differed(let ours, let excel):
            print("ORACLE  L77 ours \(ours) vs excel \(excel)   (expected, until 2.11.0)")
        case .agreed:
            print("ORACLE  L77 agrees — BusinessMath's February rule has landed")
        default:
            XCTFail("L77 was \(finding.outcome), which is neither agreement nor disagreement")
        }
    }

    /// What the corpus calls that we cannot answer.
    ///
    /// The oracle says how often we are *right*; this says what we are *missing*,
    /// which is the other half and the one that decides what to build next. A
    /// function absent from the registry answers `#NAME?` — so it never disagrees
    /// about a value, it just quietly fails, and the agreement number barely
    /// notices.
    ///
    /// Ordered by calls, because a name appearing four thousand times and a name
    /// appearing once are not the same piece of work. Workbook counts are printed
    /// beside them: something used once in forty workbooks is a different kind of
    /// important from something used four thousand times in one.
    func testWhatTheCorpusCallsThatWeCannotAnswer() throws {
        let workbooks = try Self.corpusWorkbooks()
        let registry = FunctionRegistry.builtin

        var calls: [String: Int] = [:]
        var books: [String: Set<String>] = [:]
        var read = 0

        for url in workbooks {
            guard let workbook = try? Workbook(contentsOf: url) else { continue }
            read += 1
            let name = url.lastPathComponent
            for sheet in workbook.sheets {
                for reference in sheet.cellReferences {
                    guard let ast = sheet.formulaAST(at: reference) else { continue }
                    for function in OracleFinding.functionNames(in: ast) {
                        guard registry.function(named: function) == nil else { continue }
                        guard !function.hasPrefix("_") else { continue }   // our own markers
                        calls[function, default: 0] += 1
                        books[function, default: []].insert(name)
                    }
                }
            }
        }

        print("ORACLE  workbooks read: \(read)")
        print("ORACLE  unanswerable function names: \(calls.count)")
        print("ORACLE  \("name".padding(toLength: 26, withPad: " ", startingAt: 0)) calls  books")
        for (function, count) in calls.sorted(by: { $0.value > $1.value }).prefix(40) {
            let padded = function.padding(toLength: 26, withPad: " ", startingAt: 0)
            print("ORACLE  \(padded) \(count)  \(books[function]?.count ?? 0)")
        }
    }

    // MARK: - Configuration

    /// Where the workbooks are, and whether we were asked to look.
    ///
    /// **Opt-in, and it has to be.** The roots are whole document trees, and reading
    /// every workbook under one takes minutes — the quality gate runs `swift test`,
    /// so a sweep that ran by default would tax every commit for a measurement
    /// nobody asked for at that moment.
    ///
    /// `BUSINESSMATHEXCEL_CORPUS` names the roots and enables the run in one go.
    /// `BUSINESSMATHEXCEL_ORACLE=1` enables it using the roots from `.excel-corpus`,
    /// which is where they are recorded so that nobody has to rediscover them.
    private static func corpusRoots() throws -> [String] {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["BUSINESSMATHEXCEL_CORPUS"], !configured.isEmpty {
            return configured.split(separator: ":").map(String.init)
        }
        guard let flag = environment["BUSINESSMATHEXCEL_ORACLE"],
              flag == "1" || flag.lowercased() == "true" else {
            throw XCTSkip("""
                The oracle is opt-in: it reads whole document trees and takes minutes. \
                Set BUSINESSMATHEXCEL_ORACLE=1 to run it against the roots in \
                .excel-corpus, or BUSINESSMATHEXCEL_CORPUS to a colon-separated list \
                of your own. The workbooks are private and are not in this repository.
                """)
        }
        guard let fromConfig = qualityGateRoots(), !fromConfig.isEmpty else {
            throw XCTSkip("BUSINESSMATHEXCEL_ORACLE is set but .excel-corpus names no roots")
        }
        return fromConfig
    }

    /// Reads the roots out of the nearest `.excel-corpus`.
    ///
    /// Its own file rather than a section of `.quality-gate.yml`: that file is the
    /// gate binary's schema, and it rejects keys it does not recognise — advisory
    /// today and an error later. Borrowing someone else's config file works right up
    /// until they validate it.
    private static func qualityGateRoots() -> [String]? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appendingPathComponent(".excel-corpus")
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                return roots(inFile: text)
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// - Parameter text: The file's contents.
    /// - Returns: The paths it names, or `nil` if it names none.
    static func roots(inFile text: String) -> [String]? {
        let found = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return found.isEmpty ? nil : found
    }

    private static func corpusWorkbooks() throws -> [URL] {
        let roots = try corpusRoots()
        var found: [URL] = []
        for root in roots {
            let expanded = NSString(string: root).expandingTildeInPath
            guard let walker = FileManager.default.enumerator(atPath: expanded) else { continue }
            for case let relative as String in walker where relative.hasSuffix(".xlsx") {
                if relative.contains("~$") { continue }
                found.append(URL(fileURLWithPath: expanded).appendingPathComponent(relative))
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    private static func find(_ name: String, under roots: [String]) -> URL? {
        for root in roots {
            let expanded = NSString(string: root).expandingTildeInPath
            guard let walker = FileManager.default.enumerator(atPath: expanded) else { continue }
            for case let relative as String in walker where relative.hasSuffix(name) {
                return URL(fileURLWithPath: expanded).appendingPathComponent(relative)
            }
        }
        return nil
    }
}
