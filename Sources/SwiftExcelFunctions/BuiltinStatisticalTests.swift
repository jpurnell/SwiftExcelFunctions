import Foundation
import SwiftExcelCore
import BusinessMath

/// The remaining distributions, and the two hypothesis tests.
///
/// ## On the two tests
///
/// `CHISQ.TEST` and `F.TEST` were recorded as blocked on "a statistic written nowhere".
/// That overstated it. `Σ(O−E)²/E` is a sum over two arrays and a variance ratio is a
/// division; neither is an algorithm anyone is missing, and both tails already exist as
/// ``BuiltinStatisticalDistributions``. The arithmetic lives here because it is *Excel's*
/// definition of the test — the degrees of freedom in particular — rather than a general
/// statistical routine that would belong upstream.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinStatisticalTests.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinStatisticalTests {

    /// All of these for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        negBinomDist, hypGeomDist, weibullDist, confidenceNorm, zTest, chiSquaredTest, fTest
    ]

    // MARK: - Distributions

    /// `NEGBINOM.DIST(number_f, number_s, probability_s, cumulative)` — the probability of
    /// `number_f` failures before the `number_s`-th success.
    public static let negBinomDist = ExcelFunction(
        name: "NEGBINOM.DIST", minArgs: 4, maxArgs: 4
    ) { values in
        if let error = firstError(values) { return error }
        guard let failures = real(values.first), let successes = real(values[1]),
              let probability = real(values[2]), let cumulative = flag(values[3])
        else { return .error(.value) }
        guard failures >= 0, successes >= 1, probability > 0, probability <= 1
        else { return .error(.num) }

        guard let distribution = DistributionNegativeBinomial(
            successes: Int(successes.rounded(.towardZero)), p: probability)
        else { return .error(.num) }

        let k = Int(failures.rounded(.towardZero))
        return .number(cumulative ? distribution.cdf(k) : distribution.pmf(k))
    }

    /// `HYPGEOM.DIST(sample_s, number_sample, population_s, number_pop, cumulative)` —
    /// drawing without replacement.
    public static let hypGeomDist = ExcelFunction(
        name: "HYPGEOM.DIST", minArgs: 5, maxArgs: 5
    ) { values in
        if let error = firstError(values) { return error }
        guard let sampleSuccesses = real(values.first), let sampleSize = real(values[1]),
              let populationSuccesses = real(values[2]), let population = real(values[3]),
              let cumulative = flag(values[4]) else { return .error(.value) }
        guard sampleSuccesses >= 0, sampleSize > 0, populationSuccesses >= 0,
              population > 0, sampleSize <= population, populationSuccesses <= population,
              sampleSuccesses <= sampleSize else { return .error(.num) }

        guard let distribution = DistributionHyperGeometric(
            draws: Int(sampleSize.rounded(.towardZero)),
            successes: Int(populationSuccesses.rounded(.towardZero)),
            population: Int(population.rounded(.towardZero)))
        else { return .error(.num) }

        let k = Int(sampleSuccesses.rounded(.towardZero))
        return .number(cumulative ? distribution.cdf(k) : distribution.pmf(k))
    }

    /// `WEIBULL.DIST(x, alpha, beta, cumulative)`.
    ///
    /// `alpha` is the shape and `beta` the scale, so the CDF is `1 − e^(−(x/β)^α)`.
    public static let weibullDist = ExcelFunction(
        name: "WEIBULL.DIST", minArgs: 4, maxArgs: 4
    ) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first), let shape = real(values[1]),
              let scale = real(values[2]), let cumulative = flag(values[3])
        else { return .error(.value) }
        guard x >= 0, shape > 0, scale > 0 else { return .error(.num) }

        let distribution = DistributionWeibull(shape: shape, scale: scale)
        guard cumulative else {
            // The density: (α/β)·(x/β)^(α−1)·e^(−(x/β)^α).
            let scaled = x / scale
            let density = (shape / scale) * Foundation.pow(scaled, shape - 1)
                * Foundation.exp(-Foundation.pow(scaled, shape))
            return .number(density)
        }
        return .number(distribution.cdf(x))
    }

    /// `CONFIDENCE.NORM(alpha, standard_dev, size)` — the **half-width** of a confidence
    /// interval for a population mean.
    ///
    /// Not the interval, and not its full width. The value is added to *and* subtracted
    /// from the sample mean, so returning the width would double every interval built on
    /// it — a mistake that looks like a more cautious estimate rather than a wrong one.
    public static let confidenceNorm = ExcelFunction(
        name: "CONFIDENCE.NORM", minArgs: 3, maxArgs: 3
    ) { values in
        if let error = firstError(values) { return error }
        guard let alpha = real(values.first), let deviation = real(values[1]),
              let size = real(values[2]) else { return .error(.value) }
        guard alpha > 0, alpha < 1, deviation > 0, size >= 1 else { return .error(.num) }

        let z = inverseNormalCDF(p: 1 - alpha / 2, mean: 0, stdDev: 1)
        let root = size.squareRoot()
        guard root > 0 else { return .error(.num) }
        return .number(z * deviation / root)
    }

    /// `Z.TEST(array, x, [sigma])` — the **one-tailed** probability of a z-test.
    ///
    /// The chance of observing a sample mean at least as far *above* `x` as this one, if
    /// the true mean were `x`. One-tailed, so at `x` equal to the sample mean it is a half
    /// rather than 1.
    ///
    /// `sigma` defaults to the sample standard deviation when omitted.
    public static let zTest = ExcelFunction(name: "Z.TEST", minArgs: 2, maxArgs: 3) { values in
        if let error = firstError(values) { return error }
        let sample = flattenNumbers(Array(values.prefix(1)))
        guard sample.count >= 2, let x = real(values[1]) else { return .error(.value) }

        let deviation: Double
        if values.count > 2 {
            guard let sigma = real(values[2]), sigma > 0 else { return .error(.num) }
            deviation = sigma
        } else {
            deviation = stdDevS(sample)
        }
        let count = Double(sample.count)
        let root = count.squareRoot()
        guard deviation > 0, root > 0 else { return .error(.div0) }

        let z = (mean(sample) - x) / (deviation / root)
        return .number(1 - normalCDF(x: z))
    }

    // MARK: - The two tests

    /// `CHISQ.TEST(actual_range, expected_range)` — the p-value of Pearson's chi-squared
    /// statistic.
    ///
    /// The statistic is `Σ(O−E)²/E` and the p-value is its right tail. Degrees of freedom
    /// are `n − 1` for a single row or column, which is what Excel uses and what makes this
    /// Excel's definition rather than a general one.
    ///
    /// An expected frequency of zero is `#DIV/0!` — the term is undefined, and reporting a
    /// p-value computed without it would answer a different question silently.
    public static let chiSquaredTest = ExcelFunction(
        name: "CHISQ.TEST", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        let observed = flattenNumbers(Array(values.prefix(1)))
        let expected = flattenNumbers(Array(values.dropFirst().prefix(1)))

        guard !observed.isEmpty, observed.count == expected.count else { return .error(.na) }
        guard observed.count > 1 else { return .error(.num) }

        var statistic = 0.0
        for (o, e) in zip(observed, expected) {
            guard e != 0 else { return .error(.div0) }
            let difference = o - e
            statistic += difference * difference / e
        }

        guard let cdf = try? chiSquaredCDF(x: statistic, df: observed.count - 1)
        else { return .error(.num) }
        return .number(1 - cdf)
    }

    /// `F.TEST(array1, array2)` — the **two-tailed** probability that two samples have
    /// different variances.
    ///
    /// Two-tailed, which is what makes the answer independent of the argument order: a
    /// one-tailed implementation gives different results for `F.TEST(a, b)` and
    /// `F.TEST(b, a)`, and both look plausible.
    ///
    /// Excel uses the **sample** variance, so each array needs at least two observations.
    public static let fTest = ExcelFunction(name: "F.TEST", minArgs: 2, maxArgs: 2) { values in
        if let error = firstError(values) { return error }
        let first = flattenNumbers(Array(values.prefix(1)))
        let second = flattenNumbers(Array(values.dropFirst().prefix(1)))
        guard first.count >= 2, second.count >= 2 else { return .error(.div0) }

        let varianceOne = stdDevS(first) * stdDevS(first)
        let varianceTwo = stdDevS(second) * stdDevS(second)
        guard varianceOne > 0, varianceTwo > 0 else { return .error(.div0) }

        let ratio = varianceOne / varianceTwo
        guard let cdf = try? fCDF(f: ratio, df1: first.count - 1, df2: second.count - 1)
        else { return .error(.num) }

        // Two-tailed: twice whichever tail the ratio falls in, capped at 1.
        return .number(min(2 * Swift.min(cdf, 1 - cdf), 1))
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

    /// Every number in an argument list, flattening arrays and skipping what is not a
    /// number — the same rule the statistical aggregates already follow.
    static func flattenNumbers(_ args: [CellValue]) -> [Double] {
        var result: [Double] = []
        for arg in args {
            switch arg {
            case .number(let n): result.append(n)
            case .bool(let b): result.append(b ? 1 : 0)
            case .array(let matrix): result.append(contentsOf: flattenNumbers(matrix.elements))
            default: continue
            }
        }
        return result
    }
}
