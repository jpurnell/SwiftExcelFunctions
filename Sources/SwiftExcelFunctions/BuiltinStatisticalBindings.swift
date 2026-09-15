import Foundation
import BusinessMath
import SwiftExcelCore

/// The statistical names the coverage matrix carried as **bindable** — the mathematics was
/// already upstream and only the Excel-facing name was missing.
///
/// Nothing here computes anything, for the reason ``BuiltinBindingFunctions`` gives: a
/// second skewness in the same dependency chain can disagree with the first, and that
/// disagreement is invisible until something is decided with it.
///
/// ## What the corpus asked for
///
/// A sweep of 2,236 workbooks found exactly eighteen function names this package could not
/// answer. Six of them are here — `SKEW` in three workbooks, `CORREL`, `MODE`, `FORECAST`,
/// `LINEST`, `RSQ` — and every one was a *binding* rather than a build. That is the
/// recurring shape of this work: "not implemented" meaning "implemented upstream, under a
/// name no search for the Excel spelling would reach".
public enum BuiltinStatisticalBindings {

    /// All bound statistics for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        skewFunction, skewPopulation, kurt,
        correl, pearson, rsq, forecast, forecastLinear,
        devsq, geomean, harmean, standardizeFunction,
        fisherFunction, fisherInv, permut,
        fInverse, tInverse, confidenceT,
    ]

    // MARK: - Shape

    /// `SKEW(number1, [number2], …)` — the **sample** skewness.
    ///
    /// Positive means a longer right tail. Excel's `SKEW` carries the `n/((n−1)(n−2))`
    /// correction and needs three values to do it; `SKEW.P` beside it does not and does
    /// not.
    public static let skewFunction = ExcelFunction(name: "SKEW", minArgs: 1, maxArgs: nil) { args in
        if let error = firstError(args) { return error }
        let values = numbers(args)
        guard values.count >= 3 else { return .error(.div0) }
        guard spread(values) > 0 else { return .error(.div0) }
        return finite(skewS(values))
    }

    /// `SKEW.P(number1, [number2], …)` — the **population** skewness.
    ///
    /// Two values are enough, because there is no degrees-of-freedom correction to make.
    public static let skewPopulation = ExcelFunction(name: "SKEW.P", minArgs: 1, maxArgs: nil) { args in
        if let error = firstError(args) { return error }
        let values = numbers(args)
        guard values.count >= 2 else { return .error(.div0) }
        guard spread(values) > 0 else { return .error(.div0) }
        return finite(skewP(values))
    }

    /// `KURT(number1, [number2], …)` — the **excess** kurtosis of a sample.
    ///
    /// Excess: a normal distribution is 0 rather than 3. Four values are needed, which is
    /// one more than `SKEW` wants, because the correction divides by `(n−3)`.
    public static let kurt = ExcelFunction(name: "KURT", minArgs: 1, maxArgs: nil) { args in
        if let error = firstError(args) { return error }
        let values = numbers(args)
        guard values.count >= 4 else { return .error(.div0) }
        guard spread(values) > 0 else { return .error(.div0) }
        return finite(kurtosisS(values))
    }

    // MARK: - Two series together

    /// `CORREL(array1, array2)` — the Pearson correlation coefficient.
    public static let correl = ExcelFunction(name: "CORREL", minArgs: 2, maxArgs: 2) { args in
        paired(args) { x, y in
            guard let r = try? correlationCoefficient(x, y, .sample) else { return .error(.div0) }
            return finite(r)
        }
    }

    /// `PEARSON(array1, array2)` — the same coefficient under its own name.
    ///
    /// Registered separately rather than aliased, because Excel documents them as two
    /// functions and a caller reading the registry should find both.
    public static let pearson = ExcelFunction(name: "PEARSON", minArgs: 2, maxArgs: 2) { args in
        paired(args) { x, y in
            guard let r = try? correlationCoefficient(x, y, .sample) else { return .error(.div0) }
            return finite(r)
        }
    }

    /// `RSQ(known_y's, known_x's)` — the square of the correlation coefficient.
    ///
    /// **The y series comes first**, which is the opposite of `CORREL`'s symmetry and the
    /// same order as `SLOPE` and `INTERCEPT`. It makes no difference to the answer here —
    /// `r²` is symmetric — and it makes a large one to `FORECAST` below, so the order is
    /// kept faithful rather than normalised.
    public static let rsq = ExcelFunction(name: "RSQ", minArgs: 2, maxArgs: 2) { args in
        paired(args) { y, x in
            guard let r = try? rSquared(x, y, .sample) else { return .error(.div0) }
            return finite(r)
        }
    }

    /// `FORECAST(x, known_y's, known_x's)` — the least-squares line, read at `x`.
    public static let forecast = ExcelFunction(name: "FORECAST", minArgs: 3, maxArgs: 3) { args in
        predicted(args)
    }

    /// `FORECAST.LINEAR(x, known_y's, known_x's)` — `FORECAST` under its modern name.
    ///
    /// Excel renamed it when the `FORECAST.ETS` family arrived, and both spellings are
    /// live: a workbook saved by Excel 2016 writes `_xlfn.FORECAST.LINEAR` for a formula
    /// an older file spells `FORECAST`.
    public static let forecastLinear = ExcelFunction(
        name: "FORECAST.LINEAR", minArgs: 3, maxArgs: 3
    ) { args in
        predicted(args)
    }

    /// The shared body of the two forecasts.
    ///
    /// - Parameter args: `x`, the known y series, the known x series.
    /// - Returns: The fitted value at `x`, or the error Excel gives.
    private static func predicted(_ args: [CellValue]) -> CellValue {
        if let error = firstError(args) { return error }
        guard let at = BuiltinSpreadsheetStatistics.real(args[0]) else { return .error(.value) }
        let knownY = numbers([args[1]])
        let knownX = numbers([args[2]])
        guard knownY.count == knownX.count else { return .error(.na) }
        guard knownY.count >= 2 else { return .error(.div0) }
        guard spread(knownX) > 0 else { return .error(.div0) }
        // BusinessMath takes the series in (x, y) order and answers with the line itself.
        guard let line = try? linearRegression(knownX, knownY) else { return .error(.div0) }
        return finite(line(at))
    }

    // MARK: - Dispersion and means

    /// `DEVSQ(number1, [number2], …)` — the sum of squared deviations from the mean.
    public static let devsq = ExcelFunction(name: "DEVSQ", minArgs: 1, maxArgs: nil) { args in
        if let error = firstError(args) { return error }
        let values = numbers(args)
        guard !values.isEmpty else { return .error(.num) }
        return finite(sumOfSquaredAvgDiff(values))
    }

    /// `GEOMEAN(number1, [number2], …)` — the geometric mean.
    ///
    /// Every value must be positive. A zero or a negative makes the product meaningless
    /// rather than merely awkward, and Excel answers `#NUM!` rather than a root of a
    /// negative.
    public static let geomean = ExcelFunction(name: "GEOMEAN", minArgs: 1, maxArgs: nil) { args in
        if let error = firstError(args) { return error }
        let values = numbers(args)
        guard !values.isEmpty, values.allSatisfy({ $0 > 0 }) else { return .error(.num) }
        return finite(geometricMean(values))
    }

    /// `HARMEAN(number1, [number2], …)` — the harmonic mean.
    public static let harmean = ExcelFunction(name: "HARMEAN", minArgs: 1, maxArgs: nil) { args in
        if let error = firstError(args) { return error }
        let values = numbers(args)
        guard !values.isEmpty, values.allSatisfy({ $0 > 0 }) else { return .error(.num) }
        guard let result = try? harmonicMean(values) else { return .error(.num) }
        return finite(result)
    }

    /// `STANDARDIZE(x, mean, standard_dev)` — how many standard deviations from the mean.
    public static let standardizeFunction = ExcelFunction(
        name: "STANDARDIZE", minArgs: 3, maxArgs: 3
    ) { args in
        if let error = firstError(args) { return error }
        guard let x = BuiltinSpreadsheetStatistics.real(args[0]),
              let mean = BuiltinSpreadsheetStatistics.real(args[1]),
              let deviation = BuiltinSpreadsheetStatistics.real(args[2])
        else { return .error(.value) }
        guard deviation > 0 else { return .error(.num) }
        guard let result = try? standardize(x, mean: mean, stdDev: deviation) else {
            return .error(.num)
        }
        return finite(result)
    }

    // MARK: - Fisher's transformation

    /// `FISHER(x)` — Fisher's transformation, which is `atanh`.
    ///
    /// Defined on the open interval `(−1, 1)`: a correlation of exactly ±1 transforms to
    /// infinity, and Excel answers `#NUM!` rather than reporting one.
    public static let fisherFunction = ExcelFunction(name: "FISHER", minArgs: 1, maxArgs: 1) { args in
        if let error = firstError(args) { return error }
        guard let x = BuiltinSpreadsheetStatistics.real(args[0]) else { return .error(.value) }
        guard x > -1, x < 1 else { return .error(.num) }
        guard let result = try? fisher(x) else { return .error(.num) }
        return finite(result)
    }

    /// `FISHERINV(y)` — the inverse of ``fisherFunction``, which is `tanh`.
    public static let fisherInv = ExcelFunction(name: "FISHERINV", minArgs: 1, maxArgs: 1) { args in
        if let error = firstError(args) { return error }
        guard let y = BuiltinSpreadsheetStatistics.real(args[0]) else { return .error(.value) }
        return finite(rho(from: y))
    }

    /// `PERMUT(number, number_chosen)` — ordered arrangements, without repetition.
    ///
    /// The difference from `COMBIN` is whether order counts: `PERMUT(4, 2)` is 12 and
    /// `COMBIN(4, 2)` is 6.
    public static let permut = ExcelFunction(name: "PERMUT", minArgs: 2, maxArgs: 2) { args in
        if let error = firstError(args) { return error }
        guard let total = BuiltinSpreadsheetStatistics.real(args[0]),
              let chosen = BuiltinSpreadsheetStatistics.real(args[1]) else { return .error(.value) }
        let n = Int(total.rounded(.towardZero))
        let k = Int(chosen.rounded(.towardZero))
        guard n >= 0, k >= 0, k <= n else { return .error(.num) }
        return .number(Double(permutation(n, p: k)))
    }

    // MARK: - Inverses of the two ratio distributions

    /// `F.INV(probability, deg_freedom1, deg_freedom2)` — the **left**-tailed inverse.
    ///
    /// `F.INV.RT` was already here; this is its complement, and the two are not
    /// interchangeable at any probability but 0.5.
    public static let fInverse = ExcelFunction(name: "F.INV", minArgs: 3, maxArgs: 3) { args in
        if let error = firstError(args) { return error }
        guard let p = BuiltinSpreadsheetStatistics.real(args[0]),
              let df1 = BuiltinSpreadsheetStatistics.real(args[1]),
              let df2 = BuiltinSpreadsheetStatistics.real(args[2]) else { return .error(.value) }
        guard p >= 0, p <= 1, df1 >= 1, df2 >= 1 else { return .error(.num) }
        guard let result = try? fQuantile(p: p,
                                          df1: Int(df1.rounded(.towardZero)),
                                          df2: Int(df2.rounded(.towardZero)))
        else { return .error(.num) }
        return finite(result)
    }

    /// `T.INV(probability, deg_freedom)` — the **left**-tailed inverse of Student's t.
    ///
    /// `T.INV.2T` was already here and answers a different question: this one is signed
    /// and that one is not, so `T.INV(0.25, 2)` is negative where `T.INV.2T(0.5, 2)` is
    /// its absolute value.
    public static let tInverse = ExcelFunction(name: "T.INV", minArgs: 2, maxArgs: 2) { args in
        if let error = firstError(args) { return error }
        guard let p = BuiltinSpreadsheetStatistics.real(args[0]),
              let df = BuiltinSpreadsheetStatistics.real(args[1]) else { return .error(.value) }
        guard p > 0, p < 1, df >= 1 else { return .error(.num) }
        guard let result = try? tQuantile(p: p, df: Int(df.rounded(.towardZero)))
        else { return .error(.num) }
        return finite(result)
    }

    /// `CONFIDENCE.T(alpha, standard_dev, size)` — the half-width of a t confidence
    /// interval for a mean.
    ///
    /// The t counterpart of `CONFIDENCE.NORM`, which was already here. It is the one to
    /// use when the standard deviation came from the sample, which is nearly always.
    public static let confidenceT = ExcelFunction(
        name: "CONFIDENCE.T", minArgs: 3, maxArgs: 3
    ) { args in
        if let error = firstError(args) { return error }
        guard let alpha = BuiltinSpreadsheetStatistics.real(args[0]),
              let deviation = BuiltinSpreadsheetStatistics.real(args[1]),
              let size = BuiltinSpreadsheetStatistics.real(args[2]) else { return .error(.value) }
        guard alpha > 0, alpha < 1, deviation > 0 else { return .error(.num) }
        let n = size.rounded(.towardZero)
        // One observation leaves no degrees of freedom, so the interval is undefined
        // rather than infinite.
        guard n >= 2 else { return .error(.div0) }
        guard let t = try? tQuantile(p: 1 - alpha / 2, df: Int(n) - 1) else { return .error(.num) }
        return finite(t * deviation / n.squareRoot())
    }

    // MARK: - Shared

    /// Runs a two-series function once both series are read and checked.
    ///
    /// - Parameters:
    ///   - args: The call's arguments, the first two being the series.
    ///   - body: What to do with them, in the order they were written.
    /// - Returns: The body's answer, or the error Excel gives for the arguments.
    private static func paired(
        _ args: [CellValue],
        _ body: ([Double], [Double]) -> CellValue
    ) -> CellValue {
        if let error = firstError(args) { return error }
        let first = numbers([args[0]])
        let second = numbers([args[1]])
        // Excel is strict about this: two series of different lengths is #N/A, not a
        // correlation over whichever rows both happen to have.
        guard first.count == second.count else { return .error(.na) }
        guard first.count >= 2 else { return .error(.div0) }
        return body(first, second)
    }

    /// Every number in an argument list, flattening ranges.
    private static func numbers(_ args: [CellValue]) -> [Double] {
        BuiltinSpreadsheetStatistics.flattenNumbers(args)
    }

    /// How far apart the values are, used only to refuse a division by zero.
    private static func spread(_ values: [Double]) -> Double {
        guard let low = values.min(), let high = values.max() else { return 0 }
        return high - low
    }

    /// A result, or `#NUM!` when the arithmetic left the reals.
    private static func finite(_ value: Double) -> CellValue {
        value.isFinite ? .number(value) : .error(.num)
    }

    /// The first argument that is an error, propagated rather than absorbed.
    private static func firstError(_ args: [CellValue]) -> CellValue? {
        BuiltinSpreadsheetStatistics.firstError(args)
    }
}
