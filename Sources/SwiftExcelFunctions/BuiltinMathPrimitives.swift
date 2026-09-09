import Foundation
import SwiftExcelCore

/// The math primitives — trigonometry, hyperbolics, angles, rounding away from zero.
///
/// Master plan priority 4: *review the unreviewed before treating any of it as new work*,
/// and its expectation that *"most is math, engineering and text — largely Foundation,
/// libm and swift-numerics — so a large share should resolve to near-free."*
///
/// Measured before writing any of it: **0 of the 286** unreviewed rows already answered,
/// so none was secretly covered — and the `math` category is forty functions of which
/// these are the one-line ones.
///
/// ## Why these come from Foundation and not BusinessMath
///
/// The master plan's source table is explicit: trigonometry, logs and rounding are
/// *primitives*, and primitives come from Foundation and swift-numerics. BusinessMath owns
/// the mathematics where **a second implementation could disagree** — a distribution, a day
/// count, a financial convention. There is no second opinion about `cosh`.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinMathPrimitives.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinMathPrimitives {

    /// All math primitives for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        cosh, sinh, tanh, acosh, asinh, atanh,
        sec, csc, cot, sech, csch, coth, acot, acoth,
        degrees, radians, even, odd, sqrtPi, quotient
    ]

    // MARK: - Plumbing

    /// A one-argument numeric function.
    ///
    /// - Parameters:
    ///   - name: the Excel name.
    ///   - body: the computation, returning `nil` where the result does not exist.
    ///   - failure: what Excel answers when it does not. `#NUM!` for a domain error —
    ///     Excel's answer for a computation with no result — and `#DIV/0!` where the
    ///     definition divides by zero.
    static func unary(
        _ name: String,
        failure: ExcelError = .num,
        _ body: @escaping @Sendable (Double) -> Double?
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 1, maxArgs: 1) { values in
            if let error = values.first, case .error = error { return error }
            guard let x = real(values.first) else { return .error(.value) }
            guard let result = body(x), result.isFinite else { return .error(failure) }
            return .number(result)
        }
    }

    /// A finite number from a cell value, or `nil`.
    ///
    /// Booleans coerce, as they do everywhere in Excel: `TRUE` is 1. Text does not, which
    /// is `#VALUE!` rather than a silent zero.
    static func real(_ value: CellValue?) -> Double? {
        switch value {
        case .number(let d): return d.isFinite ? d : nil
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    // MARK: - Hyperbolic

    /// `COSH(number)` — the hyperbolic cosine. Microsoft: `COSH(4)` is 27.30823.
    public static let cosh = unary("COSH") { Foundation.cosh($0) }

    /// `SINH(number)` — the hyperbolic sine. Microsoft: `SINH(1)` is 1.175201194.
    public static let sinh = unary("SINH") { Foundation.sinh($0) }

    /// `TANH(number)` — the hyperbolic tangent. Microsoft: `TANH(-2)` is -0.96403.
    public static let tanh = unary("TANH") { Foundation.tanh($0) }

    /// `ACOSH(number)` — the inverse hyperbolic cosine. Microsoft: `ACOSH(10)` is 2.993223.
    ///
    /// Defined only for `number ≥ 1`; below that Excel answers `#NUM!` rather than a NaN.
    public static let acosh = unary("ACOSH") { $0 >= 1 ? Foundation.acosh($0) : nil }

    /// `ASINH(number)` — the inverse hyperbolic sine. Microsoft: `ASINH(-2.5)` is -1.647231.
    public static let asinh = unary("ASINH") { Foundation.asinh($0) }

    /// `ATANH(number)` — the inverse hyperbolic tangent, defined on `(-1, 1)`.
    ///
    /// The bound is strict. At exactly ±1 the true value is infinite, and Excel reports
    /// `#NUM!` rather than an infinity a later cell would carry into an average.
    public static let atanh = unary("ATANH") { abs($0) < 1 ? Foundation.atanh($0) : nil }

    // MARK: - Reciprocal trigonometry

    /// `SEC(number)` — `1/COS(number)`, by Microsoft's own definition.
    public static let sec = unary("SEC", failure: .div0) { reciprocal(Foundation.cos($0)) }

    /// `CSC(number)` — `1/SIN(number)`. `#DIV/0!` at multiples of π, where the sine is zero.
    public static let csc = unary("CSC", failure: .div0) { reciprocal(Foundation.sin($0)) }

    /// `COT(number)` — `1/TAN(number)`. `#DIV/0!` at zero.
    public static let cot = unary("COT", failure: .div0) { reciprocal(Foundation.tan($0)) }

    /// `SECH(number)` — `1/COSH(number)`. Never divides by zero: `cosh` is at least 1.
    public static let sech = unary("SECH", failure: .div0) { reciprocal(Foundation.cosh($0)) }

    /// `CSCH(number)` — `1/SINH(number)`. `#DIV/0!` at zero.
    public static let csch = unary("CSCH", failure: .div0) { reciprocal(Foundation.sinh($0)) }

    /// `COTH(number)` — `1/TANH(number)`. `#DIV/0!` at zero.
    public static let coth = unary("COTH", failure: .div0) { reciprocal(Foundation.tanh($0)) }

    /// `ACOT(number)` — the inverse cotangent, in the principal range `(0, π)`.
    ///
    /// **Not `ATAN(1/x)`.** That returns a negative angle for a negative argument, and
    /// Excel's `ACOT` does not — its range is the open interval `(0, π)` throughout, so
    /// `ACOT(-2)` is just under π rather than just under zero. Adding π to the negative
    /// branch is what makes the two agree.
    /// `ACOT(0)` is `π/2`, and it is written out rather than reached through `1/0`.
    /// IEEE would arrive at the right answer — `atan(+∞)` is `π/2` — but a division whose
    /// correctness depends on infinity propagating is one nobody can check by reading it.
    public static let acot = unary("ACOT") { x in
        guard x != 0 else { return Double.pi / 2 }
        let angle = Foundation.atan(1 / x)
        return x < 0 ? angle + Double.pi : angle
    }

    /// `ACOTH(number)` — the inverse hyperbolic cotangent, defined where `|number| > 1`.
    ///
    /// `½·ln((x+1)/(x−1))`, which is Microsoft's documented formula. The bound is strict:
    /// at exactly ±1 the logarithm's argument is zero or infinite.
    public static let acoth = unary("ACOTH") { x in
        abs(x) > 1 ? 0.5 * Foundation.log((x + 1) / (x - 1)) : nil
    }

    /// `1/x`, or `nil` where that does not exist.
    private static func reciprocal(_ x: Double) -> Double? {
        x == 0 ? nil : 1 / x
    }

    // MARK: - Angles

    /// Degrees in one radian: `180/π`, to the full precision a `Double` holds.
    ///
    /// Written as a constant rather than computed, so both conversions are a
    /// multiplication. `180/π` cannot be zero, but a division written per call asks every
    /// reader — and every auditor — to prove that again, and the proof is not local to the
    /// line it appears on.
    private static let degreesPerRadian = 57.295_779_513_082_320_877

    /// Radians in one degree: `π/180`.
    private static let radiansPerDegree = 0.017_453_292_519_943_295_769

    /// `DEGREES(angle)` — radians to degrees. Microsoft: `DEGREES(PI())` is 180.
    public static let degrees = unary("DEGREES") { $0 * degreesPerRadian }

    /// `RADIANS(angle)` — degrees to radians. Microsoft: `RADIANS(270)` is 4.712389.
    public static let radians = unary("RADIANS") { $0 * radiansPerDegree }

    // MARK: - Rounding away from zero

    /// `EVEN(number)` — rounded away from zero to the next even integer.
    ///
    /// **Away from zero, not up.** Microsoft: `EVEN(-1)` is -2, not 0 — which is the whole
    /// difference between this and a ceiling, and the reason it cannot be written as one.
    public static let even = unary("EVEN") { roundAwayFromZero($0, toOddMultiple: false) }

    /// `ODD(number)` — rounded away from zero to the next odd integer.
    ///
    /// Microsoft: `ODD(2)` is 3, `ODD(-1)` is -1, and `ODD(0)` is 1 — zero rounds *up* to
    /// one because there is no odd zero to stay at.
    public static let odd = unary("ODD") { roundAwayFromZero($0, toOddMultiple: true) }

    /// Rounds away from zero to the next integer of the requested parity.
    private static func roundAwayFromZero(_ x: Double, toOddMultiple odd: Bool) -> Double {
        if x == 0 { return odd ? 1 : 0 }
        let sign: Double = x < 0 ? -1 : 1
        let magnitude = abs(x)
        // Step onto the parity's grid, round away from zero, step back.
        let offset: Double = odd ? 1 : 0
        let stepped = ((magnitude - offset) / 2).rounded(.up) * 2 + offset
        return sign * stepped
    }

    // MARK: - The rest

    /// `SQRTPI(number)` — `SQRT(number × PI())`, by Microsoft's definition.
    ///
    /// Negative input is `#NUM!`: the square root of a negative has no real result, and
    /// Excel says so rather than answering NaN.
    public static let sqrtPi = unary("SQRTPI") { $0 >= 0 ? ($0 * Double.pi).squareRoot() : nil }

    /// `QUOTIENT(numerator, denominator)` — the integer part of a division.
    ///
    /// The fractional part is **discarded**, not rounded. Microsoft: `QUOTIENT(-10, 3)` is
    /// -3, where rounding would give -3.33 → -3 either way but `QUOTIENT(-11, 3)` is -3
    /// and a rounded division would be -4. Truncation is toward zero.
    public static let quotient = ExcelFunction(name: "QUOTIENT", minArgs: 2, maxArgs: 2) { values in
        if let error = values.first(where: { if case .error = $0 { return true } else { return false } }) {
            return error
        }
        guard let numerator = real(values.first), let denominator = real(values.dropFirst().first)
        else { return .error(.value) }
        guard denominator != 0 else { return .error(.div0) }
        return .number((numerator / denominator).rounded(.towardZero))
    }
}
