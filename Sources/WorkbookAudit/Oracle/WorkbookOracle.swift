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

    /// The same question, asked of the name table as well as the formula.
    ///
    /// **A formula can reach into another workbook without saying so.**
    /// `VLOOKUP(B157, month_lookup, 2, 0)` holds no bracketed sheet name anywhere in its AST;
    /// the bracket is in the name table, where `month_lookup` resolves to
    /// `[1]Definitions!$C$75:$E$86`. Walking the nodes alone therefore read the formula as
    /// ordinary, we answered `#N/A` having nothing to look in, and Excel's cached `"October"`
    /// counted against us — 216 cells in one corpus workbook, and a false accusation each.
    ///
    /// That is exactly the floor the simpler check was written to avoid, reached by the one
    /// path it did not walk.
    ///
    /// - Parameters:
    ///   - ast: The formula.
    ///   - names: The workbook's name table.
    ///   - sheet: The sheet the formula sits on, for sheet-scoped names.
    /// - Returns: A description of the first external reference found, or `nil`.
    public static func externalReference(
        in ast: FormulaAST, names: NameResolver, sheet: String
    ) -> String? {
        if let direct = externalReference(in: ast) { return direct }
        for node in OracleFinding.nodes(in: ast) {
            guard case .namedRange(let name) = node else { continue }
            guard let target = names.resolve(name, inSheet: sheet.isEmpty ? nil : sheet) else {
                continue
            }
            guard let external = externalSheet(of: target) else { continue }
            return "\(name) → \(external)"
        }
        return nil
    }

    /// The external sheet a name points at, if it points at one.
    private static func externalSheet(of target: NamedRangeTarget) -> String? {
        switch target {
        case .sheetCell(let reference), .sheetRange(let reference):
            return reference.sheetName.hasPrefix("[") ? reference.sheetName : nil
        case .formula(let ast):
            // A name can hold a formula, and that formula can reach outward too.
            return externalReference(in: ast)
        case .cell, .range, .unparsed:
            return nil
        }
    }

    /// A defined name in the formula that this package cannot turn into a reference.
    ///
    /// **A name the reader could not turn into a reference.** SwiftXLSX says so directly
    /// now, with `NamedRangeTarget.unparsed` — so this asks rather than infers.
    ///
    /// It used to have to infer. A whole-column name like `amounts = Expenditures!$D:$D`
    /// came back as `.formula(.text(…))`, indistinguishable by type from a name that really
    /// is a text constant, and telling them apart meant looking for a `!` and the absence of
    /// a quote. Both halves of that are fixed upstream in SwiftXLSX 0.26.0: whole columns
    /// parse, and what still cannot be read says so.
    ///
    /// What belongs here is unchanged — refusing to *judge* a formula we knowingly cannot
    /// evaluate. A cell we cannot compare is not a cell that disagrees.
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
            // The reader now *says* when it could not read a name, so this no longer has to
            // infer it from the shape of a text node. `.unparsed` is the statement itself.
            if case .unparsed = target { return name }
        }
        return nil
    }

    /// A whole-column or whole-row reference that a shared formula has shifted.
    ///
    /// **`C:C` has no row to offset.** Excel stores a column of identical formulas once and
    /// derives the rest by offset, and a whole-column reference is derived unchanged — every
    /// row of the shared range sees `C:C`. SwiftXLSX's expansion materialises it as
    /// `C1:C1048576` first and *then* offsets, so the formula in row 26 comes out as
    /// `C26:C1048601`: a window starting 25 rows too low, and reaching past the end of the
    /// sheet.
    ///
    /// Every position downstream is then wrong by the offset. `INDEX(MATCH(F165,C:C,0),,1)`
    /// answered `C206` where Excel answered `C231` — 112 cells in one corpus workbook, and
    /// a false accusation each.
    ///
    /// **Recognised by its shape, which is unambiguous.** A range spanning exactly
    /// 1,048,576 rows but not starting at row 1 cannot have been written by a person: it is
    /// a whole column that has been moved. The same for 16,384 columns not starting at
    /// column A.
    ///
    /// The expansion is upstream and is recorded rather than worked around. What belongs
    /// here is declining to judge a formula we know has been read wrongly.
    ///
    /// - Parameter ast: The formula.
    /// - Returns: The first such reference, written out, or `nil`.
    static func shiftedWholeReference(in ast: FormulaAST) -> String? {
        for node in OracleFinding.nodes(in: ast) {
            let range: CellRange
            switch node {
            case .cellRange(let found): range = found
            case .sheetRef(let found): range = found.range
            default: continue
            }
            if range.rowCount == CellRef.lastOnSheet.row, range.start.row > 1 {
                return "\(range.start.reference):\(range.end.reference)"
            }
            if range.columnCount == CellRef.lastOnSheet.column, range.start.column > 1 {
                return "\(range.start.reference):\(range.end.reference)"
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

        /// Every cell of the workbook, read once.
        let snapshot: WorkbookSnapshot

        /// Which sheet an unqualified reference means.
        let sheet: String

        func value(at ref: CellRef) -> CellValue? { value(at: ref, inSheet: sheet) }

        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? {
            Self.reading(snapshot.value(at: ref, inSheet: sheet))
        }

        func lastPopulatedCell() -> CellRef? { lastPopulatedCell(inSheet: sheet) }

        func lastPopulatedCell(inSheet sheet: String) -> CellRef? {
            snapshot.lastPopulatedCell(inSheet: sheet)
        }

        func values(in range: CellRange) -> [CellValue] { values(in: range, inSheet: sheet) }

        func values(in range: CellRange, inSheet sheet: String) -> [CellValue] {
            range.cells.compactMap { value(at: $0, inSheet: sheet) }
        }

        func matrix(in range: CellRange) -> CellMatrix { matrix(in: range, inSheet: sheet) }

        func matrix(in range: CellRange, inSheet sheet: String) -> CellMatrix {
            snapshot.matrix(in: range, inSheet: sheet) { Self.reading($0) }
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
    }

    /// Every cell of a workbook, in a dictionary, read once.
    ///
    /// **A measured 40× on one real file**, and the reason is worth stating because it is
    /// not obvious from the code that was replaced. `WorkbookValueProvider.value(at:)` finds
    /// its sheet by scanning `workbook.sheets` and comparing names, and it does that on
    /// *every cell read*. One `SUMIFS($F$2:$F$20001, $E$2:$E$20001, …)` reads 80,000 cells;
    /// a sheet of 126 of them reads ten million, each paying a linear scan over thirteen
    /// sheet names and a retain/release of the cell's style.
    ///
    /// The oracle reads the same cells thousands of times — that is what recomputing a
    /// workbook *is* — so it reads them once instead. `Name Analysis.xlsx` went from over
    /// three minutes to under five seconds.
    ///
    /// A snapshot is also the right shape for the job: the oracle judges each formula
    /// against the values Excel recorded, and those do not change while it runs.
    // Justification: every stored property is a `let` holding `Sendable` values, assigned once in `init` and never mutated.
    final class WorkbookSnapshot: @unchecked Sendable {

        private let cells: [String: [Int: CellValue]]
        private let corners: [String: CellRef?]

        // Justification: the lock makes every access to `rectangles` exclusive, and it is the only mutable state here.
        private let lock = NSLock()
        private var rectangles: [Key: CellMatrix] = [:]

        /// What identifies a rectangle that has already been read.
        private struct Key: Hashable {
            let sheet: String
            let start: Int
            let end: Int
        }

        /// Reads a workbook.
        ///
        /// - Parameter workbook: The workbook to snapshot.
        init(_ workbook: Workbook) {
            var cells: [String: [Int: CellValue]] = [:]
            var corners: [String: CellRef?] = [:]
            for sheet in workbook.sheets {
                var values: [Int: CellValue] = [:]
                values.reserveCapacity(sheet.cellReferences.count)
                for reference in sheet.cellReferences {
                    values[Self.key(CellRef(reference))] = sheet.cell(at: reference)
                }
                cells[sheet.name] = values
                corners[sheet.name] = sheet.lastPopulatedCell
            }
            self.cells = cells
            self.corners = corners
        }

        /// The value in a cell.
        ///
        /// - Parameters:
        ///   - ref: The cell.
        ///   - sheet: Which sheet it is on.
        /// - Returns: The value, or `nil` for an empty cell or an absent sheet.
        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? {
            cells[sheet]?[Self.key(ref)]
        }

        /// A cell's position as one integer.
        ///
        /// **Not its reference string.** Keying by `"$B$1"` meant building that string on
        /// every read — an integer-to-ASCII conversion and two small-string appends — and a
        /// single `SUMIFS` over four 20,000-row ranges does 80,000 reads. The profile was
        /// almost entirely `_BinaryIntegerToASCII`.
        ///
        /// The `$` markers are not part of a cell's identity, which is why a string key had
        /// to be normalised before use in the first place; a pair of integers never had
        /// them to lose.
        ///
        /// - Parameter ref: The cell.
        /// - Returns: A key unique within a sheet.
        static func key(_ ref: CellRef) -> Int {
            ref.row << 15 | ref.column
        }

        /// A rectangle of the sheet, read once however often it is asked for.
        ///
        /// **The oracle reads the same ranges thousands of times.** A column of 20,000
        /// `SUMIFS($F$2:$F$20001, $E$2:$E$20001, …)` formulas names the same four ranges in
        /// every row, and materialising each of them per formula is 1.6 billion cell copies
        /// for a workbook whose sheets hold 167,000 cells. Read once, it is 80,000.
        ///
        /// Bounded rather than unbounded: a run that walks a sheet of distinct ranges would
        /// otherwise keep every one of them. The cap is generous enough that the repeated
        /// ranges — which is what this exists for — all stay.
        ///
        /// - Parameters:
        ///   - range: The rectangle.
        ///   - sheet: Which sheet it is on.
        ///   - reading: How to read one cell, which is the oracle's own rule.
        /// - Returns: The rectangle, with absent cells as `.blank`.
        func matrix(in range: CellRange, inSheet sheet: String,
                    reading: (CellValue?) -> CellValue?) -> CellMatrix {
            guard let clipped = range.clipped(to: lastPopulatedCell(inSheet: sheet)) else {
                return CellMatrix(row: [])
            }
            let key = Key(sheet: sheet,
                          start: Self.key(clipped.start), end: Self.key(clipped.end))
            lock.lock()
            let cached = rectangles[key]
            lock.unlock()
            if let cached { return cached }

            var elements: [CellValue] = []
            elements.reserveCapacity(clipped.rowCount * clipped.columnCount)
            for row in clipped.start.row...clipped.end.row {
                for column in clipped.start.column...clipped.end.column {
                    let cell = CellRef(column: column, row: row)
                    elements.append(reading(value(at: cell, inSheet: sheet)) ?? .blank)
                }
            }
            let matrix = CellMatrix(elements: elements,
                                    rows: clipped.rowCount,
                                    columns: clipped.columnCount) ?? CellMatrix(row: [])
            lock.lock()
            if rectangles.count >= Self.cacheLimit { rectangles.removeAll(keepingCapacity: true) }
            rectangles[key] = matrix
            lock.unlock()
            return matrix
        }

        /// How many rectangles to keep before starting again.
        private static let cacheLimit = 256

        /// The far corner of a sheet.
        ///
        /// - Parameter sheet: The sheet's name.
        /// - Returns: Its last populated cell, or `nil` if it holds nothing.
        func lastPopulatedCell(inSheet sheet: String) -> CellRef? {
            corners[sheet] ?? nil
        }
    }

    // MARK: - Judging

    /// Judges every formula cell in a workbook.
    ///
    /// - Parameter workbook: The workbook to read.
    /// - Returns: A report over all its sheets.
    public static func audit(_ workbook: Workbook) -> OracleReport {
        var report = OracleReport()
        // Read once, for every sheet, before judging anything. See ``WorkbookSnapshot``.
        let snapshot = WorkbookSnapshot(workbook)
        for sheet in workbook.sheets {
            let cells = ExcelCached(snapshot: snapshot, sheet: sheet.name)
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
        if let external = externalReference(in: ast, names: names, sheet: sheet) {
            return .notComparable("external workbook: \(external)")
        }
        if let name = unresolvableName(in: ast, names: names, sheet: sheet) {
            return .notComparable("unresolved name: \(name)")
        }
        if let shifted = shiftedWholeReference(in: ast) {
            return .notComparable("shifted whole reference: \(shifted)")
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
            // **Implicit intersection is not modelled, so it is not judged.**
            //
            // `=annRevenue - annCost` where those names span fifteen columns is, in Excel's
            // pre-dynamic-array semantics, the *one* column that lines up with the formula's
            // own position. This package returns the whole row: the alignment needs the
            // array's origin on the sheet, and a `CellMatrix` does not carry one.
            //
            // Comparing the first element instead would be right one time in fifteen and
            // wrong the rest, and every one of those is a cell the checker would accuse a
            // workbook over. 214 of them in one corpus sweep.
            if case .array(let matrix) = ours, matrix.elements.count > 1 {
                if case .array = excel {} else {
                    return .notComparable("implicit intersection: \(matrix.rows)×\(matrix.columns)")
                }
            }
            // An iterative solver is compared against the band Excel documents for itself,
            // not against the general float tolerance.
            let tolerance = named.contains(where: {
                OracleTolerance.iterativeFunctions.contains($0)
            }) ? OracleTolerance.iterative : nil
            if OracleTolerance.agree(ours, excel, tolerance: tolerance) { return .agreed }
            if case .error(let kind) = ours { return .refused(kind, excel: excel) }
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
            return .threw("\(failure)", excel: excel)
        }
    }
}
