import Foundation
import SwiftExcelCore
import BusinessMath

/// The `Psi*` statistics that are functions of a completed run's **values**.
///
/// ``BuiltinRiskSolverStatistics`` holds the seven that a corpus workbook actually calls.
/// These are the rest of the ones that need nothing but the trial values — the engine for
/// them has existed since `SimulationResultProvider` landed, and what was missing was the
/// arithmetic.
///
/// ## These cannot be measured the way Excel's functions are
///
/// Every other convention in this package was settled by asking Excel: write the formula into
/// a workbook, open it, read the answer back. **That does not work here.** `Psi*` functions
/// come from Frontline's Analytic Solver add-in; a workbook containing them opens without it
/// and every cell reads `#NAME?`. The conformance workbook can measure Excel and cannot
/// measure an add-in nobody has installed.
///
/// So these rest on Frontline's published documentation — and this project's own record is
/// that documentation has been wrong **seven** times. Each definition below therefore states
/// the convention it chose in words, so that a later measurement has something specific to
/// contradict. Two are worth naming up front because a reader will assume the other answer:
///
/// - **`PsiKurtosis` is not excess kurtosis.** Frontline reports 3 for a normal, so this adds
///   3 to BusinessMath's `kurtosis(_:_:)`, which reports 0. A statistic that is out by exactly
///   3 looks like an ordinary number.
/// - **Sample, not population**, throughout, matching `PsiStdDev` — a finite set of trials is
///   estimating something it cannot see.
///
/// **Zero of these appear in the corpus.** Neither did the 87 EXCEL rows that closed the
/// unreviewed bucket; the case is completeness, which is a weaker argument and is worth
/// saying before the work rather than after.
public enum BuiltinRiskSolverRunStatistics {

    /// Everything here, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        psiVariance, psiSkewness, psiKurtosis, psiRange, psiCount,
        psiAbsDev, psiCoeffVar, psiStdErr,
        psiSemiVar, psiSemiDev, psiSemiVar2, psiSemiDev2,
        psiData, psiFrequency, psiExpGain, psiExpLoss
    ]

    // MARK: - Shape

    /// The second argument as a number, for the statistics that take a target.
    private static func real(_ values: [CellValue], at index: Int) -> Double? {
        guard values.count > index else { return nil }
        switch values[index] {
        case .number(let d): return d.isFinite ? d : nil
        case .bool(let flag): return flag ? 1 : 0
        default: return nil
        }
    }

    // MARK: - Moments

    /// `PsiVariance(cell)` — the sample variance of a completed run.
    public static let psiVariance = BuiltinRiskSolverStatistics.statistic(
        "PSIVARIANCE", maxArgs: 2
    ) { results, _ in .number(results.statistics.variance) }

    /// `PsiSkewness(cell)` — the sample skewness of a completed run.
    ///
    /// Zero for a symmetric run. Positive means the long tail is to the right, which is the
    /// usual shape of a cost or a duration.
    public static let psiSkewness = BuiltinRiskSolverStatistics.statistic(
        "PSISKEWNESS", maxArgs: 2
    ) { results, _ in .number(results.statistics.skewness) }

    /// `PsiKurtosis(cell)` — kurtosis, **not excess kurtosis**.
    ///
    /// A normal distribution reports **3**, which is Frontline's convention and the older of
    /// the two in general use. BusinessMath's `kurtosis(_:_:)` reports excess kurtosis — 0 for
    /// a normal — so 3 is added here and the addition is the whole content of this function.
    ///
    /// Stated at length because the two conventions differ by exactly 3, and a heavy-tailed
    /// run reporting 4.2 where the caller expected 1.2 is a plausible number either way.
    public static let psiKurtosis = BuiltinRiskSolverStatistics.statistic(
        "PSIKURTOSIS", maxArgs: 2
    ) { results, _ in
        let excess: Double = kurtosis(results.values, .sample)
        guard excess.isFinite else { return .error(.num) }
        return .number(excess + 3)
    }

    // MARK: - Spread

    /// `PsiRange(cell)` — the largest trial value minus the smallest.
    public static let psiRange = BuiltinRiskSolverStatistics.statistic(
        "PSIRANGE", maxArgs: 2
    ) { results, _ in .number(results.statistics.max - results.statistics.min) }

    /// `PsiCount(cell)` — how many trials the run recorded.
    ///
    /// The number of *trials*, not of distinct values: a run that drew the same number twice
    /// counted two trials, and a statistic that collapsed them would misreport every other
    /// statistic's denominator.
    public static let psiCount = BuiltinRiskSolverStatistics.statistic(
        "PSICOUNT", maxArgs: 2
    ) { results, _ in .number(Double(results.values.count)) }

    /// `PsiAbsDev(cell)` — the mean absolute deviation about the mean.
    ///
    /// The average distance from the mean, in the units of the output. Unlike a standard
    /// deviation it does not square, so one extreme trial moves it far less — which is the
    /// reason to ask for it.
    public static let psiAbsDev = BuiltinRiskSolverStatistics.statistic(
        "PSIABSDEV", maxArgs: 2
    ) { results, _ in
        let values = results.values
        guard !values.isEmpty else { return .error(.num) }
        let mean = results.statistics.mean
        let total = values.reduce(0.0) { $0 + Swift.abs($1 - mean) }
        return .number(total / Double(values.count))
    }

    /// `PsiCoeffVar(cell)` — the coefficient of variation, `σ/μ`.
    ///
    /// Dimensionless, which is what makes two outputs on different scales comparable. `#DIV/0!`
    /// at a mean of zero rather than an infinity: the ratio genuinely has no value there, and a
    /// cell cannot hold one.
    public static let psiCoeffVar = BuiltinRiskSolverStatistics.statistic(
        "PSICOEFFVAR", maxArgs: 2
    ) { results, _ in
        let mean = results.statistics.mean
        guard mean != 0 else { return .error(.div0) }
        return .number(results.statistics.stdDev / mean)
    }

    /// `PsiStdErr(cell)` — the standard error of the mean, `σ/√n`.
    ///
    /// How much the *mean* would move if the run were repeated — not how much a trial moves,
    /// which is `PsiStdDev`. It is the statistic that says whether another ten thousand trials
    /// would change the answer.
    public static let psiStdErr = BuiltinRiskSolverStatistics.statistic(
        "PSISTDERR", maxArgs: 2
    ) { results, _ in
        let count = results.values.count
        guard count > 0 else { return .error(.num) }
        return .number(results.statistics.stdDev / Double(count).squareRoot())
    }

    // MARK: - Downside

    /// Semi-variance below a threshold: the mean squared shortfall, over **all** trials.
    ///
    /// Dividing by the full count rather than by the number of trials that fell short is the
    /// choice that makes this comparable with the variance beside it. Dividing by the
    /// shortfall count answers a different question — how bad a bad trial is, rather than how
    /// much downside the distribution carries — and the two differ by a factor of the
    /// shortfall rate, which is not a rounding.
    private static func semiVariance(_ values: [Double], below threshold: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let total = values.reduce(0.0) { running, value in
            guard value < threshold else { return running }
            let shortfall = threshold - value
            return running + shortfall * shortfall
        }
        return total / Double(values.count)
    }

    /// `PsiSemiVar(cell)` — semi-variance below the **mean**.
    public static let psiSemiVar = BuiltinRiskSolverStatistics.statistic(
        "PSISEMIVAR", maxArgs: 2
    ) { results, _ in
        guard let value = semiVariance(results.values, below: results.statistics.mean) else {
            return .error(.num)
        }
        return .number(value)
    }

    /// `PsiSemiDev(cell)` — semi-deviation below the mean, the root of ``psiSemiVar``.
    public static let psiSemiDev = BuiltinRiskSolverStatistics.statistic(
        "PSISEMIDEV", maxArgs: 2
    ) { results, _ in
        guard let value = semiVariance(results.values, below: results.statistics.mean) else {
            return .error(.num)
        }
        return .number(value.squareRoot())
    }

    /// `PsiSemiVar2(cell, target)` — semi-variance below a **stated** target.
    ///
    /// The same measure as ``psiSemiVar`` against a number the model chose rather than against
    /// the mean: a budget, a covenant, a service level. Without the target this is `#VALUE!`
    /// rather than a silent fallback to the mean, which would answer a different question
    /// under the name of this one.
    public static let psiSemiVar2 = BuiltinRiskSolverStatistics.statistic(
        "PSISEMIVAR2", maxArgs: 3
    ) { results, values in
        guard let target = real(values, at: 1) else { return .error(.value) }
        guard let value = semiVariance(results.values, below: target) else { return .error(.num) }
        return .number(value)
    }

    /// `PsiSemiDev2(cell, target)` — semi-deviation below a stated target.
    public static let psiSemiDev2 = BuiltinRiskSolverStatistics.statistic(
        "PSISEMIDEV2", maxArgs: 3
    ) { results, values in
        guard let target = real(values, at: 1) else { return .error(.value) }
        guard let value = semiVariance(results.values, below: target) else { return .error(.num) }
        return .number(value.squareRoot())
    }

    // MARK: - Reaching into the run

    /// `PsiData(cell, trial)` — the value this output took on one trial.
    ///
    /// **One-based**, as every position in Excel is. Trial 0 or a trial past the end is
    /// `#NUM!` rather than a clamp to an end: a caller iterating one past the count is asking
    /// for something that does not exist, and a clamped answer would repeat the last trial
    /// silently for as far as the loop ran.
    public static let psiData = BuiltinRiskSolverStatistics.statistic(
        "PSIDATA", maxArgs: 3
    ) { results, values in
        guard let requested = real(values, at: 1) else { return .error(.value) }
        let index = Int(requested.rounded(.towardZero))
        guard index >= 1, index <= results.values.count else { return .error(.num) }
        return .number(results.values[index - 1])
    }

    /// `PsiFrequency(cell, lower, upper)` — the share of trials landing in `[lower, upper]`.
    ///
    /// A proportion in 0…1, not a count: the count is `PsiCount` times this, and the
    /// proportion is what survives a change in the number of trials.
    ///
    /// Both ends are **inclusive**, and a lower above the upper is `#NUM!` rather than an
    /// empty interval reported as a legitimate zero.
    public static let psiFrequency = BuiltinRiskSolverStatistics.statistic(
        "PSIFREQUENCY", maxArgs: 4
    ) { results, values in
        guard let lower = real(values, at: 1), let upper = real(values, at: 2) else {
            return .error(.value)
        }
        guard lower <= upper else { return .error(.num) }
        let values = results.values
        guard !values.isEmpty else { return .error(.num) }
        let inside = values.filter { $0 >= lower && $0 <= upper }.count
        return .number(Double(inside) / Double(values.count))
    }

    // MARK: - Gain and loss

    /// `PsiExpGain(cell, threshold)` — the mean amount by which trials exceed a threshold.
    ///
    /// Averaged over **all** trials, not over the winning ones, for the same reason the
    /// semi-variance is: it is the expected gain of the distribution, so a run that clears the
    /// threshold a tenth of the time by 100 reports 10 and not 100.
    public static let psiExpGain = BuiltinRiskSolverStatistics.statistic(
        "PSIEXPGAIN", maxArgs: 3
    ) { results, values in
        guard let threshold = real(values, at: 1) else { return .error(.value) }
        return expectedTail(results.values, beyond: threshold, above: true)
    }

    /// `PsiExpLoss(cell, threshold)` — the mean amount by which trials fall short.
    ///
    /// Reported as a **positive** number, being a magnitude: a loss of 10 is 10, not −10.
    public static let psiExpLoss = BuiltinRiskSolverStatistics.statistic(
        "PSIEXPLOSS", maxArgs: 3
    ) { results, values in
        guard let threshold = real(values, at: 1) else { return .error(.value) }
        return expectedTail(results.values, beyond: threshold, above: false)
    }

    /// The mean one-sided excess past a threshold, over every trial.
    private static func expectedTail(
        _ values: [Double], beyond threshold: Double, above: Bool
    ) -> CellValue {
        guard !values.isEmpty else { return .error(.num) }
        let total = values.reduce(0.0) { running, value in
            let excess = above ? value - threshold : threshold - value
            return excess > 0 ? running + excess : running
        }
        return .number(total / Double(values.count))
    }
}
