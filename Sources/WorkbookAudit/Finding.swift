import Foundation
import SwiftExcelCore

/// Something a checker found in a workbook.
///
/// ## Findings carry their reasoning
///
/// A borrowed habit, and the one that decides whether anyone acts on the output. The
/// quality gate does not say "inconsistent"; it says what was compared against what and
/// how they differed. The most valuable findings here are *comparative* — "this cell
/// differs from the eleven beside it" is only actionable if it names the eleven — which is
/// what ``related`` is for.
public struct Finding: Sendable, Equatable {

    /// How much it matters.
    public enum Severity: String, Sendable, Equatable, Comparable {
        /// The model is wrong, and Excel would say so too.
        case error
        /// The model is suspect. A human decides.
        case warning
        /// Worth knowing, not worth fixing.
        case note

        private var rank: Int {
            switch self {
            case .error: return 0
            case .warning: return 1
            case .note: return 2
            }
        }

        /// Orders severities worst first.
        /// - Parameters:
        ///   - lhs: the left severity.
        ///   - rhs: the right severity.
        /// - Returns: `true` if `lhs` is more severe.
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    /// Which checker found it.
    public let checker: String

    /// How much it matters.
    public let severity: Severity

    /// The cell it is about.
    public let address: CellAddress

    /// One line, in a person's terms.
    public let summary: String

    /// The reasoning, when it needs one.
    public let detail: String?

    /// The other cells this finding is about — the cycle it runs through, the neighbours
    /// it disagrees with. Empty when the finding stands alone.
    public let related: [CellAddress]

    /// Creates a finding.
    ///
    /// - Parameters:
    ///   - checker: the checker's name.
    ///   - severity: how much it matters.
    ///   - address: the cell it is about.
    ///   - summary: one line, in a person's terms.
    ///   - detail: the reasoning, when it needs one.
    ///   - related: the other cells involved.
    public init(
        checker: String,
        severity: Severity,
        address: CellAddress,
        summary: String,
        detail: String? = nil,
        related: [CellAddress] = []
    ) {
        self.checker = checker
        self.severity = severity
        self.address = address
        self.summary = summary
        self.detail = detail
        self.related = related
    }
}

extension Finding {
    /// Sort order for a report: worst first, then by where it is.
    ///
    /// Total and deterministic, because a validator whose output moves between runs on one
    /// unchanged workbook cannot be diffed in CI, and a validator nobody can diff is one
    /// nobody wires up.
    static func precedes(_ lhs: Finding, _ rhs: Finding) -> Bool {
        if lhs.severity != rhs.severity { return lhs.severity < rhs.severity }
        if lhs.address.sheet != rhs.address.sheet { return lhs.address.sheet < rhs.address.sheet }
        if lhs.address.cell.row != rhs.address.cell.row {
            return lhs.address.cell.row < rhs.address.cell.row
        }
        if lhs.address.cell.column != rhs.address.cell.column {
            return lhs.address.cell.column < rhs.address.cell.column
        }
        return lhs.checker < rhs.checker
    }
}
