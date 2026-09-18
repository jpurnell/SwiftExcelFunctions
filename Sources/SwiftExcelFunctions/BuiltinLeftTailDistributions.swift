import Foundation
#if canImport(os)
import os
#endif
import SwiftExcelCore
import BusinessMath

/// The three left-tail distributions, and the regression family.
///
/// `CHISQ.DIST`, `T.DIST`, `F.DIST`, `LINEST`, `TREND`, `LOGEST` and `GROWTH`.
///
/// ## Left tails, from right tails that already exist
///
/// Each of the three has a `.RT` sibling in this package already, tested and in use. The
/// cumulative form is `1 − RT`, so it is composed rather than reimplemented: a second path to
/// a chi-squared CDF is a second set of answers, and the incomplete gamma is not somewhere to
/// keep two opinions.
///
/// `T.DIST` needs one turn of thought the others do not. `T.DIST.RT` is defined for `x ≥ 0`,
/// and `T.DIST` is asked for any `x`, so the negative half comes from the distribution's
/// symmetry: `CDF(−x) = RT(x)`.
public enum BuiltinLeftTailDistributions {

    /// Everything here, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        chiSquaredDist, tDist, fDist, linest, trend, logest, growth
    ]

    // MARK: - Distributions

    /// `CHISQ.DIST(x, deg_freedom, cumulative)` — the **left**-tailed chi-squared.
    ///
    /// Not `CHIDIST`, which is an alias of the right tail and answers the complement.
    public static let chiSquaredDist = ExcelFunction(
        name: "CHISQ.DIST", minArgs: 3, maxArgs: 3
    ) { args in
        if let error = args.first(where: isError) { return error }
        guard let x = real(args[0]), let df = whole(args[1]) else { return .error(.value) }
        guard x >= 0, df >= 1 else { return .error(.num) }

        guard truthy(args[2]) else {
            // **Written out rather than bound to BusinessMath's `chi2pdf`, which is wrong.**
            // At x = 0.5, df = 1 it answers 0.5022974900306464 where the definition gives
            // 0.4393912894677224 — 14% out, not a rounding. Checked the same way the Bessel
            // dispute was: against the closed form, which for a chi-squared density is not in
            // doubt. `studentTPDF` was checked too and agrees to 1e-16, so this is one
            // function rather than a reason to distrust the module.
            //
            // Reported upstream; rebind when it is fixed.
            let k = Double(df)
            guard x > 0 else {
                // At zero the density is unbounded below two degrees of freedom, exactly ½ at
                // two, and zero above. Compared as integers, which is what `df` is — an
                // equality on the `Double` would be asking the wrong question of the value.
                if df < 2 { return .error(.num) }
                return .number(df == 2 ? 0.5 : 0)
            }
            let logDensity = -(k / 2) * Foundation.log(2) - logGamma(k / 2)
                + (k / 2 - 1) * Foundation.log(x) - x / 2
            return finite(Foundation.exp(logDensity))
        }
        return complementOf(BuiltinStatisticalDistributions.chiSquaredDistRightTail,
                            [.number(x), .number(Double(df))])
    }

    /// `T.DIST(x, deg_freedom, cumulative)` — the **left**-tailed Student's t.
    public static let tDist = ExcelFunction(name: "T.DIST", minArgs: 3, maxArgs: 3) { args in
        if let error = args.first(where: isError) { return error }
        guard let x = real(args[0]), let df = whole(args[1]) else { return .error(.value) }
        guard df >= 1 else { return .error(.num) }

        guard truthy(args[2]) else {
            guard let density = try? studentTPDF(t: x, df: df) else {
                return .error(.num)
            }
            return finite(density)
        }
        // `T.DIST.RT` is defined for non-negative t. Below zero the symmetry gives the answer
        // directly: the left tail at −x is the right tail at x.
        guard x < 0 else {
            return complementOf(BuiltinSpreadsheetStatistics.tDistRightTail,
                                [.number(x), .number(Double(df))])
        }
        return (try? BuiltinSpreadsheetStatistics.tDistRightTail.evaluate(
            [.number(-x), .number(Double(df))])) ?? .error(.num)
    }

    /// `F.DIST(x, deg_freedom1, deg_freedom2, cumulative)` — the **left**-tailed F.
    ///
    /// The density is written out rather than composed, because no `fPDF` exists to compose
    /// with. Through log-gamma, so the ratio of large factorials never forms: at moderate
    /// degrees of freedom the direct expression overflows while the answer is an ordinary
    /// number near zero.
    public static let fDist = ExcelFunction(name: "F.DIST", minArgs: 4, maxArgs: 4) { args in
        if let error = args.first(where: isError) { return error }
        guard let x = real(args[0]), let d1 = whole(args[1]), let d2 = whole(args[2]) else {
            return .error(.value)
        }
        guard x >= 0, d1 >= 1, d2 >= 1 else { return .error(.num) }

        guard truthy(args[3]) else {
            guard x > 0 else { return .number(0) }
            let n1 = Double(d1), n2 = Double(d2)
            let logDensity =
                (n1 / 2) * Foundation.log(n1) + (n2 / 2) * Foundation.log(n2)
                + (n1 / 2 - 1) * Foundation.log(x)
                - ((n1 + n2) / 2) * Foundation.log(n2 + n1 * x)
                + logGamma((n1 + n2) / 2) - logGamma(n1 / 2) - logGamma(n2 / 2)
            return finite(Foundation.exp(logDensity))
        }
        return complementOf(BuiltinStatisticalDistributions.fDistRightTail,
                            [.number(x), .number(Double(d1)), .number(Double(d2))])
    }

    // MARK: - Regression

    /// `LINEST(known_y, [known_x])` — the slope and intercept of a least-squares line.
    ///
    /// Excel returns them **in that order, slope first**, as a 1×2 array — which reads
    /// backwards to anyone expecting `y = mx + c` written left to right, and is what a
    /// workbook's `INDEX(LINEST(…), 1, 1)` depends on.
    ///
    /// The full form returns a 5×2 block of regression statistics. This returns the
    /// coefficients only; the statistics rows are not implemented and a caller asking for
    /// them would need `stats` support this does not have.
    public static let linest = ExcelFunction(name: "LINEST", minArgs: 1, maxArgs: 2) { args in
        fitted(args) { xs, ys in
            do {
                return [try slope(xs, ys), try intercept(xs, ys)]
            } catch {
                // BusinessMath refuses data it cannot fit — fewer than two points, or an `x`
                // with no variance. Excel answers `#NUM!` for the same, which `fitted` turns
                // this `nil` into.
                #if canImport(os)
                Logger(subsystem: "SwiftExcelFunctions", category: "regression")
                    .error("LINEST could not fit: \(String(describing: error), privacy: .public)")
                #endif
                return nil
            }
        }
    }

    /// `LOGEST(known_y, [known_x])` — the same, fitted to `y = b · mˣ`.
    ///
    /// The exponential fit is a linear fit of `ln y`, and the coefficients come back
    /// exponentiated. Every `y` must be positive, because the logarithm is where the fit
    /// happens.
    public static let logest = ExcelFunction(name: "LOGEST", minArgs: 1, maxArgs: 2) { args in
        fitted(args) { xs, ys in
            guard ys.allSatisfy({ $0 > 0 }) else { return nil }
            let logs = ys.map { Foundation.log($0) }
            do {
                return [Foundation.exp(try slope(xs, logs)),
                        Foundation.exp(try intercept(xs, logs))]
            } catch {
                #if canImport(os)
                Logger(subsystem: "SwiftExcelFunctions", category: "regression")
                    .error("LOGEST could not fit: \(String(describing: error), privacy: .public)")
                #endif
                return nil
            }
        }
    }

    /// `TREND(known_y, [known_x], [new_x])` — the fitted line evaluated at points.
    public static let trend = ExcelFunction(name: "TREND", minArgs: 1, maxArgs: 3) { args in
        projected(args) { m, c, x in m * x + c }
    }

    /// `GROWTH(known_y, [known_x], [new_x])` — the fitted exponential evaluated at points.
    public static let growth = ExcelFunction(name: "GROWTH", minArgs: 1, maxArgs: 3) { args in
        projected(args, logarithmic: true) { m, c, x in
            Foundation.exp(c) * Foundation.exp(m * x)
        }
    }

    // MARK: - Plumbing

    /// `1 − f(args)`, for turning a right tail into a left one.
    private static func complementOf(
        _ function: ExcelFunction, _ args: [CellValue]
    ) -> CellValue {
        guard let result = try? function.evaluate(args) else { return .error(.num) }
        guard case .number(let tail) = result else { return result }
        return finite(1 - tail)
    }

    /// `LINEST` and `LOGEST`: fit, then return the coefficients as a 1×2 row.
    private static func fitted(
        _ args: [CellValue], _ body: ([Double], [Double]) -> [Double]?
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        let ys = flatten([args[0]]).compactMap(real)
        // An omitted `known_x` is 1, 2, 3, … — the positions themselves, which is Excel's
        // default and the reason a single column of data fits a line at all.
        let xs = args.count > 1
            ? flatten([args[1]]).compactMap(real)
            : (1...Swift.max(ys.count, 1)).map(Double.init)
        guard xs.count == ys.count, ys.count >= 2 else { return .error(.ref) }
        guard let coefficients = body(xs, ys) else { return .error(.num) }
        return shaped(coefficients.map { CellValue.number($0) }, rows: 1,
                      columns: coefficients.count)
    }

    /// `TREND` and `GROWTH`: fit, then evaluate at each new point.
    private static func projected(
        _ args: [CellValue], logarithmic: Bool = false,
        _ body: (Double, Double, Double) -> Double
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        let rawYs = flatten([args[0]]).compactMap(real)
        let xs = args.count > 1 && !flatten([args[1]]).isEmpty
            ? flatten([args[1]]).compactMap(real)
            : (1...Swift.max(rawYs.count, 1)).map(Double.init)
        guard xs.count == rawYs.count, rawYs.count >= 2 else { return .error(.ref) }

        if logarithmic && !rawYs.allSatisfy({ $0 > 0 }) { return .error(.num) }
        let ys = logarithmic ? rawYs.map { Foundation.log($0) } : rawYs
        let m: Double, c: Double
        do {
            m = try slope(xs, ys)
            c = try intercept(xs, ys)
        } catch {
            #if canImport(os)
            Logger(subsystem: "SwiftExcelFunctions", category: "regression")
                .error("could not fit: \(String(describing: error), privacy: .public)")
            #endif
            return .error(.num)
        }

        // No new points means "fit the ones given", which is how these are used to draw a
        // trend line over the data it came from.
        let targets = args.count > 2 ? flatten([args[2]]).compactMap(real) : xs
        guard !targets.isEmpty else { return .error(.value) }
        let values = targets.map { CellValue.number(body(m, c, $0)) }
        return shaped(values, rows: values.count, columns: 1)
    }

    /// `log Γ(x)`.
    ///
    /// Foundation's, rather than a series written here: the F density needs it only to keep a
    /// ratio of large gammas from overflowing, and a second implementation of log-gamma would
    /// be a second set of answers in a package that already has one.
    private static func logGamma(_ x: Double) -> Double {
        var sign: Int32 = 1
        return lgamma_r(x, &sign)
    }

    private static func isError(_ value: CellValue) -> Bool {
        if case .error = value { return true }
        return false
    }

    private static func real(_ value: CellValue) -> Double? {
        BuiltinMathPrimitives.real(value)
    }

    private static func whole(_ value: CellValue) -> Int? {
        guard let number = real(value) else { return nil }
        return Int(exactly: number.rounded(.towardZero))
    }

    private static func truthy(_ value: CellValue) -> Bool {
        switch value {
        case .bool(let flag): return flag
        case .number(let number): return number != 0
        default: return false
        }
    }

    private static func finite(_ value: Double) -> CellValue {
        value.isFinite ? .number(value) : .error(.num)
    }

    private static func shaped(_ elements: [CellValue], rows: Int, columns: Int) -> CellValue {
        guard let matrix = CellMatrix(elements: elements, rows: rows, columns: columns) else {
            return .error(.value)
        }
        return .array(matrix)
    }

    private static func flatten(_ args: [CellValue]) -> [CellValue] {
        var out: [CellValue] = []
        for value in args {
            if case .array(let matrix) = value {
                out.append(contentsOf: flatten(matrix.elements))
            } else {
                out.append(value)
            }
        }
        return out
    }
}
