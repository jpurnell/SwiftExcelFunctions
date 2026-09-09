import Foundation
import SwiftExcelCore
import BusinessMath

/// The distribution inverses — `BETA.INV`, `GAMMA.INV`, `F.INV.RT`, `T.INV.2T`,
/// `LOGNORM.INV`.
///
/// ## All five reach upstream the same way
///
/// Every one goes through a type conforming to `ContinuousDistribution`, whose
/// `quantile(_:)` is *the* documented inverse of its `cdf(_:)`. The free functions —
/// `gammaQuantile`, `fQuantile`, `tQuantile`, `inverseRegularizedIncompleteBeta` — are
/// reachable too, and an earlier draft of this file used three of them directly.
///
/// It went through the protocol instead because the conformances are thin wrappers over
/// exactly those free functions, so nothing is lost and one seam is gained. `DistributionT`
/// delegates to `tQuantile`, `DistributionBeta` to `inverseRegularizedIncompleteBeta`,
/// `DistributionF` to `fQuantile`, `DistributionGamma` to `gammaQuantile`. Binding some
/// through the type and some through the function would have left the next person to guess
/// which convention this file follows.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinStatisticalQuantiles.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinStatisticalQuantiles {

    /// All distribution inverses for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        betaInverse, gammaInverse, fInverseRightTail, tInverseTwoTailed, logNormInverse
    ]

    /// `BETA.INV(probability, alpha, beta, [A], [B])` — the inverse of the beta CDF.
    ///
    /// `A` and `B` rescale the result off the unit interval and default to 0 and 1. The
    /// probability is inverted on `[0, 1]` first and mapped afterwards, which is Excel's
    /// definition and also the only order that keeps the bounds independent of the shape.
    public static let betaInverse = ExcelFunction(
        name: "BETA.INV", minArgs: 3, maxArgs: 5
    ) { values in
        if let error = firstError(values) { return error }
        guard let probability = real(values.first), let alpha = real(values[1]),
              let beta = real(values[2]) else { return .error(.value) }
        guard probability >= 0, probability <= 1, alpha > 0, beta > 0 else { return .error(.num) }

        let lower = values.count > 3 ? real(values[3]) : 0
        let upper = values.count > 4 ? real(values[4]) : 1
        guard let lower, let upper, upper > lower else { return .error(.num) }

        let unit = DistributionBeta(alpha: alpha, beta: beta).quantile(probability)
        guard unit.isFinite else { return .error(.num) }
        return .number(lower + unit * (upper - lower))
    }

    /// `GAMMA.INV(probability, alpha, beta)` — the inverse of `GAMMA.DIST(…, TRUE)`.
    ///
    /// `beta` is the **scale**, matching `GAMMA.DIST`. `DistributionGamma(shape:scale:)` is
    /// failable and returns `nil` for a non-positive parameter, so the guard below and the
    /// initialiser agree rather than one covering for the other.
    public static let gammaInverse = ExcelFunction(
        name: "GAMMA.INV", minArgs: 3, maxArgs: 3
    ) { values in
        if let error = firstError(values) { return error }
        guard let probability = real(values.first), let shape = real(values[1]),
              let scale = real(values[2]) else { return .error(.value) }
        guard probability >= 0, probability <= 1, shape > 0, scale > 0 else { return .error(.num) }

        guard let distribution = DistributionGamma(shape: shape, scale: scale)
        else { return .error(.num) }
        let result = distribution.quantile(probability)
        guard result.isFinite else { return .error(.num) }
        return .number(result)
    }

    /// `F.INV.RT(probability, deg_freedom1, deg_freedom2)` — the inverse of the
    /// **right-tailed** F probability.
    ///
    /// `quantile(_:)` is the left-tailed inverse, so this asks it for `1 − probability`.
    /// Passing `probability` straight through returns a positive number in the same range
    /// for every input, and nothing about the result says which one you got — the trap the
    /// `compatibility` bucket carries eight of, where `FDIST` means `F.DIST.RT`.
    public static let fInverseRightTail = ExcelFunction(
        name: "F.INV.RT", minArgs: 3, maxArgs: 3
    ) { values in
        if let error = firstError(values) { return error }
        guard let probability = real(values.first), let df1 = real(values[1]),
              let df2 = real(values[2]) else { return .error(.value) }
        guard probability >= 0, probability <= 1,
              BuiltinStatisticalDistributions.degreesOfFreedomRange.contains(df1),
              BuiltinStatisticalDistributions.degreesOfFreedomRange.contains(df2)
        else { return .error(.num) }

        let distribution = DistributionF(df1: Int(df1.rounded(.towardZero)),
                                         df2: Int(df2.rounded(.towardZero)))
        let result = distribution.quantile(1 - probability)
        guard result.isFinite else { return .error(.num) }
        return .number(result)
    }

    /// `T.INV.2T(probability, deg_freedom)` — the inverse of the **two-tailed** t
    /// probability.
    ///
    /// A two-tailed probability `p` splits into `p/2` in each tail, so the critical value
    /// is the one-tailed quantile at `1 − p/2`. `T.INV` — a different function — is
    /// one-tailed, and binding this to it is out by exactly the factor that makes a
    /// confidence interval too narrow.
    ///
    /// Probability is in `(0, 1]`: at zero the critical value is infinite.
    public static let tInverseTwoTailed = ExcelFunction(
        name: "T.INV.2T", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        guard let probability = real(values.first), let df = real(values[1])
        else { return .error(.value) }
        guard probability > 0, probability <= 1,
              BuiltinStatisticalDistributions.degreesOfFreedomRange.contains(df)
        else { return .error(.num) }

        let distribution = DistributionT(degreesOfFreedom: Int(df.rounded(.towardZero)))
        let result = distribution.quantile(1 - probability / 2)
        guard result.isFinite else { return .error(.num) }
        return .number(result)
    }

    /// `LOGNORM.INV(probability, mean, standard_dev)` — the inverse of
    /// `LOGNORM.DIST(…, TRUE)`.
    ///
    /// `mean` and `standard_dev` are of `ln(x)`, matching `LOGNORM.DIST`. Probability is in
    /// the open interval: both endpoints are infinite on an unbounded support.
    public static let logNormInverse = ExcelFunction(
        name: "LOGNORM.INV", minArgs: 3, maxArgs: 3
    ) { values in
        if let error = firstError(values) { return error }
        guard let probability = real(values.first), let mean = real(values[1]),
              let deviation = real(values[2]) else { return .error(.value) }
        guard probability > 0, probability < 1, deviation > 0 else { return .error(.num) }

        let result = DistributionLogNormal(mean, deviation).quantile(probability)
        guard result.isFinite else { return .error(.num) }
        return .number(result)
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
