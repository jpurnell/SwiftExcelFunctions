import Foundation
import SwiftExcelCore

/// Rounding to a multiple, and the four functions Excel has for it.
///
/// `CEILING.MATH`, `CEILING.PRECISE`, `FLOOR.MATH`, `FLOOR.PRECISE`, `ISO.CEILING` and
/// `MROUND`. They differ in one thing — **what a negative number does** — and Excel's answer
/// is genuinely inconsistent between them, because they arrived in different decades.
///
/// | | negative number, positive significance |
/// |---|---|
/// | `CEILING.PRECISE` / `ISO.CEILING` | **up**, toward zero: `-4.5` to `-4` |
/// | `CEILING.MATH`, no mode | the same |
/// | `CEILING.MATH`, mode ≠ 0 | **away** from zero: `-4.5` to `-5` |
/// | `MROUND` | to the nearest, ties away from zero |
///
/// The `PRECISE` pair ignore the sign of the significance entirely; `.MATH` takes its
/// absolute value too but then lets `mode` decide the direction. Writing them as one function
/// with flags would hide exactly the distinction a caller needs.
public enum BuiltinMathRounding {

    /// Every rounding-to-a-multiple function, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        ceilingMath, ceilingPrecise, isoCeiling, floorMath, floorPrecise, mround
    ]

    /// `CEILING.MATH(number, [significance], [mode])` — up to a multiple.
    ///
    /// Significance defaults to 1. A non-zero `mode` rounds a negative number *away* from
    /// zero rather than toward it, which is the only thing `mode` does and the only reason
    /// this differs from `CEILING.PRECISE`.
    public static let ceilingMath = ExcelFunction(
        name: "CEILING.MATH", minArgs: 1, maxArgs: 3
    ) { args in
        rounded(args, awayFromZeroWhenNegative: mode(args, at: 2)) { $0.rounded(.up) }
    }

    /// `CEILING.PRECISE(number, [significance])` — up, whatever the signs.
    ///
    /// "Precise" means the significance's sign is ignored: `CEILING.PRECISE(-4.5, -2)` is
    /// `-4`, the same as with `+2`. Up is toward positive infinity, so a negative number
    /// moves toward zero.
    public static let ceilingPrecise = ExcelFunction(
        name: "CEILING.PRECISE", minArgs: 1, maxArgs: 2
    ) { args in
        rounded(args, awayFromZeroWhenNegative: false) { $0.rounded(.up) }
    }

    /// `ISO.CEILING(number, [significance])` — `CEILING.PRECISE` under its other name.
    ///
    /// Excel ships both and they compute the same thing. Kept as a separate registration
    /// rather than an alias, because a workbook that says `ISO.CEILING` should read back
    /// saying `ISO.CEILING`.
    public static let isoCeiling = ExcelFunction(
        name: "ISO.CEILING", minArgs: 1, maxArgs: 2
    ) { args in
        rounded(args, awayFromZeroWhenNegative: false) { $0.rounded(.up) }
    }

    /// `FLOOR.MATH(number, [significance], [mode])` — down to a multiple.
    public static let floorMath = ExcelFunction(
        name: "FLOOR.MATH", minArgs: 1, maxArgs: 3
    ) { args in
        rounded(args, awayFromZeroWhenNegative: mode(args, at: 2)) { $0.rounded(.down) }
    }

    /// `FLOOR.PRECISE(number, [significance])` — down, whatever the signs.
    public static let floorPrecise = ExcelFunction(
        name: "FLOOR.PRECISE", minArgs: 1, maxArgs: 2
    ) { args in
        rounded(args, awayFromZeroWhenNegative: false) { $0.rounded(.down) }
    }

    /// `MROUND(number, multiple)` — to the *nearest* multiple, ties away from zero.
    ///
    /// The one that refuses rather than guessing: Excel answers `#NUM!` when the number and
    /// the multiple have opposite signs, because there is no nearest multiple in the
    /// direction asked for. A zero multiple is 0, not a division by zero.
    public static let mround = ExcelFunction(name: "MROUND", minArgs: 2, maxArgs: 2) { args in
        if let error = args.first(where: isError) { return error }
        guard let number = BuiltinMathPrimitives.real(args[0]),
              let multiple = BuiltinMathPrimitives.real(args[1]) else { return .error(.value) }
        guard multiple != 0 else { return .number(0) }
        guard number == 0 || (number > 0) == (multiple > 0) else { return .error(.num) }
        return .number((number / multiple).rounded(.toNearestOrAwayFromZero) * multiple)
    }

    // MARK: - Plumbing

    private static func isError(_ value: CellValue) -> Bool {
        if case .error = value { return true }
        return false
    }

    /// The `mode` flag, which is present only on the `.MATH` pair.
    private static func mode(_ args: [CellValue], at index: Int) -> Bool {
        guard args.count > index,
              let flag = BuiltinMathPrimitives.real(args[index]) else { return false }
        return flag != 0
    }

    /// Rounds to a multiple in a given direction.
    ///
    /// - Parameters:
    ///   - args: number, then optional significance.
    ///   - awayFromZeroWhenNegative: the `.MATH` family's `mode`. A negative number is
    ///     reflected, rounded, and reflected back, which turns "up" into "away from zero".
    ///   - direction: `.up` or `.down`, applied to the quotient.
    private static func rounded(
        _ args: [CellValue],
        awayFromZeroWhenNegative: Bool,
        _ direction: (Double) -> Double
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        guard let number = BuiltinMathPrimitives.real(args[0]) else { return .error(.value) }

        // Significance defaults to 1, and its sign never matters: every one of these takes
        // its magnitude. A zero significance is 0 rather than a division by zero, which is
        // what Excel answers and is the only sensible multiple of nothing.
        let significance: Double
        if args.count > 1 {
            guard let given = BuiltinMathPrimitives.real(args[1]) else { return .error(.value) }
            significance = Swift.abs(given)
        } else {
            significance = 1
        }
        guard significance != 0 else { return .number(0) }

        let reflect = awayFromZeroWhenNegative && number < 0
        let subject = reflect ? -number : number
        let rounded = direction(subject / significance) * significance
        return .number(reflect ? -rounded : rounded)
    }
}
