import Foundation
import SwiftExcelCore
import BusinessMath

/// The modern statistical spellings — the inverses, first.
///
/// These are the first two of the 26 functions the `compatibility` bucket is waiting on,
/// and the pair that established what that bucket actually costs. A survey of BusinessMath
/// found **24 of the 26 already have their mathematics**: `DistributionChiSquared.quantile`
/// and `binomialPMF` both exist. What was missing is the Excel-facing layer — argument
/// order, tail convention, and the `#NUM!` domains — which is this package's job.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinStatisticalInverses.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinStatisticalInverses {

    /// All statistical inverses for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [chiSquaredInverseRightTail, binomialInverse]

    /// `CHISQ.INV.RT(probability, deg_freedom)` — the inverse of the **right-tailed**
    /// chi-squared probability.
    ///
    /// Microsoft: *"Returns the inverse of the right-tailed probability of the chi-squared
    /// distribution."* Probability in `[0, 1]`, degrees of freedom in `[1, 10¹⁰)`.
    ///
    /// ## The tail is the whole function
    ///
    /// `DistributionChiSquared.quantile(p)` is the **left**-tailed inverse — the value
    /// whose CDF equals `p`. The right-tailed inverse is therefore `quantile(1 − p)`, and
    /// writing `quantile(p)` instead returns a positive number in the same range for every
    /// input. Nothing about the result says which one you got.
    ///
    /// That is the same trap the `compatibility` bucket carries eight of, one function
    /// along: `CHIDIST` means `CHISQ.DIST.RT` and not `CHISQ.DIST`.
    public static let chiSquaredInverseRightTail = ExcelFunction(
        name: "CHISQ.INV.RT", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        guard let probability = real(values.first),
              let degreesOfFreedom = real(values.dropFirst().first) else { return .error(.value) }

        // Microsoft's stated domain, quoted rather than inferred.
        guard probability >= 0, probability <= 1 else { return .error(.num) }
        guard degreesOfFreedom >= 1, degreesOfFreedom < 1e10 else { return .error(.num) }

        let distribution = DistributionChiSquared(
            degreesOfFreedom: Int(degreesOfFreedom.rounded(.towardZero)))
        let result = distribution.quantile(1 - probability)
        guard result.isFinite else { return .error(.num) }
        return .number(result)
    }

    /// `BINOM.INV(trials, probability_s, alpha)` — the smallest number of successes whose
    /// cumulative binomial probability reaches a criterion.
    ///
    /// Microsoft: *"Returns the smallest value for which the cumulative binomial
    /// distribution is greater than or equal to a criterion value."*
    ///
    /// ## Two words doing the work
    ///
    /// **"Smallest"** and **"greater than or equal to"**. The comparison is inclusive, so
    /// at an `alpha` that exactly equals a cumulative value the answer is that `k` and not
    /// the next one. With two trials at `p = 0.5` the cumulative values are 0.25, 0.75,
    /// 1.0 — and `BINOM.INV(2, 0.5, 0.75)` is 1, not 2. A strict `>` gives 2, is wrong only
    /// at exact boundaries, and is therefore wrong exactly where a test would be written
    /// with round numbers.
    ///
    /// Accumulated over BusinessMath's `binomialPMF(n:k:p:)` rather than through a
    /// binomial CDF, because upstream has the mass function and not the distribution
    /// function. That is Microsoft's definition rather than an implementation choice.
    public static let binomialInverse = ExcelFunction(
        name: "BINOM.INV", minArgs: 3, maxArgs: 3
    ) { values in
        if let error = firstError(values) { return error }
        guard let trials = real(values.first),
              let successProbability = real(values.dropFirst().first),
              let alpha = real(values.dropFirst(2).first) else { return .error(.value) }

        guard trials >= 0, trials.rounded(.towardZero) == trials else { return .error(.num) }
        guard successProbability >= 0, successProbability <= 1 else { return .error(.num) }
        guard alpha >= 0, alpha <= 1 else { return .error(.num) }

        let n = Int(trials)
        var cumulative = 0.0
        for k in 0...max(n, 0) {
            cumulative += binomialPMF(n: n, k: k, p: successProbability)
            // Inclusive, per "greater than or equal to". The tolerance absorbs the
            // accumulated rounding of a sum of masses, which at an exact boundary would
            // otherwise fall a few ulps short and return k + 1.
            if cumulative >= alpha - 1e-12 { return .number(Double(k)) }
        }
        return .number(Double(n))
    }

    // MARK: - Shared

    /// The first error among the arguments, propagated rather than absorbed.
    static func firstError(_ values: [CellValue]) -> CellValue? {
        values.first { if case .error = $0 { return true } else { return false } }
    }

    /// A finite number from a cell value.
    static func real(_ value: CellValue?) -> Double? {
        switch value {
        case .number(let d): return d.isFinite ? d : nil
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
}
