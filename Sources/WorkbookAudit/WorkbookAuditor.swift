import Foundation
import SwiftExcelCore
import SwiftXLSX

/// Runs checkers over a workbook and collects what they find.
///
/// ```swift
/// import SwiftXLSX
///
/// func audit(_ workbook: Workbook) -> [Finding] {
///     WorkbookAuditor().audit(workbook)
/// }
/// ```
public struct WorkbookAuditor: Sendable {

    private let checkers: [any WorkbookChecker]

    /// - Parameter checkers: the checks to run. Defaults to every one that is ready.
    public init(checkers: [any WorkbookChecker] = WorkbookAuditor.standard) {
        self.checkers = checkers
    }

    /// The checkers that ship enabled.
    ///
    /// Each one lands with a census number. `PROPOSAL_workbook_validator.md` §9 puts the
    /// false-positive count before the *next* checker deliberately: one firing on 80% of
    /// real models is wrong about what it measures whatever its logic says, and one built
    /// without that number ships noisy and gets switched off.
    public static let standard: [any WorkbookChecker] = [CircularReferenceChecker()]

    /// Checkers that work but have not earned a default yet.
    ///
    /// ``ConsistencyChecker`` is here rather than in ``standard``, and the reason is the
    /// census rather than a doubt about its logic. It **finds real defects** — in one real
    /// model, `E19 = E17*E18*D13` where every neighbour reads `E13`, the classic copy that
    /// mixed a column, alongside a `B19` that duplicates `C19` without shifting. Those are
    /// exactly the errors it exists to catch and a person reading the sheet would not see
    /// them.
    ///
    /// It also produced **249 findings across 33% of six real workbooks**, and
    /// `PROPOSAL_workbook_validator.md` §9 is explicit that this is the number that
    /// decides: a checker firing on a third of real models is measuring something broader
    /// than it claims, and shipping it enabled is how a validator gets switched off
    /// wholesale — taking the checker that *was* right down with it.
    ///
    /// So it ships opt-in until the rate comes down. Available to anyone who wants it,
    /// default to no one.
    ///
    /// ```swift
    /// WorkbookAuditor(checkers: WorkbookAuditor.standard + WorkbookAuditor.experimental)
    /// ```
    public static let experimental: [any WorkbookChecker] = [ConsistencyChecker()]

    /// Audits a workbook.
    ///
    /// - Parameter workbook: the workbook to examine.
    /// - Returns: every finding, worst first and then in reading order.
    public func audit(_ workbook: Workbook) -> [Finding] {
        let model = Self.model(of: workbook)
        return checkers
            .flatMap { $0.check(model) }
            .sorted(by: Finding.precedes)
    }

    /// Assembles what every checker sees, once.
    ///
    /// The graph is built over the **whole workbook** rather than a sheet at a time.
    /// Measured on real models, 2 of 6 are cross-sheet and the largest has 69% of its
    /// formulas referencing another sheet — and a per-sheet graph drops an out-of-scope
    /// reference *along with its edge*, which would silently hide every cycle that closes
    /// across two sheets.
    static func model(of workbook: Workbook) -> AuditModel {
        var addresses: [CellAddress] = []
        for sheet in workbook.sheets {
            for reference in sheet.cellReferences {
                addresses.append(CellAddress(sheet: sheet.name, ref: reference))
            }
        }
        addresses.sort { ($0.sheet, $0.cell.row, $0.cell.column) < ($1.sheet, $1.cell.row, $1.cell.column) }

        let provider = WorkbookValueProvider(
            workbook: workbook, currentSheet: workbook.sheets.first?.name ?? "")

        return AuditModel(
            cells: provider,
            addresses: addresses,
            graph: DependencyGraph(cells: addresses, provider: provider))
    }
}
