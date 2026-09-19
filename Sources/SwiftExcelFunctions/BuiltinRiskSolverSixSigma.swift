import Foundation
import SwiftExcelCore
import BusinessMath

/// `PsiSixSigma(…)` and the twenty `PsiSigma*` capability metrics.
///
/// Six Sigma asks one question of a simulated output: **how much of the distribution falls
/// outside what the customer will accept.** The specification limits are not a property of
/// the run — no number of trials reveals them — so they are written onto the output cell:
///
/// ```
/// =B2 + B3 + PsiOutput() + PsiSixSigma(95, 105, 100)
/// ```
///
/// and every `PsiSigma*` statistic reads them back from there. `PsiSixSigma` contributes
/// nothing to the arithmetic, exactly as `PsiOutput()` does, which is why it is written
/// *onto* a formula rather than instead of one.
///
/// ## Two families of answer, and the difference is not cosmetic
///
/// - **The capability ratios** — `Cp`, `Cpk`, `Cpm`, `k`, the `Z` scores — are algebra over
///   the mean and standard deviation. They are what they are for any distribution.
/// - **The defect rates** come in two forms, and this is the part worth reading. The
///   unshifted ones are counted **empirically, from the trials themselves**: a simulation's
///   whole purpose is that it does not need to assume a shape, and a skewed output's true
///   defect rate is nothing like the normal-theory figure. The **shifted** ones
///   (`PsiSigmaDefectShiftPPM` and its relatives) apply the classic 1.5σ long-term drift,
///   which is a normal-theory construct with no empirical counterpart — there are no trials
///   of a process that has not drifted yet. Those are computed from the normal, and say so.
///
/// Mixing the two would be easy and invisible: both produce a defect rate in parts per
/// million, and for a symmetric output they nearly agree.
///
/// ## Not measurable against Excel
///
/// As with every `Psi*`, these come from Frontline's add-in and cannot be put to Excel — a
/// workbook containing one opens reading `#NAME?`. The definitions below are the standard
/// process-capability formulas, stated in the documentation of each so that a later
/// measurement has something specific to contradict.
public enum BuiltinRiskSolverSixSigma {

    /// The specification a `PsiSixSigma` call carries.
    struct Specification: Sendable {
        let lower: Double
        let upper: Double
        /// The target value. Defaults to the midpoint, which is what `Cpm` reduces to `Cp`
        /// at — so an omitted target costs nothing rather than meaning zero.
        let target: Double
        /// The assumed long-term drift, in standard deviations. Frontline's default is 1.5,
        /// the figure the whole "six sigma" name is calibrated against: a 6σ process drifting
        /// 1.5σ is the 3.4 defects per million everyone quotes.
        let shift: Double
    }

    /// `PsiSixSigma(LSL, USL, [target], [shift])` — the limits, carried on the output cell.
    ///
    /// Answers zero so it can be added onto a real formula without changing it, the same
    /// arrangement `PsiOutput()` has.
    public static let psiSixSigma = ExcelFunction(
        name: "PSISIXSIGMA", minArgs: 2, maxArgs: 4
    ) { _ in .number(0) }

    /// Every metric name this file answers.
    static let governed: Set<String> = [
        "PSISIGMACP", "PSISIGMACPK", "PSISIGMACPKLOWER", "PSISIGMACPKUPPER", "PSISIGMACPM",
        "PSISIGMAK", "PSISIGMALOWERBOUND", "PSISIGMAUPPERBOUND",
        "PSISIGMAZLOWER", "PSISIGMAZUPPER", "PSISIGMAZMIN", "PSISIGMASIGMALEVEL",
        "PSISIGMAYIELD", "PSISIGMADEFECTPPM",
        "PSISIGMAPROBDEFECTSHIFT", "PSISIGMAPROBDEFECTSHIFTLOWER",
        "PSISIGMAPROBDEFECTSHIFTUPPER",
        "PSISIGMADEFECTSHIFTPPM", "PSISIGMADEFECTSHIFTPPMLOWER", "PSISIGMADEFECTSHIFTPPMUPPER"
    ]

    /// Whether this file answers a name.
    static func governs(_ name: String) -> Bool { governed.contains(name) }

    /// Registrations, whose bodies the evaluator replaces — see
    /// ``BuiltinRiskSolverTheoretical/all`` for why a placeholder is needed at all.
    public static let all: [ExcelFunction] =
        [psiSixSigma] + governed.sorted().map { name in
            ExcelFunction(name: name, minArgs: 1, maxArgs: 1) { _ in .error(.value) }
        }

    // MARK: - The metrics

    /// Answers one `PsiSigma*` call.
    ///
    /// - Parameters:
    ///   - name: the canonical name, already known to be governed.
    ///   - specification: the limits read off the cell's `PsiSixSigma` call.
    ///   - values: the completed run's trial values.
    ///   - mean: the run's mean.
    ///   - deviation: the run's standard deviation.
    /// - Returns: the metric, or an Excel error.
    static func evaluate(
        _ name: String, specification: Specification,
        values: [Double], mean: Double, deviation: Double
    ) -> CellValue {
        let lower = specification.lower, upper = specification.upper
        // The bounds are the one pair that needs neither a spread nor a mean.
        switch name {
        case "PSISIGMALOWERBOUND": return .number(lower)
        case "PSISIGMAUPPERBOUND": return .number(upper)
        default: break
        }
        guard upper > lower else { return .error(.num) }
        // Every remaining metric divides by the spread. A run with none is a constant, and a
        // constant has no capability — refused rather than answered with an infinity, which
        // no cell can hold.
        guard deviation > 0 else { return .error(.num) }

        let width = upper - lower
        let upperZ = (upper - mean) / deviation
        let lowerZ = (mean - lower) / deviation

        switch name {
        case "PSISIGMACP":
            // The spread the specification allows against the spread the process has,
            // ignoring where the process is centred. A perfectly capable but badly centred
            // process has a high Cp and a low Cpk, which is the pair's whole point.
            return .number(width / (6 * deviation))
        case "PSISIGMACPKUPPER":
            return .number(upperZ / 3)
        case "PSISIGMACPKLOWER":
            return .number(lowerZ / 3)
        case "PSISIGMACPK":
            return .number(Swift.min(upperZ, lowerZ) / 3)
        case "PSISIGMACPM":
            // Cpm charges for being off *target*, not merely off centre: the denominator
            // carries the distance from the target alongside the variance.
            let offset = mean - specification.target
            let effective = (deviation * deviation + offset * offset).squareRoot()
            guard effective > 0 else { return .error(.num) }
            return .number(width / (6 * effective))
        case "PSISIGMAK":
            // How far off centre, as a fraction of the half-width. Zero is centred; one sits
            // on a limit. Signed, so it says *which* way — an unsigned k loses the only piece
            // of information a centring measure carries beyond Cpk.
            let midpoint = (upper + lower) / 2
            return .number((mean - midpoint) / (width / 2))

        case "PSISIGMAZUPPER": return .number(upperZ)
        case "PSISIGMAZLOWER": return .number(lowerZ)
        case "PSISIGMAZMIN", "PSISIGMASIGMALEVEL":
            // The sigma level is the nearer limit in standard deviations — the short-term
            // figure, with no 1.5 shift folded in. The shifted view is what the
            // `*Shift*` metrics are for, and adding it here as well would double-count it.
            return .number(Swift.min(upperZ, lowerZ))

        case "PSISIGMADEFECTPPM", "PSISIGMAYIELD":
            // **Counted from the trials, not assumed from a normal.** A simulation exists so
            // that a skewed output's defect rate does not have to be guessed from its moments,
            // and for a skewed output the two answers are not close.
            guard !values.isEmpty else { return .error(.num) }
            let defects = values.filter { $0 < lower || $0 > upper }.count
            let rate = Double(defects) / Double(values.count)
            return .number(name == "PSISIGMAYIELD" ? 1 - rate : rate * 1_000_000)

        default:
            return shifted(name, specification: specification,
                           upperZ: upperZ, lowerZ: lowerZ)
        }
    }

    /// The long-term metrics, which assume a normal that has drifted.
    ///
    /// There are no trials of a process that has not drifted yet, so unlike the unshifted
    /// defect rate this cannot be counted and is computed from the normal.
    ///
    /// ## The drift goes one way
    ///
    /// A mean that moves toward one limit moves **away** from the other by the same amount.
    /// The first version of this subtracted the shift from both `Z` scores, making both tails
    /// worse at once — a process cannot drift toward both its limits, and the result was a
    /// defect rate worse than any real drift could produce. `testTheDriftHurtsOneSideAndHelps
    /// TheOther` is what caught it, and the doc comment describing the correct behaviour was
    /// sitting directly above the code that did not do it.
    ///
    /// The direction is **toward the nearer limit**, which is the worst case and the
    /// convention the familiar figure comes from: a 6σ process drifting 1.5σ leaves `Z = 4.5`
    /// on the near side and 3.4 defects per million, while the far side at `Z = 7.5`
    /// contributes nothing anyone rounds to. Ties go to the upper limit, so a perfectly
    /// centred process gets a definite answer rather than an arbitrary one.
    private static func shifted(
        _ name: String, specification: Specification, upperZ: Double, lowerZ: Double
    ) -> CellValue {
        let shift = specification.shift
        let standard = DistributionNormal(0, 1)
        let towardUpper = upperZ <= lowerZ
        // `cdf(-z)` rather than `1 - cdf(z)`: the tail is what is wanted, and the complement
        // loses its significant digits exactly where a capability study cares most.
        let aboveUpper = standard.cdf(-(towardUpper ? upperZ - shift : upperZ + shift))
        let belowLower = standard.cdf(-(towardUpper ? lowerZ + shift : lowerZ - shift))
        let value: Double
        switch name {
        case "PSISIGMAPROBDEFECTSHIFTUPPER", "PSISIGMADEFECTSHIFTPPMUPPER":
            value = aboveUpper
        case "PSISIGMAPROBDEFECTSHIFTLOWER", "PSISIGMADEFECTSHIFTPPMLOWER":
            value = belowLower
        default:
            value = aboveUpper + belowLower
        }
        guard value.isFinite else { return .error(.num) }
        return .number(name.hasSuffix("PPM") || name.contains("PPM")
                       ? value * 1_000_000 : value)
    }

    // MARK: - Reading the specification

    /// The `PsiSixSigma` call attached to a formula, if it carries one.
    ///
    /// - Parameters:
    ///   - arguments: the evaluated arguments of that call.
    /// - Returns: the specification, or `nil` when the arguments are not usable.
    static func specification(from arguments: [CellValue]) -> Specification? {
        let numbers = arguments.compactMap { value -> Double? in
            if case .number(let d) = value, d.isFinite { return d }
            return nil
        }
        guard numbers.count >= 2 else { return nil }
        let lower = numbers[0], upper = numbers[1]
        // An omitted target is the midpoint, where `Cpm` reduces to `Cp` — so leaving it out
        // costs nothing, where defaulting to zero would report every centred process as
        // wildly off target.
        let target = numbers.count > 2 ? numbers[2] : (lower + upper) / 2
        let shift = numbers.count > 3 ? numbers[3] : 1.5
        return Specification(lower: lower, upper: upper, target: target, shift: shift)
    }
}
