import Foundation
import SwiftExcelCore

/// Cells that depend, directly or through a chain, on themselves.
///
/// The analogue of the gate's `recursion` auditor, which finds a function that calls
/// itself with no base case. A spreadsheet's version is the same defect with no way to
/// write a base case at all: Excel refuses to evaluate it and shows `0` or a warning,
/// depending on the iterative-calculation setting — so a workbook can carry one silently
/// for years while every cell downstream reports a number.
///
/// It is the cheapest possible checker, which is why it is first:
/// `DependencyGraph.cycles` already computes the answer, so this reports rather than
/// analyses, and the whole path from file to finding gets exercised with nothing new to
/// get wrong.
public struct CircularReferenceChecker: WorkbookChecker {

    /// The name on every finding this makes.
    public static let name = "circular-reference"

    /// Structure only. No formula is evaluated to find a cycle — which is just as well,
    /// since evaluating one is what does not terminate.
    public static let requires: Requirement = .structure

    /// Creates the checker.
    public init() {}

    /// Reports every cycle the graph found.
    ///
    /// - Parameter model: the workbook and its dependency graph.
    /// - Returns: one finding per cycle, anchored at its earliest cell.
    public func check(_ model: AuditModel) -> [Finding] {
        model.graph.cycles.compactMap { cycle in
            // A cycle is reported once, at its earliest cell in reading order, rather than
            // once per member. Every cell in it is equally guilty and naming them all as
            // separate findings would turn one defect into ten.
            guard let anchor = cycle.min(by: {
                ($0.sheet, $0.cell.row, $0.cell.column) < ($1.sheet, $1.cell.row, $1.cell.column)
            }) else { return nil }

            let path = cycle
                .sorted { ($0.sheet, $0.cell.row, $0.cell.column) < ($1.sheet, $1.cell.row, $1.cell.column) }
                .map { "\($0.sheet)!\($0.cell.reference)" }
                .joined(separator: " → ")

            return Finding(
                checker: Self.name,
                severity: .error,
                address: anchor,
                summary: cycle.count == 1
                    ? "\(anchor.cell.reference) refers to itself"
                    : "\(cycle.count) cells depend on each other in a cycle",
                detail: """
                    Excel cannot evaluate a circular reference. Depending on the \
                    iterative-calculation setting it reports 0 or refuses, and either way \
                    every cell downstream of this reports a number that means nothing.
                    Cycle: \(path)
                    """,
                related: cycle.filter { $0 != anchor })
        }
    }
}
