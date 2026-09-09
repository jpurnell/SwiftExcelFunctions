import Foundation
import SwiftExcelCore
import BusinessMath

/// The modern distribution spellings.
///
/// Eight of the 26 the `compatibility` bucket waits on. Every one is a binding over
/// mathematics BusinessMath already has — `binomialPMF`, `poissonCDF`, `exponentialCDF`,
/// `gammaCDF`, `logNormalCDF`, `chiSquaredCDF`, `fCDF`, `tCDF`. What this layer supplies is
/// Excel's argument order, its cumulative flag, its tail convention and its `#NUM!` domains.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinStatisticalDistributions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinStatisticalDistributions {

    /// All distribution spellings for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        binomDist, poissonDist, exponDist, gammaDist, logNormDist,
        chiSquaredDistRightTail, fDistRightTail, tDistTwoTailed
    ]

    /// Excel's ceiling on degrees of freedom: `[1, 10¹⁰)`, the bound `CHISQ.INV.RT`
    /// documents and the rest of the family shares.
    static let degreesOfFreedomRange: Range<Double> = 1..<1e10

    // MARK: - The cumulative flag

    /// `BINOM.DIST(number_s, trials, probability_s, cumulative)`.
    ///
    /// `cumulative` selects a **different function**, not a different format: `FALSE` is
    /// the probability of exactly `number_s` successes, `TRUE` the probability of at most
    /// that many. Accumulated over BusinessMath's `binomialPMF`, since upstream has the mass function
    /// rather than the distribution function.
    public static let binomDist = ExcelFunction(
        name: "BINOM.DIST", minArgs: 4, maxArgs: 4
    ) { values in
        if let error = firstError(values) { return error }
        guard let successes = real(values.first), let trials = real(values[1]),
              let probability = real(values[2]), let cumulative = flag(values[3])
        else { return .error(.value) }

        guard trials >= 0, successes >= 0, successes <= trials,
              probability >= 0, probability <= 1 else { return .error(.num) }

        let n = Int(trials.rounded(.towardZero))
        let k = Int(successes.rounded(.towardZero))
        guard cumulative else { return .number(binomialPMF(n: n, k: k, p: probability)) }

        var total = 0.0
        for i in 0...k { total += binomialPMF(n: n, k: i, p: probability) }
        return .number(min(total, 1))
    }

    /// `POISSON.DIST(x, mean, cumulative)`.
    ///
    /// The mass at `x` is `e^(−μ)·μˣ/x!`. Computed from the definition rather than as a
    /// difference of two cumulatives, which would lose precision in the tail where the two
    /// are nearly equal.
    public static let poissonDist = ExcelFunction(
        name: "POISSON.DIST", minArgs: 3, maxArgs: 3
    ) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first), let mean = real(values[1]),
              let cumulative = flag(values[2]) else { return .error(.value) }
        guard x >= 0, mean >= 0 else { return .error(.num) }

        let k = Int(x.rounded(.towardZero))
        guard cumulative else {
            var logMass = -mean + Double(k) * Foundation.log(mean == 0 ? 1 : mean)
            for i in 1...max(k, 1) where k > 0 { logMass -= Foundation.log(Double(i)) }
            if mean == 0 { return .number(k == 0 ? 1 : 0) }
            return .number(Foundation.exp(logMass))
        }
        return .number(poissonCDF(x, µ: mean))
    }

    /// `EXPON.DIST(x, lambda, cumulative)`.
    ///
    /// Cumulative is `1 − e^(−λx)`; the density is `λe^(−λx)`. `lambda` must be strictly
    /// positive — a rate of zero describes nothing.
    public static let exponDist = ExcelFunction(
        name: "EXPON.DIST", minArgs: 3, maxArgs: 3
    ) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first), let lambda = real(values[1]),
              let cumulative = flag(values[2]) else { return .error(.value) }
        guard x >= 0, lambda > 0 else { return .error(.num) }

        guard cumulative else { return .number(lambda * Foundation.exp(-lambda * x)) }
        return .number(exponentialCDF(x, λ: lambda))
    }

    /// `GAMMA.DIST(x, alpha, beta, cumulative)`.
    ///
    /// Excel's `alpha` is the shape and `beta` the **scale**, matching upstream's
    /// `gammaCDF(_:shape:scale:)`. The other common parameterisation uses a *rate*, which
    /// is the reciprocal — a model built against it silently reports a distribution
    /// stretched by `1/β²`.
    public static let gammaDist = ExcelFunction(
        name: "GAMMA.DIST", minArgs: 4, maxArgs: 4
    ) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first), let shape = real(values[1]),
              let scale = real(values[2]), let cumulative = flag(values[3])
        else { return .error(.value) }
        guard x >= 0, shape > 0, scale > 0 else { return .error(.num) }

        guard cumulative else {
            // The density, from its definition: x^(α−1)·e^(−x/β) / (β^α·Γ(α)).
            guard x > 0 else { return .number(shape < 1 ? .infinity : (shape == 1 ? 1 / scale : 0)) }
            let logDensity = (shape - 1) * Foundation.log(x) - x / scale
                - shape * Foundation.log(scale) - Foundation.lgamma(shape)
            return .number(Foundation.exp(logDensity))
        }
        return .number(gammaCDF(x, shape: shape, scale: scale))
    }

    /// `LOGNORM.DIST(x, mean, standard_dev, cumulative)`.
    ///
    /// `mean` and `standard_dev` are of `ln(x)`, not of `x` — the same trap
    /// `PsiLogNormal` carries, where the arithmetic and log-scale parameterisations differ
    /// and swapping them fails silently. Defined for `x > 0` only.
    public static let logNormDist = ExcelFunction(
        name: "LOGNORM.DIST", minArgs: 4, maxArgs: 4
    ) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first), let mean = real(values[1]),
              let deviation = real(values[2]), let cumulative = flag(values[3])
        else { return .error(.value) }
        guard x > 0, deviation > 0 else { return .error(.num) }

        guard cumulative else {
            let z = (Foundation.log(x) - mean) / deviation
            let density = Foundation.exp(-z * z / 2)
                / (x * deviation * (2 * Double.pi).squareRoot())
            return .number(density)
        }
        return .number(logNormalCDF(x, mean: mean, stdDev: deviation))
    }

    // MARK: - The tails

    /// `CHISQ.DIST.RT(x, deg_freedom)` — the **right-tailed** probability.
    ///
    /// One minus the CDF, and the name is the only thing that says so. `CHISQ.DIST` is the
    /// left-tailed spelling and returns a probability in the same range for every input.
    public static let chiSquaredDistRightTail = ExcelFunction(
        name: "CHISQ.DIST.RT", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first), let df = real(values[1]) else { return .error(.value) }
        guard x >= 0, degreesOfFreedomRange.contains(df) else { return .error(.num) }

        guard let cdf = try? chiSquaredCDF(x: x, df: Int(df.rounded(.towardZero)))
        else { return .error(.num) }
        return .number(1 - cdf)
    }

    /// `F.DIST.RT(x, deg_freedom1, deg_freedom2)` — the right-tailed F probability.
    public static let fDistRightTail = ExcelFunction(
        name: "F.DIST.RT", minArgs: 3, maxArgs: 3
    ) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first), let df1 = real(values[1]), let df2 = real(values[2])
        else { return .error(.value) }
        guard x >= 0, degreesOfFreedomRange.contains(df1),
              degreesOfFreedomRange.contains(df2) else { return .error(.num) }

        guard let cdf = try? fCDF(f: x, df1: Int(df1.rounded(.towardZero)),
                                  df2: Int(df2.rounded(.towardZero)))
        else { return .error(.num) }
        return .number(1 - cdf)
    }

    /// `T.DIST.2T(x, deg_freedom)` — the **two-tailed** Student's t probability.
    ///
    /// Twice the right tail, so at zero it is exactly **1** and not 0.5. Forgetting the
    /// doubling — or applying it twice — produces a probability that looks entirely
    /// reasonable and is out by a factor of two.
    ///
    /// Microsoft requires `x ≥ 0`: a negative is `#NUM!` rather than being folded to its
    /// absolute value.
    public static let tDistTwoTailed = ExcelFunction(
        name: "T.DIST.2T", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first), let df = real(values[1]) else { return .error(.value) }
        guard x >= 0, degreesOfFreedomRange.contains(df) else { return .error(.num) }

        guard let cdf = try? tCDF(t: x, df: Int(df.rounded(.towardZero)))
        else { return .error(.num) }
        return .number(min(2 * (1 - cdf), 1))
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

    /// Excel's `cumulative` flag, which accepts a boolean or a number.
    static func flag(_ value: CellValue?) -> Bool? {
        switch value {
        case .bool(let b): return b
        case .number(let n): return n != 0
        default: return nil
        }
    }
}
