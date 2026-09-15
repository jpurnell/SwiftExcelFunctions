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
    ///
    /// **Built when a checker asks for it, not before.** The graph is the expensive part of
    /// assembling a model — every formula's precedents, over every populated cell — and not
    /// every checker needs it. ``StaleValueChecker`` judges each formula against Excel's own
    /// cached inputs and so needs no precedent order at all; measured on a corpus, building
    /// the graph anyway was most of the run.
    ///
    /// Built at most once and shared, so ten structural checkers still build one graph
    /// between them, which is what the model exists for.
    public var graph: DependencyGraph { lazyGraph.value }

    private let lazyGraph: LazyGraph

    /// The workbook itself, for the checks that cannot work from addresses alone.
    ///
    /// Structural checks want the graph and nothing else, which is why they get a provider
    /// and a list of addresses. **Recomputation needs the file.** A value provider is bound
    /// to one sheet — an unqualified `B2` in a formula means B2 *on the formula's own
    /// sheet* — so every sheet needs its own provider, and only the workbook can supply
    /// them. Optional so that a model can still be assembled from parts in a test, and a
    /// checker that needs it says so rather than returning nothing.
    public let workbook: Workbook?

    /// Creates the model a checker sees.
    ///
    /// - Parameters:
    ///   - cells: the workbook's cells.
    ///   - addresses: every populated address.
    ///   - graph: the dependency graph over them.
    ///   - workbook: the workbook, for checks that recompute.
    public init(cells: any CellValueProvider, addresses: [CellAddress], graph: DependencyGraph,
                workbook: Workbook? = nil) {
        self.init(cells: cells, addresses: addresses, workbook: workbook) { graph }
    }

    /// Creates the model with a graph that is built only if something asks.
    ///
    /// - Parameters:
    ///   - cells: the workbook's cells.
    ///   - addresses: every populated address.
    ///   - workbook: the workbook, for checks that recompute.
    ///   - graph: how to build the dependency graph, called at most once.
    public init(cells: any CellValueProvider, addresses: [CellAddress],
                workbook: Workbook? = nil,
                graph: @escaping @Sendable () -> DependencyGraph) {
        self.cells = cells
        self.addresses = addresses
        self.workbook = workbook
        self.lazyGraph = LazyGraph(graph)
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

/// A dependency graph built on first use.
///
/// A reference type because ``AuditModel`` is a value passed to every checker in turn, and
/// the point is that they share one graph rather than each building their own.
// Justification: the lock makes every access to `cached` exclusive, which is the whole of this type's state.
final class LazyGraph: @unchecked Sendable {

    private let build: @Sendable () -> DependencyGraph
    private let lock = NSLock()
    private var cached: DependencyGraph?

    /// - Parameter build: how to produce the graph, called at most once.
    init(_ build: @escaping @Sendable () -> DependencyGraph) {
        self.build = build
    }

    /// The graph, building it the first time it is asked for.
    var value: DependencyGraph {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let graph = build()
        cached = graph
        return graph
    }
}
