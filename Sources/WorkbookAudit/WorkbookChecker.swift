import Foundation
import SwiftExcelCore
import SwiftXLSX

/// What a checker needs before it can run.
///
/// The load-bearing part of the design. Structural checks are milliseconds; recomputing
/// every formula is a pass over the workbook; a simulation is thousands of passes. A run
/// that only wants `circular-reference` must not pay for a Monte Carlo, and the only way
/// to arrange that is for checkers to say what they need before the runner does any work.
public enum Requirement: Sendable, Equatable, Comparable {
    /// The formula trees and the dependency graph. Cheap.
    case structure
    /// The above, plus evaluating every formula once.
    case recomputation
    /// The above, plus a completed simulation run.
    case simulation

    private var rank: Int {
        switch self {
        case .structure: return 0
        case .recomputation: return 1
        case .simulation: return 2
        }
    }

    /// Orders requirements cheapest first.
    /// - Parameters:
    ///   - lhs: the left requirement.
    ///   - rhs: the right requirement.
    /// - Returns: `true` if `lhs` needs less work.
    public static func < (lhs: Requirement, rhs: Requirement) -> Bool { lhs.rank < rhs.rank }
}

/// What a checker is given.
///
/// Assembled once and shared, so ten structural checkers build one graph between them
/// rather than ten.
public struct AuditModel: Sendable {

    /// The workbook's cells, readable by address.
    public let cells: any CellValueProvider

    /// Every populated address, across every sheet.
    public let addresses: [CellAddress]

    /// The dependency graph over all of them — evaluation order, precedents, cycles.
    public let graph: DependencyGraph

    /// Creates the model a checker sees.
    ///
    /// - Parameters:
    ///   - cells: the workbook's cells.
    ///   - addresses: every populated address.
    ///   - graph: the dependency graph over them.
    public init(cells: any CellValueProvider, addresses: [CellAddress], graph: DependencyGraph) {
        self.cells = cells
        self.addresses = addresses
        self.graph = graph
    }
}

/// One kind of defect a workbook can have.
///
/// ## A checker that skips is not a checker that passed
///
/// Borrowed from the quality gate, and the failure mode this tool would otherwise fall
/// into constantly: so many checks depend on a model shape not every workbook has. A
/// checker that cannot run must say so, not return `[]` and let the run look clean.
public protocol WorkbookChecker: Sendable {

    /// The name that appears on every finding it makes.
    static var name: String { get }

    /// What it needs before it can run.
    static var requires: Requirement { get }

    /// Examines a workbook.
    ///
    /// - Parameter model: the workbook, its addresses, and its dependency graph.
    /// - Returns: what it found, in any order — the auditor sorts.
    func check(_ model: AuditModel) -> [Finding]
}
