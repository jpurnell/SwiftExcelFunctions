import Foundation
import SwiftExcelCore
import BusinessMath

/// The remaining spreadsheet statistics — position, dispersion, fit, binning, and the
/// two-sample t test.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinSpreadsheetStatistics.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinSpreadsheetStatistics {

    /// All of these for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        chiSquaredInverse, tDistRightTail,
        quartileInclusive, quartileExclusive, percentileExclusive, percentRankInclusive,
        averageDeviation, trimMean, standardErrorYX, probability, frequency, tTest
    ]

    // MARK: - Tails and inverses

    /// `CHISQ.INV(probability, deg_freedom)` — the **left**-tailed inverse.
    ///
    /// The complement of ``BuiltinStatisticalInverses/chiSquaredInverseRightTail``, and the
    /// one the legacy `CHIINV` does *not* map to.
    public static let chiSquaredInverse = ExcelFunction(
        name: "CHISQ.INV", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        guard let p = real(values.first), let df = real(values[1]) else { return .error(.value) }
        guard p >= 0, p <= 1,
              BuiltinStatisticalDistributions.degreesOfFreedomRange.contains(df)
        else { return .error(.num) }

        let result = DistributionChiSquared(
            degreesOfFreedom: Int(df.rounded(.towardZero))).quantile(p)
        guard result.isFinite else { return .error(.num) }
        return .number(result)
    }

    /// `T.DIST.RT(x, deg_freedom)` — the right-tailed t probability. Half of
    /// ``BuiltinStatisticalDistributions/tDistTwoTailed``.
    public static let tDistRightTail = ExcelFunction(
        name: "T.DIST.RT", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first), let df = real(values[1]) else { return .error(.value) }
        guard BuiltinStatisticalDistributions.degreesOfFreedomRange.contains(df)
        else { return .error(.num) }

        guard let cdf = try? tCDF(t: x, df: Int(df.rounded(.towardZero)))
        else { return .error(.num) }
        return .number(1 - cdf)
    }

    // MARK: - Position

    /// The value at probability `p` by linear interpolation between order statistics.
    ///
    /// **Inclusive**: rank runs `p·(n−1)` over `0…n−1`, so `p = 0` and `p = 1` are the
    /// minimum and maximum. This is Excel's `.INC` convention and the one the un-suffixed
    /// `PERCENTILE` and `QUARTILE` also use.
    static func inclusivePercentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty, p >= 0, p <= 1 else { return nil }
        guard sorted.count > 1 else { return sorted[0] }
        let rank = p * Double(sorted.count - 1)
        let lower = Int(rank.rounded(.down))
        let upper = Swift.min(lower + 1, sorted.count - 1)
        return sorted[lower] + (rank - Double(lower)) * (sorted[upper] - sorted[lower])
    }

    /// The **exclusive** percentile: rank runs `p·(n+1)` over `1…n`.
    ///
    /// Which means only probabilities strictly inside `(1/(n+1), n/(n+1))` have an answer —
    /// the endpoints lie outside the data rather than on it. Excel returns `#NUM!` there,
    /// and that refusal is the whole difference between the two conventions.
    static func exclusivePercentile(_ sorted: [Double], _ p: Double) -> Double? {
        let n = sorted.count
        guard n > 0 else { return nil }
        let rank = p * Double(n + 1)
        guard rank >= 1, rank <= Double(n) else { return nil }
        let lower = Int(rank.rounded(.down))
        guard lower >= 1 else { return nil }
        guard lower < n else { return sorted[n - 1] }
        return sorted[lower - 1] + (rank - Double(lower)) * (sorted[lower] - sorted[lower - 1])
    }

    /// `QUARTILE.INC(array, quart)` — quart 0 through 4 as probabilities 0, ¼, ½, ¾, 1.
    public static let quartileInclusive = ExcelFunction(
        name: "QUARTILE.INC", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        let data = flattenNumbers(Array(values.prefix(1))).sorted()
        guard let quart = real(values[1]), quart >= 0, quart <= 4, !data.isEmpty
        else { return .error(.num) }
        guard let result = inclusivePercentile(data, quart / 4) else { return .error(.num) }
        return .number(result)
    }

    /// `QUARTILE.EXC(array, quart)` — the exclusive convention, so quart 0 and 4 have no
    /// answer.
    public static let quartileExclusive = ExcelFunction(
        name: "QUARTILE.EXC", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        let data = flattenNumbers(Array(values.prefix(1))).sorted()
        guard let quart = real(values[1]), quart > 0, quart < 4, !data.isEmpty
        else { return .error(.num) }
        guard let result = exclusivePercentile(data, quart / 4) else { return .error(.num) }
        return .number(result)
    }

    /// `PERCENTILE.EXC(array, k)` — the exclusive percentile.
    public static let percentileExclusive = ExcelFunction(
        name: "PERCENTILE.EXC", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        let data = flattenNumbers(Array(values.prefix(1))).sorted()
        guard let k = real(values[1]), !data.isEmpty else { return .error(.value) }
        guard let result = exclusivePercentile(data, k) else { return .error(.num) }
        return .number(result)
    }

    /// `PERCENTRANK.INC(array, x, [significance])` — where `x` sits, as a proportion.
    ///
    /// The inverse question to ``quartileInclusive``: the minimum ranks 0 and the maximum
    /// ranks 1.
    public static let percentRankInclusive = ExcelFunction(
        name: "PERCENTRANK.INC", minArgs: 2, maxArgs: 3
    ) { values in
        if let error = firstError(values) { return error }
        let data = flattenNumbers(Array(values.prefix(1))).sorted()
        guard let x = real(values[1]), data.count >= 2 else { return .error(.num) }
        guard let first = data.first, let last = data.last, x >= first, x <= last
        else { return .error(.na) }

        // Linear interpolation between the bracketing order statistics, which is the
        // inverse of `inclusivePercentile` and is kept alongside it for that reason.
        if x == last { return .number(1) }
        guard let index = data.lastIndex(where: { $0 <= x }) else { return .error(.na) }
        let below = data[index]
        let above = index + 1 < data.count ? data[index + 1] : below
        let span = above - below
        let within = span == 0 ? 0 : (x - below) / span

        // Bound and guarded rather than divided by inline. `data.count >= 2` above makes
        // this positive, but the safety checker tracks the *divisor symbol* and an inline
        // `Double(data.count - 1)` is not a symbol anything guarded — so the precondition
        // and the check would have been in two places that could drift apart.
        let spread = Double(data.count - 1)
        guard spread > 0 else { return .error(.div0) }
        return .number((Double(index) + within) / spread)
    }

    // MARK: - Dispersion and fit

    /// `AVEDEV(number1, …)` — the mean **absolute** deviation from the mean.
    ///
    /// Absolute, not squared: a measure of spread that stays in the data's own units and
    /// does not weight an outlier by its square.
    public static let averageDeviation = ExcelFunction(
        name: "AVEDEV", minArgs: 1, maxArgs: nil
    ) { values in
        if let error = firstError(values) { return error }
        let data = flattenNumbers(values)
        guard !data.isEmpty else { return .error(.num) }
        let count = Double(data.count)
        guard count > 0 else { return .error(.div0) }
        let average = data.reduce(0, +) / count
        return .number(data.reduce(0) { $0 + abs($1 - average) } / count)
    }

    /// `TRIMMEAN(array, percent)` — the mean after discarding the extremes.
    ///
    /// `percent` is the **total** fraction removed, split between both ends, and the count
    /// is rounded **down to a multiple of two** so the trimming stays symmetric. Rounding
    /// up, or trimming the whole fraction from one end, both produce a plausible number
    /// from a different statistic.
    public static let trimMean = ExcelFunction(name: "TRIMMEAN", minArgs: 2, maxArgs: 2) { values in
        if let error = firstError(values) { return error }
        let data = flattenNumbers(Array(values.prefix(1))).sorted()
        guard let fraction = real(values[1]), fraction >= 0, fraction < 1, !data.isEmpty
        else { return .error(.num) }

        let removable = Int((Double(data.count) * fraction).rounded(.down))
        let perEnd = removable / 2
        let kept = data.dropFirst(perEnd).dropLast(perEnd)
        let count = Double(kept.count)
        guard count > 0 else { return .error(.num) }
        return .number(kept.reduce(0, +) / count)
    }

    /// `STEYX(known_ys, known_xs)` — the standard error of the predicted `y`.
    ///
    /// Zero on a perfect fit, because there is nothing left to err by.
    public static let standardErrorYX = ExcelFunction(
        name: "STEYX", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        let ys = flattenNumbers(Array(values.prefix(1)))
        let xs = flattenNumbers(Array(values.dropFirst().prefix(1)))
        guard ys.count == xs.count else { return .error(.na) }
        guard ys.count >= 3 else { return .error(.div0) }

        let count = Double(ys.count)
        let meanX = xs.reduce(0, +) / count
        let meanY = ys.reduce(0, +) / count
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for (x, y) in zip(xs, ys) {
            sxx += (x - meanX) * (x - meanX)
            syy += (y - meanY) * (y - meanY)
            sxy += (x - meanX) * (y - meanY)
        }
        guard sxx > 0 else { return .error(.div0) }
        let residual = syy - (sxy * sxy) / sxx
        return .number((Swift.max(residual, 0) / (count - 2)).squareRoot())
    }

    // MARK: - Probability and binning

    /// `PROB(x_range, prob_range, lower_limit, [upper_limit])` — the probability that an
    /// outcome falls in the interval.
    ///
    /// With no upper limit it is the probability of exactly `lower_limit`. The weights must
    /// be a distribution: anything not summing to 1 is `#NUM!` rather than a normalised
    /// guess at what was meant.
    public static let probability = ExcelFunction(name: "PROB", minArgs: 3, maxArgs: 4) { values in
        if let error = firstError(values) { return error }
        let outcomes = flattenNumbers(Array(values.prefix(1)))
        let weights = flattenNumbers(Array(values.dropFirst().prefix(1)))
        guard outcomes.count == weights.count, !outcomes.isEmpty else { return .error(.na) }
        guard weights.allSatisfy({ $0 > 0 && $0 <= 1 }) else { return .error(.num) }
        guard abs(weights.reduce(0, +) - 1) < 1e-9 else { return .error(.num) }

        guard let lower = real(values[2]) else { return .error(.value) }
        let upper = values.count > 3 ? real(values[3]) : lower
        guard let upper else { return .error(.value) }

        var total = 0.0
        for (outcome, weight) in zip(outcomes, weights)
        where outcome >= Swift.min(lower, upper) && outcome <= Swift.max(lower, upper) {
            total += weight
        }
        return .number(total)
    }

    /// `FREQUENCY(data_array, bins_array)` — how many values fall in each bin.
    ///
    /// Returns **one more value than there are bins**: the last counts everything above the
    /// highest bin, which is the element callers forget exists and the reason the result
    /// never fits the range they selected.
    ///
    /// Bins are inclusive of their upper bound, so a value exactly on a boundary falls in
    /// the lower bin.
    public static let frequency = ExcelFunction(
        name: "FREQUENCY", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        let data = flattenNumbers(Array(values.prefix(1)))
        let bins = flattenNumbers(Array(values.dropFirst().prefix(1))).sorted()
        guard !bins.isEmpty else { return .error(.na) }

        var counts = [Int](repeating: 0, count: bins.count + 1)
        for value in data {
            // Inclusive upper bound: the first bin whose ceiling the value does not exceed.
            if let index = bins.firstIndex(where: { value <= $0 }) {
                counts[index] += 1
            } else {
                counts[bins.count] += 1
            }
        }
        let elements = counts.map { CellValue.number(Double($0)) }
        return .array(CellMatrix(column: elements))
    }

    // MARK: - The two-sample t test

    /// `T.TEST(array1, array2, tails, type)` — the probability that two samples come from
    /// populations with the same mean.
    ///
    /// `type` selects the test: 1 paired, 2 equal variance, 3 unequal variance (Welch).
    /// `tails` is 1 or 2, and the two answers differ by exactly a factor of two — which is
    /// why the regression test asserts that ratio rather than either value.
    public static let tTest = ExcelFunction(name: "T.TEST", minArgs: 4, maxArgs: 4) { values in
        if let error = firstError(values) { return error }
        let a = flattenNumbers(Array(values.prefix(1)))
        let b = flattenNumbers(Array(values.dropFirst().prefix(1)))
        guard let tails = real(values[2]), let type = real(values[3]) else { return .error(.value) }
        guard tails == 1 || tails == 2, (1...3).contains(type) else { return .error(.num) }
        guard a.count >= 2, b.count >= 2 else { return .error(.div0) }

        let statistic: Double
        let degreesOfFreedom: Double

        switch Int(type) {
        case 1:
            guard a.count == b.count else { return .error(.na) }
            let differences = zip(a, b).map { $0 - $1 }
            let count = Double(differences.count)
            let meanDifference = differences.reduce(0, +) / count
            let deviation = stdDevS(differences)
            // Identical samples differ by nothing, which is a probability of 1 rather than
            // a division by zero.
            guard deviation > 0 else { return .number(1) }
            statistic = meanDifference / (deviation / count.squareRoot())
            degreesOfFreedom = count - 1

        case 2:
            let na = Double(a.count), nb = Double(b.count)
            let va = stdDevS(a) * stdDevS(a), vb = stdDevS(b) * stdDevS(b)
            let pooled = ((na - 1) * va + (nb - 1) * vb) / (na + nb - 2)
            guard pooled > 0 else { return .number(1) }
            statistic = (mean(a) - mean(b)) / (pooled * (1 / na + 1 / nb)).squareRoot()
            degreesOfFreedom = na + nb - 2

        default:
            let na = Double(a.count), nb = Double(b.count)
            let va = stdDevS(a) * stdDevS(a) / na, vb = stdDevS(b) * stdDevS(b) / nb
            guard va + vb > 0 else { return .number(1) }
            statistic = (mean(a) - mean(b)) / (va + vb).squareRoot()
            // Welch–Satterthwaite.
            let numerator = (va + vb) * (va + vb)
            let denominator = va * va / (na - 1) + vb * vb / (nb - 1)
            degreesOfFreedom = denominator > 0 ? numerator / denominator : na + nb - 2
        }

        guard let cdf = try? tCDF(t: abs(statistic), df: Int(degreesOfFreedom.rounded(.towardZero)))
        else { return .error(.num) }
        let oneTail = 1 - cdf
        return .number(Swift.min(tails == 1 ? oneTail : 2 * oneTail, 1))
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

    /// Every number in an argument list, flattening arrays and skipping what is not one.
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
