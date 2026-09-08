import Foundation
import SwiftExcelCore
import BusinessMath

/// Where the `Psi*` statistics get a completed simulation run.
///
/// ## Why this exists
///
/// `PsiMean(B4)` cannot be a function of `B4`'s value. After a run, `B4` has ten thousand
/// values — the reference names a *vector across trials*, and no argument shape in Excel's
/// calculation model can carry one. The statistics are not functions of cells; they are
/// functions of a run, addressed by cell.
///
/// So they read through a provider the caller supplies, exactly as cell values do. That
/// symmetry is the point: ``FormulaEvaluator`` still holds no run, knows nothing about how
/// one was produced, and works unchanged for every caller who has none.
///
/// ## Before a run
///
/// A caller with no simulation supplies nothing, and every statistic answers `#N/A` —
/// which is what Risk Solver itself shows before a simulation has been run. Answering
/// zero, or the base case, would be a number a reader could mistake for a result.
///
/// ```swift
/// import SwiftExcelCore
/// import BusinessMath
///
/// struct OneCell: SimulationResultProvider {
///     let results: SimulationResults
///     func results(for ref: CellRef) -> SimulationResults? {
///         ref == CellRef("B4") ? results : nil
///     }
/// }
/// ```
public protocol SimulationResultProvider: Sendable {

    /// The completed run for a cell, or `nil` if this run does not cover it.
    ///
    /// `nil` is not an error. A run collects the cells a model marked with `PsiOutput()`,
    /// and a statistic asking about any other cell is asking a question the run did not
    /// answer — reported as `#N/A` rather than as a failure.
    func results(for ref: CellRef) -> SimulationResults?
}
