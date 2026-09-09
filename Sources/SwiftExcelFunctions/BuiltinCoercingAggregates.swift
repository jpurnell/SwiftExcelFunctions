import Foundation
import SwiftExcelCore
import BusinessMath

/// The `A`-suffixed aggregates — `AVERAGEA`, `MAXA`, `MINA`, `STDEVA`, `STDEVPA`, `VARA`,
/// `VARPA`.
///
/// ## One rule, seven functions
///
/// These are not new mathematics. Each is its plain counterpart under a **different
/// coercion rule**, and the rule is the whole content: `AVERAGE` skips text and logicals
/// inside a range, `AVERAGEA` counts text as 0, `TRUE` as 1 and `FALSE` as 0. The
/// arithmetic afterwards is identical and is delegated to the same upstream functions the
/// plain versions use.
///
/// Microsoft, on the family: *"Arguments that contain TRUE evaluate as 1; arguments that
/// contain text or FALSE evaluate as 0 (zero). Empty cells are ignored."*
///
/// The consequence people trip over is that text is an **observation**, not an omission.
/// `AVERAGEA(10, "n/a", 20)` is 10 rather than 15, because the label is a third value worth
/// nothing — and `MINA` over positive numbers with a label among them is 0.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinCoercingAggregates.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinCoercingAggregates {

    /// All coercing aggregates for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        averageA, maxA, minA, stdDevA, stdDevPA, varA, varPA
    ]

    /// Every value an argument list contributes, under the `A` rule.
    ///
    /// The rule in one place, because seven functions share it and a second copy could
    /// drift. Note what it does **not** do: a blank is skipped rather than counted as zero,
    /// which is the one point where the `A` variants agree with their plain counterparts.
    /// Counting blanks would make a sparse column's mean collapse toward zero.
    static func coercedValues(_ args: [CellValue]) -> [Double] {
        var result: [Double] = []
        for arg in args {
            switch arg {
            case .number(let n): result.append(n)
            case .bool(let b): result.append(b ? 1 : 0)
            case .text: result.append(0)
            case .date(let d): result.append(d.timeIntervalSince1970)
            case .array(let matrix): result.append(contentsOf: coercedValues(matrix.elements))
            case .blank, .error, .formula: continue
            }
        }
        return result
    }

    /// Builds an aggregate over the coerced values.
    ///
    /// - Parameters:
    ///   - name: the Excel name.
    ///   - minimumCount: how many observations the statistic needs. Two for the sample
    ///     forms, whose `n − 1` denominator is zero at one observation.
    ///   - body: the statistic itself.
    static func aggregate(
        _ name: String,
        minimumCount: Int = 1,
        _ body: @escaping @Sendable ([Double]) -> Double
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 1, maxArgs: nil) { values in
            if let error = firstError(values) { return error }
            let numbers = coercedValues(values)
            guard numbers.count >= minimumCount else { return .error(.div0) }
            let result = body(numbers)
            guard result.isFinite else { return .error(.num) }
            return .number(result)
        }
    }

    /// `AVERAGEA(value1, …)` — the mean, with text as zero.
    ///
    /// `AVERAGEA(10, "n/a", 20)` is 10, not 15: the label is an observation.
    public static let averageA = aggregate("AVERAGEA") { mean($0) }

    /// `MAXA(value1, …)` — the largest coerced value.
    ///
    /// `TRUE` counts as 1, so it can be the maximum of a set of fractions.
    public static let maxA = aggregate("MAXA") { $0.max() ?? 0 }

    /// `MINA(value1, …)` — the smallest coerced value.
    ///
    /// Text counts as 0, so a label among positive numbers *becomes* the minimum. That is
    /// the case this function is most often used by accident rather than on purpose.
    public static let minA = aggregate("MINA") { $0.min() ?? 0 }

    /// `STDEVA(value1, …)` — the **sample** standard deviation, with text as zero.
    public static let stdDevA = aggregate("STDEVA", minimumCount: 2) { stdDevS($0) }

    /// `STDEVPA(value1, …)` — the **population** standard deviation, with text as zero.
    public static let stdDevPA = aggregate("STDEVPA") { stdDevP($0) }

    /// `VARA(value1, …)` — the **sample** variance, with text as zero.
    public static let varA = aggregate("VARA", minimumCount: 2) { varianceS($0) }

    /// `VARPA(value1, …)` — the **population** variance, with text as zero.
    public static let varPA = aggregate("VARPA") { varianceP($0) }

    /// The first error among the arguments, propagated rather than absorbed.
    static func firstError(_ values: [CellValue]) -> CellValue? {
        values.first { if case .error = $0 { return true } else { return false } }
    }
}
