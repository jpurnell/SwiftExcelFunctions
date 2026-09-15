import Foundation
#if canImport(os)
import os
#endif
import SwiftExcelCore
import SwiftExcelFunctions
import SwiftXLSX

/// Every formula in a workbook, checked against the value Excel recorded for it.
///
/// A saved workbook caches the result of every formula cell. That cache is the
/// strongest oracle this project has: produced by the specification itself, on files
/// written by people who were not thinking about us. It finds the cases nobody would
/// invent — the day-count bug that started this arrived because a lease happened to begin
/// on a leap day.
///
/// ## Each formula is judged alone
///
/// Precedents resolve to **Excel's** cached values, not to ours. So a formula is evaluated
/// against ground-truth inputs and its verdict is about that formula and nothing else. There
/// is no cascade to attribute: a wrong cell cannot poison its dependents, because its
/// dependents never see our answer.
///
/// ## Why this is a library and not a test
///
/// It was a test. An `XCTestCase` over 2,240 workbooks prints only at the end, cannot
/// resume, and gives no way to tell a working run from a hung one — the same three
/// properties that caused two abandoned attempts at the workbook census. A run against the
/// full corpus was killed at two and a half minutes having produced nothing at all, which is
/// what moved this here. The measurement is the same; what changed is that something else
/// can now drive it and report as it goes.
public enum WorkbookOracle {

    // MARK: - What cannot be compared

    /// Functions whose value cannot be compared to a cached one.
    ///
    /// A cached `RAND()` records what Excel drew on some afternoon in 2013. Nothing we
    /// compute can match it and nothing should try, so these are excluded by name rather
    /// than by a tolerance wide enough to hide real defects.
    public static let volatile: Set<String> = [
        "RAND", "RANDBETWEEN", "RANDARRAY", "NOW", "TODAY", "OFFSET", "INDIRECT",
        "INFO", "CELL",
    ]

    /// Whether a function's cached value is a draw rather than an answer.
    ///
    /// Risk Solver's `Psi*` family is Monte Carlo. A cached `PsiTriangular(…)` is one sample
    /// from one run, with no seed anybody published, so nothing can reproduce it. Excel
    /// writes the names as `_xll.PsiTriangular` when the add-in is not loaded.
    ///
    /// - Parameter name: The function name, uppercased.
    /// - Returns: `true` when its value cannot be reproduced.
    public static func isStochastic(_ name: String) -> Bool {
        let bare = name.hasPrefix("_XLL.") ? String(name.dropFirst(5)) : name
        return bare.hasPrefix("PSI")
    }

    /// Whether a formula reaches into another workbook.
    ///
    /// **Not a disagreement, and counting it as one put a floor under the failure rate that
    /// no amount of work could lift.** Excel writes an external reference as `[1]Sheet!A1`,
    /// where `[1]` indexes a workbook this one links to. The cached value is what that other
    /// file said when the link was last live; the file itself is not here, and often no
    /// longer exists anywhere. We answer `blank` because we have nothing to answer with, and
    /// the comparison is meaningless in both directions.
    ///
    /// Found by walking the tree rather than by matching text, because the marker is
    /// structural — a `sheetRef` whose sheet name is bracketed.
    ///
    /// - Parameter ast: The formula.
    /// - Returns: The first external sheet name found, or `nil`.
    public static func externalReference(in ast: FormulaAST) -> String? {
        for node in OracleFinding.nodes(in: ast) {
            if case .sheetRef(let reference) = node, reference.sheetName.hasPrefix("[") {
                return reference.sheetName
            }
        }
        return nil
    }

    /// A defined name in the formula that this package cannot turn into a reference.
    ///
    /// **A whole-column name does not resolve.** `amounts = Expenditures!$D:$D` is read by
    /// SwiftXLSX's `DefinedNameResolver` as an unparsed formula string, because its
    /// reference test requires a letter *and* a digit in each half and `$D` has no digit.
    /// The name then evaluates to its own text, and `SUMIFS(amounts, dates, …)` sums
    /// nothing — 1,058 cells in one corpus workbook, every one of which the checker was
    /// about to report as somebody's stale value.
    ///
    /// **The defect is upstream and is recorded rather than worked around**: the parser
    /// lives in SwiftXLSX and a second one here is exactly what the package split exists to
    /// prevent. What belongs here is refusing to *judge* a formula we knowingly cannot
    /// evaluate. A cell we cannot compare is not a cell that disagrees.
    ///
    /// A name whose target is a text *constant* is not this case: the file writes those
    /// quoted, so the quote is what tells the two apart.
    ///
    /// - Parameters:
    ///   - ast: The formula.
    ///   - names: The workbook's defined names.
    ///   - sheet: The sheet the formula is on, for a sheet-scoped name.
    /// - Returns: The first such name, or `nil`.
    static func unresolvableName(
        in ast: FormulaAST, names: NameResolver, sheet: String
    ) -> String? {
        for node in OracleFinding.nodes(in: ast) {
            guard case .namedRange(let name) = node else { continue }
            guard let target = names.resolve(name, inSheet: sheet.isEmpty ? nil : sheet) else {
                // No definition at all. Excel cached a value, so it resolved for Excel.
                return name
            }
            if case .formula(.text(let literal)) = target,
               literal.contains("!"), !literal.contains("\"") {
                return name
            }
        }
        return nil
    }

    // MARK: - Reading Excel's answers

    /// A provider whose references resolve to the value Excel recorded.
    ///
    /// The two things that make the oracle meaningful. `resolved` turns a formula cell into
    /// its cached value, so a reference yields a value rather than the formula object —
    /// without it every reference to a computed cell is wrong. And because those values are
    /// Excel's, each formula is judged against inputs that are correct by definition.
    struct ExcelCached: CellValueProvider {
        let inner: WorkbookValueProvider

        func value(at ref: CellRef) -> CellValue? { Self.reading(inner.value(at: ref)) }

        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? {
            Self.reading(inner.value(at: ref, inSheet: sheet))
        }

        /// What Excel recorded in a cell, read the way Excel reads it.
        ///
        /// `resolved` alone is not enough for one case, and it is a common one: **a cell
        /// holding a formula is never blank**, whatever the formula produced.
        ///
        /// ```xml
        /// <c r="G3" t="str"><f>IF(…,A3,"")</f><v/></c>
        /// ```
        ///
        /// That cell's result is the empty string, and `ISBLANK(G3)` is FALSE in Excel
        /// because there is a formula in it. `resolved` gives `.blank` — the reader cannot
        /// distinguish an empty `<v/>` from a `<v>` that is not there — so `ISBLANK`
        /// answered TRUE and **147 cells in one workbook** were reported as disagreeing
        /// with their own cached values.
        ///
        /// Found by the workbook checker on its first corpus run, which is what the census
        /// is for: they were about to be reported as defects in someone's spreadsheet.
        ///
        /// - Parameter value: The cell as the reader gives it.
        /// - Returns: The value a formula referring to that cell should see.
        static func reading(_ value: CellValue?) -> CellValue? {
            guard case .formula(_, let cached)? = value else { return value?.resolved }
            // An uncached formula cell is empty *text*, not an empty cell. The distinction
            // only matters to the handful of functions that ask — `ISBLANK`, `COUNTA`,
            // `COUNTBLANK` — and it matters completely to those.
            return cached ?? .text("")
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

    // MARK: - Judging

    /// Judges every formula cell in a workbook.
    ///
    /// - Parameter workbook: The workbook to read.
    /// - Returns: A report over all its sheets.
    public static func audit(_ workbook: Workbook) -> OracleReport {
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

    /// Judges one formula against the value Excel cached for it.
    ///
    /// - Parameters:
    ///   - ast: The formula.
    ///   - cached: What Excel last computed for it.
    ///   - cells: A provider resolving references to Excel's own values.
    ///   - names: The workbook's defined names.
    ///   - sheet: The sheet the formula is on.
    ///   - cell: The cell it occupies.
    /// - Returns: The verdict.
    public static func judge(
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
        if let external = externalReference(in: ast) {
            return .notComparable("external workbook: \(external)")
        }
        if let name = unresolvableName(in: ast, names: names, sheet: sheet) {
            return .notComparable("unresolved name: \(name)")
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
            // An iterative solver is compared against the band Excel documents for itself,
            // not against the general float tolerance.
            let tolerance = named.contains(where: {
                OracleTolerance.iterativeFunctions.contains($0)
            }) ? OracleTolerance.iterative : nil
            if OracleTolerance.agree(ours, excel, tolerance: tolerance) { return .agreed }
            if case .error(let kind) = ours { return .refused(kind) }
            return .differed(ours: ours, excel: excel)
        } catch let failure {
            // The throw is carried in the outcome and counted, but it is logged too. A
            // swallowed error that only ever appears as a tally is one nobody can debug
            // from, and the volume is bearable: seven throws in forty-six workbooks, so a
            // few hundred across a corpus of two thousand.
            #if canImport(os)
            Logger(subsystem: "WorkbookAudit", category: "oracle")
                .error("\(sheet, privacy: .public)!\(cell.reference, privacy: .public) threw: \(String(describing: failure), privacy: .public)")
            #endif
            return .threw("\(failure)")
        }
    }
}
