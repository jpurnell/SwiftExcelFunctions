import Foundation
import SwiftExcelCore
import BusinessMath

/// Risk Solver's read-out surface — the statistics of a completed run.
///
/// Measured across six real Risk Solver workbooks, these are **70 of 314** `Psi` calls:
/// about a fifth of everything the family is used for. They are not a tail.
///
/// ## What makes them different from every other function here
///
/// Every other function in this package computes from values. These compute from a *run*.
/// `PsiMean(B4)` names a vector across trials, not a cell's value, so it reads through
/// ``SimulationResultProvider`` — supplied by the caller, exactly as cell values are.
///
/// The consequence is that they answer `#N/A` when nothing has been simulated, which is
/// what Risk Solver shows before a run. A statistic is not a number a workbook always has.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinRiskSolverStatistics.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinRiskSolverStatistics {

    /// All statistics for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] =
        [psiMean, psiStdDev, psiPercentile, psiTarget, psiXtoP, psiBVaR, psiCVaR]

    // MARK: - Reading the run

    /// The run for the cell an argument names, or an Excel error saying why not.
    ///
    /// Two failures, deliberately distinct. A statistic given something that is not a
    /// reference — `PsiMean(42)` — has been handed a value where an address was needed,
    /// and that is `#VALUE!`. A statistic naming a real cell that no run covers is
    /// `#N/A`: the question is well-formed and the answer is not available, which is the
    /// same thing Risk Solver reports before a simulation exists.
    enum RunLookup {
        /// The run, for the cell the first argument named.
        case found(SimulationResults)
        /// The first argument was not a reference — `#VALUE!`.
        case notAReference
        /// A well-formed question no run answers — `#N/A`.
        case noRun
    }

    static func run(_ context: EvaluationContext) -> RunLookup {
        guard let ref = context.referencedCell(at: 0) else { return .notAReference }
        guard let simulation = context.simulation,
              let results = simulation.results(for: ref) else { return .noRun }
        return .found(results)
    }

    /// Builds a statistic that reads one number off a completed run.
    ///
    /// - Parameters:
    ///   - name: the function's canonical name.
    ///   - maxArgs: its arity. Every statistic takes the cell first; extras are its own.
    ///   - read: the statistic itself, given the run and the evaluated arguments.
    static func statistic(
        _ name: String,
        maxArgs: Int?,
        read: @escaping @Sendable (SimulationResults, [CellValue]) -> CellValue
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 1, maxArgs: maxArgs) { context, values in
            switch run(context) {
            case .notAReference: return .error(.value)
            case .noRun: return .error(.na)
            case .found(let results): return read(results, values)
            }
        }
    }

    // MARK: - The statistics

    /// `PsiMean(cell)` — the mean of a completed run. 28 calls across 5 real workbooks.
    public static let psiMean = statistic("PSIMEAN", maxArgs: 2) { results, _ in
        .number(results.statistics.mean)
    }

    /// `PsiStdDev(cell)` — the standard deviation of a completed run.
    ///
    /// The **sample** standard deviation, which is what `SimulationStatistics` computes
    /// and what a finite set of trials estimating an unknown population wants. 12 calls
    /// across 2 real workbooks.
    public static let psiStdDev = statistic("PSISTDDEV", maxArgs: 2) { results, _ in
        .number(results.statistics.stdDev)
    }

    /// `PsiPercentile(cell, p)` — the value at probability `p` of a completed run.
    ///
    /// `p` is a **fraction**, as Frontline documents: `0.95`, not `95`. A value outside
    /// `[0, 1]` is `#NUM!` rather than a clamp to the nearest end — Excel's answer for a
    /// computation that has no result, and the alternative would return the maximum for
    /// `1.5` as though it had been asked something meaningful. 10 calls in 1 workbook.
    public static let psiPercentile = statistic("PSIPERCENTILE", maxArgs: 3) { results, values in
        guard values.count >= 2, case .number(let p) = values[1] else { return .error(.value) }
        guard p >= 0, p <= 1 else { return .error(.num) }
        return .number(results.percentiles.percentile(p))
    }
}

// MARK: - Cumulative probability and risk

extension BuiltinRiskSolverStatistics {

    /// The proportion of a run at or below a threshold.
    ///
    /// **Not `SimulationResults.probabilityBelow`, deliberately.** That counts strictly
    /// `<`, and Frontline documents `PsiTarget` as *"the proportion of simulated values
    /// for cell that are less than or **equal to** target value."*
    ///
    /// On a continuous output the difference is measure-zero and invisible. On a discrete
    /// one it is the entire probability mass at the boundary — and `PsiBernoulli` is 55 of
    /// the 314 Psi calls across six real workbooks, so discrete outputs are the common
    /// case here rather than the edge case. `PsiTarget(cell, 0)` on a Bernoulli output
    /// would answer 0.0 instead of the proportion of failures.
    ///
    /// This is not a second implementation of an upstream function; it is a different
    /// predicate, and upstream has no inclusive form to delegate to. Recorded so that if
    /// one appears, this is the call site to replace.
    static func proportionAtOrBelow(_ threshold: Double, of results: SimulationResults) -> Double {
        let values = results.values
        guard !values.isEmpty else { return 0 }
        return Double(values.filter { $0 <= threshold }.count) / Double(values.count)
    }

    /// `PsiTarget(cell, x)` — the cumulative probability at `x`. 7 calls across 3 workbooks.
    ///
    /// The coverage matrix recorded this as `probabilityAbove`, which is the complement of
    /// what Frontline documents. Binding that would have returned a number in `[0, 1]`
    /// that is plausible, wrong, and reported by nothing.
    public static let psiTarget = statistic("PSITARGET", maxArgs: 3) { results, values in
        guard values.count >= 2, case .number(let target) = values[1] else { return .error(.value) }
        return .number(proportionAtOrBelow(target, of: results))
    }

    /// `PsiXtoP(cell, x)` — `PsiTarget` under another name.
    ///
    /// Frontline documents the two as interchangeable, with identical arguments. Bound
    /// through the same closure rather than duplicated, so they cannot drift apart.
    public static let psiXtoP = statistic("PSIXTOP", maxArgs: 3) { results, values in
        guard values.count >= 2, case .number(let target) = values[1] else { return .error(.value) }
        return .number(proportionAtOrBelow(target, of: results))
    }

    /// `PsiBVaR(cell, confidence)` — Value at Risk, losses reported **positive**.
    ///
    /// The "B" is for Basel, distinguishing it from the Premium Solver Platform's
    /// `PsiVar()`. Frontline: `PsiBVaR(A1, 0.95)` equals `−PsiPercentile(A1, 0.05)`.
    ///
    /// `SimulationResults.valueAtRisk(confidenceLevel:)` returns the raw percentile — its
    /// own documentation prints `abs(var999)` — so the negation happens here. That is
    /// where `master_plan.md` puts every sign convention: *"BusinessMath returns positive
    /// where Excel returns negative, and the flip belongs in the translation, not the
    /// mathematics."*
    ///
    /// Confidence outside `[0, 1]` is `#NUM!`, as with ``psiPercentile``.
    public static let psiBVaR = statistic("PSIBVAR", maxArgs: 3) { results, values in
        guard values.count >= 2, case .number(let confidence) = values[1] else {
            return .error(.value)
        }
        guard confidence >= 0, confidence <= 1 else { return .error(.num) }
        return .number(-results.valueAtRisk(confidenceLevel: confidence))
    }
}

// MARK: - Conditional Value at Risk

extension BuiltinRiskSolverStatistics {

    /// `PsiCVaR(cell, percentile)` — the mean of the loss tail, reported positive.
    ///
    /// Frontline defines it as *"the negative of the mean value of the specified uncertain
    /// function for the trials that lie between PsiMin(cell) and
    /// PsiPercentile(cell, 1-percentile), **inclusive**"*, and *"like PsiBVaR, PsiCVaR
    /// returns a loss as a positive number."*
    ///
    /// ## Why this delegates where ``psiTarget`` does not
    ///
    /// `SimulationResults.conditionalValueAtRisk(confidenceLevel:)` selects its tail as
    /// `values.filter { $0 <= varThreshold }` — **by value, and inclusive** — which is
    /// Frontline's definition exactly. A description of it as taking the worst
    /// `ceil(n × (1 − confidence))` sorted values would imply a count-based tail that
    /// disagrees whenever trials tie at the boundary, and discrete outputs tie constantly.
    /// The body does not do that, so there is nothing to work around and the mathematics
    /// stays upstream where it belongs.
    ///
    /// This is the opposite finding to `proportionAtOrBelow`, and both came from reading
    /// the implementation rather than its name: one function was wrong where it looked
    /// right, and this one is right where it was reported wrong.
    ///
    /// Only the sign differs, and the flip belongs here — the same rule ``psiBVaR``
    /// follows.
    public static let psiCVaR = statistic("PSICVAR", maxArgs: 3) { results, values in
        guard values.count >= 2, case .number(let percentile) = values[1] else {
            return .error(.value)
        }
        guard percentile >= 0, percentile <= 1 else { return .error(.num) }
        return .number(-results.conditionalValueAtRisk(confidenceLevel: percentile))
    }
}
