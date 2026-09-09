import Foundation
import SwiftExcelCore
import BusinessMath

/// The gamma pair, the standard-normal helpers, the modes, and two counting functions.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinGammaAndModes.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinGammaAndModes {

    /// All of these for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        gamma, gammaLnPrecise, gauss, phi,
        permutationA, binomDistRange, modeSingle, modeMultiple, percentRankExclusive
    ]

    // MARK: - Gamma

    /// `GAMMA(x)` — the gamma function, which extends the factorial: `Γ(n) = (n−1)!`.
    ///
    /// Undefined at zero and every negative integer, where it has a pole. Excel answers
    /// `#NUM!` there rather than an infinity that a later cell would carry into a sum
    /// without complaint. A *non-integer* negative is defined and often negative.
    public static let gamma = ExcelFunction(name: "GAMMA", minArgs: 1, maxArgs: 1) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first) else { return .error(.value) }
        // The poles: zero and the negative integers.
        guard !(x <= 0 && x.rounded() == x) else { return .error(.num) }
        let result = Foundation.tgamma(x)
        guard result.isFinite else { return .error(.num) }
        return .number(result)
    }

    /// `GAMMALN.PRECISE(x)` — `ln(Γ(x))`, defined for positive `x` only.
    ///
    /// Exists precisely where `GAMMA` overflows: `Γ(200)` is past a `Double`'s range and
    /// its logarithm is an ordinary number.
    public static let gammaLnPrecise = ExcelFunction(
        name: "GAMMALN.PRECISE", minArgs: 1, maxArgs: 1
    ) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first) else { return .error(.value) }
        guard x > 0 else { return .error(.num) }
        // Annotated because `lgamma` has two overloads — one returning `Double`, one
        // returning `(Double, Int)` with the sign of Γ. For positive `x`, Γ is positive
        // and the sign carries nothing, so the scalar form is the one wanted.
        let result: Double = Foundation.lgamma(x)
        guard result.isFinite else { return .error(.num) }
        return .number(result)
    }

    // MARK: - Standard normal helpers

    /// `GAUSS(z)` — the probability between the mean and `z`, which is `Φ(z) − ½`.
    ///
    /// **Not the cumulative.** At zero it is 0 where the CDF is 0.5, and it is odd about
    /// the origin. Returning the CDF instead gives a number in `[0, 1]` that is plausible
    /// everywhere and correct nowhere except by accident.
    public static let gauss = ExcelFunction(name: "GAUSS", minArgs: 1, maxArgs: 1) { values in
        if let error = firstError(values) { return error }
        guard let z = real(values.first) else { return .error(.value) }
        return .number(normalCDF(x: z) - 0.5)
    }

    /// `PHI(x)` — the standard normal **density**, `e^(−x²/2)/√(2π)`.
    public static let phi = ExcelFunction(name: "PHI", minArgs: 1, maxArgs: 1) { values in
        if let error = firstError(values) { return error }
        guard let x = real(values.first) else { return .error(.value) }
        return .number(Foundation.exp(-x * x / 2) / (2 * Double.pi).squareRoot())
    }

    // MARK: - Counting

    /// `PERMUTATIONA(number, number_chosen)` — arrangements **with** repetition, `n^k`.
    ///
    /// `PERMUT` counts arrangements *without* repetition and is the falling factorial. The
    /// two agree at `k ≤ 1` and diverge immediately after, which is what makes picking the
    /// wrong one hard to notice on a small example.
    public static let permutationA = ExcelFunction(
        name: "PERMUTATIONA", minArgs: 2, maxArgs: 2
    ) { values in
        if let error = firstError(values) { return error }
        guard let n = real(values.first), let k = real(values.dropFirst().first)
        else { return .error(.value) }
        guard n >= 0, k >= 0 else { return .error(.num) }
        let result = Foundation.pow(n.rounded(.towardZero), k.rounded(.towardZero))
        guard result.isFinite else { return .error(.num) }
        return .number(result)
    }

    /// `BINOM.DIST.RANGE(trials, probability_s, number_s, [number_s2])` — the mass summed
    /// over an inclusive range of success counts.
    ///
    /// With no upper bound it is a single mass. Over the whole support it is exactly 1,
    /// which is the relationship the tests assert rather than any particular total.
    public static let binomDistRange = ExcelFunction(
        name: "BINOM.DIST.RANGE", minArgs: 3, maxArgs: 4
    ) { values in
        if let error = firstError(values) { return error }
        guard let trials = real(values.first), let probability = real(values[1]),
              let from = real(values[2]) else { return .error(.value) }
        let to = values.count > 3 ? real(values[3]) : from
        guard let to else { return .error(.value) }

        guard trials >= 0, probability >= 0, probability <= 1,
              from >= 0, to >= from, to <= trials else { return .error(.num) }

        let n = Int(trials.rounded(.towardZero))
        var total = 0.0
        for k in Int(from.rounded(.towardZero))...Int(to.rounded(.towardZero)) {
            total += binomialPMF(n: n, k: k, p: probability)
        }
        return .number(Swift.min(total, 1))
    }

    // MARK: - Modes

    /// Every value tied for most frequent, in the order they first appear.
    ///
    /// First-appearance order rather than sorted, because `MODE.SNGL` is documented as the
    /// *first* mode and the two spellings must agree about which that is.
    static func modes(of data: [Double]) -> [Double] {
        var counts: [Double: Int] = [:]
        var order: [Double] = []
        for value in data {
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
        guard let best = counts.values.max(), best > 1 else { return [] }
        return order.filter { counts[$0] == best }
    }

    /// `MODE.SNGL(number1, …)` — the most frequent value, the first when several tie.
    ///
    /// No value repeating is `#N/A` rather than zero: a set with no mode has no answer, and
    /// zero is a value the data might legitimately contain.
    public static let modeSingle = ExcelFunction(
        name: "MODE.SNGL", minArgs: 1, maxArgs: nil
    ) { values in
        if let error = firstError(values) { return error }
        guard let first = modes(of: flattenNumbers(values)).first else { return .error(.na) }
        return .number(first)
    }

    /// `MODE.MULT(number1, …)` — every tied mode.
    public static let modeMultiple = ExcelFunction(
        name: "MODE.MULT", minArgs: 1, maxArgs: nil
    ) { values in
        if let error = firstError(values) { return error }
        let found = modes(of: flattenNumbers(values))
        guard !found.isEmpty else { return .error(.na) }
        return .array(CellMatrix(column: found.map { CellValue.number($0) }))
    }

    // MARK: - Exclusive percent rank

    /// `PERCENTRANK.EXC(array, x, [significance])` — the rank on the `1/(n+1)` convention.
    ///
    /// Neither endpoint reaches 0 or 1, which is the same exclusion `QUARTILE.EXC` applies
    /// and the whole difference from `PERCENTRANK.INC`.
    public static let percentRankExclusive = ExcelFunction(
        name: "PERCENTRANK.EXC", minArgs: 2, maxArgs: 3
    ) { values in
        if let error = firstError(values) { return error }
        let data = flattenNumbers(Array(values.prefix(1))).sorted()
        guard let x = real(values[1]), data.count >= 1 else { return .error(.num) }
        guard let first = data.first, let last = data.last, x >= first, x <= last
        else { return .error(.na) }

        let span = Double(data.count + 1)
        guard span > 0 else { return .error(.div0) }
        guard let index = data.lastIndex(where: { $0 <= x }) else { return .error(.na) }

        let below = data[index]
        let above = index + 1 < data.count ? data[index + 1] : below
        let gap = above - below
        let within = gap == 0 ? 0 : (x - below) / gap
        return .number((Double(index + 1) + within) / span)
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

    /// Every number in an argument list, flattening arrays.
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
