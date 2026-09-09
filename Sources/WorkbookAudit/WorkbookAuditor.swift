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
    /// One, for now. `PROPOSAL_workbook_validator.md` §9 puts the false-positive census
    /// before the second one deliberately: a checker firing on 80% of real models is wrong
    /// about what it measures whatever its logic says, and one built without that number
    /// ships noisy and gets switched off.
    public static let standard: [any WorkbookChecker] = [CircularReferenceChecker()]

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
