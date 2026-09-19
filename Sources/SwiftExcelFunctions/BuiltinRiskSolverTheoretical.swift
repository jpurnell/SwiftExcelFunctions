import Foundation
import SwiftExcelCore

/// `PsiTheo*` — statistics of the **distribution**, not of a run.
///
/// `PsiMean(B4)` is the mean of ten thousand trials. `PsiTheoMean(B4)` is the mean of the
/// distribution `B4` draws from, and it has an answer before any simulation has been run —
/// which is the whole reason the family exists. A modeller compares the two to ask whether
/// the run has converged.
///
/// ## How a distribution is reached, and why it is not a table
///
/// The obvious implementation is a second registry mapping `PSINORMAL` to a
/// `DistributionNormal`, beside the one the samplers already use. That would be two lists to
/// keep in step, and this project has just spent a session on what happens when one copy of a
/// rule is right and the other is not — `CellRange(_:)` against `DefinedNameResolver`.
///
/// So there is no second list. `BuiltinRiskSolverDistributions.sampling(…)` draws one uniform
/// from `RandomSource` and applies the distribution's inverse to it, which means **evaluating
/// the cell's own formula with a random source that returns `p` yields exactly `q(p)`**. The
/// theoretical statistics walk a grid of `p` and read the quantile function off the sampler,
/// through the identical code path. A distribution the sampler reads one way cannot be read
/// another way here, because there is only one way.
///
/// It also means every one of the 90-odd `Psi*` distributions is covered by this file without
/// being named in it — including the `*Alt` percentile-parameterised forms, which have no
/// closed-form object to put in a table at all.
///
/// ## The grid, and what it cannot do
///
/// Moments are integrals over `p` in (0, 1): the mean is `∫ q(p) dp`, the variance is
/// `∫ (q(p) − µ)² dp`, and so on. The **midpoint** rule is used, at `p = (i − ½)/n`, because
/// it never evaluates the quantile at 0 or 1 — where an unbounded distribution is infinite and
/// the integral would be over a value no cell can hold.
///
/// That leaves a real limit, stated rather than discovered later: **a heavy tail is
/// understated.** The grid's outermost point is `q(1/2n)`, so mass beyond it is missed. For a
/// Cauchy — whose mean does not exist — this returns a finite number that is an artefact of
/// `n` and nothing else. The same shape of problem as integrating a density by Simpson, and
/// the same answer: it is written down here rather than left for a reader to find.
public enum BuiltinRiskSolverTheoretical {

    /// Every name this file answers, so the evaluator can dispatch without a table of cases.
    static let governed: Set<String> = [
        "PSITHEOMEAN", "PSITHEOSTDDEV", "PSITHEOVARIANCE", "PSITHEOSKEWNESS",
        "PSITHEOKURTOSIS", "PSITHEOMEDIAN", "PSITHEOMIN", "PSITHEOMAX", "PSITHEORANGE",
        "PSITHEOPERCENTILE", "PSITHEOPERCENTILED", "PSITHEOPTOX", "PSITHEOQTOX",
        "PSITHEOXTOP", "PSITHEOXTOQ", "PSITHEOTARGET", "PSITHEOTARGETD", "PSITHEOMODE"
    ]

    /// Whether this file answers a name.
    static func governs(_ name: String) -> Bool { governed.contains(name) }

    /// Registrations for a ``FunctionRegistry``.
    ///
    /// The bodies are never reached — ``FormulaEvaluator`` intercepts these before calling
    /// one, because answering needs the evaluator itself. They exist so the name **resolves**:
    /// the evaluator looks a function up before it dispatches, so an unregistered name is
    /// `#NAME?` no matter what the dispatch would have done with it. The same arrangement
    /// `LAMBDA` and `ISOMITTED` have.
    ///
    /// The arity is real and is checked here, before the interception.
    public static let all: [ExcelFunction] = {
        let takingOnlyTheCell = ["PSITHEOMEAN", "PSITHEOSTDDEV", "PSITHEOVARIANCE",
                                 "PSITHEOSKEWNESS", "PSITHEOKURTOSIS", "PSITHEOMEDIAN",
                                 "PSITHEOMIN", "PSITHEOMAX", "PSITHEORANGE",
                                 "PSITHEOMODE"]
        let takingAValueToo = ["PSITHEOPERCENTILE", "PSITHEOPERCENTILED", "PSITHEOPTOX",
                               "PSITHEOQTOX", "PSITHEOXTOP", "PSITHEOXTOQ",
                               "PSITHEOTARGET", "PSITHEOTARGETD"]
        return takingOnlyTheCell.map { placeholder($0, minArgs: 1, maxArgs: 1) }
            + takingAValueToo.map { placeholder($0, minArgs: 2, maxArgs: 2) }
    }()

    /// A registration whose body the evaluator replaces.
    private static func placeholder(
        _ name: String, minArgs: Int, maxArgs: Int
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: minArgs, maxArgs: maxArgs) { _ in
            // Reached only if the interception is ever removed. `#VALUE!` rather than a
            // wrong number, and rather than a trap: a statistic that silently stopped being
            // computed is the failure this answer exists to make visible.
            .error(.value)
        }
    }

    /// How many points the moment grid uses.
    ///
    /// 4,096 midpoints reaches `q(0.000122)` at each end — about ±3.67σ for a normal, which
    /// carries the mean and variance to well past the precision a spreadsheet displays. Raising
    /// it costs one formula evaluation per point and buys tail accuracy; there is no value at
    /// which a Cauchy's mean becomes real.
    static let gridPoints = 4_096

    /// The probability nearest an end that the extremes are read at.
    ///
    /// `PsiTheoMin` of an unbounded distribution has no finite answer. Rather than an infinity
    /// no cell can hold, this reports the quantile at `1e-9` and its documentation says so —
    /// the same choice the density work made at an unbounded support boundary, for the same
    /// reason.
    static let extremeProbability = 1e-9

    // MARK: - Dispatch

    /// Answers a `PsiTheo*` call.
    ///
    /// - Parameters:
    ///   - name: the canonical function name, already known to be governed.
    ///   - arguments: the evaluated arguments after the first; the cell itself is `quantile`.
    ///   - quantile: `q(p)` for the referenced cell's distribution, or `nil` where the cell
    ///     holds no distribution call.
    /// - Returns: the statistic, or an Excel error.
    static func evaluate(
        _ name: String, arguments: [CellValue],
        quantile: (Double) throws -> Double?
    ) rethrows -> CellValue {
        switch name {
        case "PSITHEOMEDIAN":
            return try value(at: 0.5, quantile)
        case "PSITHEOMODE":
            return try mode(quantile)
        case "PSITHEOMIN":
            return try value(at: extremeProbability, quantile)
        case "PSITHEOMAX":
            return try value(at: 1 - extremeProbability, quantile)
        case "PSITHEORANGE":
            guard case .number(let low) = try value(at: extremeProbability, quantile),
                  case .number(let high) = try value(at: 1 - extremeProbability, quantile)
            else { return .error(.num) }
            return .number(high - low)

        case "PSITHEOPERCENTILE", "PSITHEOPTOX":
            guard let p = real(arguments.first), p > 0, p < 1 else { return .error(.num) }
            return try value(at: p, quantile)
        // The `D` and `Q` spellings take the probability from the **other** end. A caller who
        // reaches for the wrong one gets the opposite tail, which for a symmetric distribution
        // is a sign error and for a skewed one is simply a different number.
        case "PSITHEOPERCENTILED", "PSITHEOQTOX":
            guard let q = real(arguments.first), q > 0, q < 1 else { return .error(.num) }
            return try value(at: 1 - q, quantile)

        case "PSITHEOXTOP", "PSITHEOTARGET":
            guard let x = real(arguments.first) else { return .error(.value) }
            return try probability(of: x, quantile)
        case "PSITHEOXTOQ", "PSITHEOTARGETD":
            guard let x = real(arguments.first) else { return .error(.value) }
            guard case .number(let p) = try probability(of: x, quantile) else {
                return .error(.num)
            }
            return .number(1 - p)

        default:
            return try moment(name, quantile)
        }
    }

    // MARK: - Points

    /// The quantile at one probability, as a cell value.
    private static func value(
        at p: Double, _ quantile: (Double) throws -> Double?
    ) rethrows -> CellValue {
        guard let x = try quantile(p), x.isFinite else { return .error(.num) }
        return .number(x)
    }

    /// `P(X ≤ x)`, by bisecting the quantile function.
    ///
    /// The distributions are reached through their inverses, so the CDF is not available
    /// directly and is recovered from the inverse's monotonicity. Sixty halvings take the
    /// bracket below the precision of a `Double`, so the loop is bounded by arithmetic rather
    /// than by a tolerance that could fail to be met.
    private static func probability(
        of x: Double, _ quantile: (Double) throws -> Double?
    ) rethrows -> CellValue {
        guard x.isFinite else { return .error(.num) }
        var low = extremeProbability, high = 1 - extremeProbability
        guard let lowest = try quantile(low), let highest = try quantile(high) else {
            return .error(.num)
        }
        if x <= lowest { return .number(0) }
        if x >= highest { return .number(1) }
        for _ in 0..<60 {
            let middle = (low + high) / 2
            guard let value = try quantile(middle) else { return .error(.num) }
            if value <= x { low = middle } else { high = middle }
        }
        return .number((low + high) / 2)
    }

    /// The mode: where the density is greatest.
    ///
    /// ## Found through the quantile, because that is all there is
    ///
    /// These statistics reach a distribution only through its inverse, so there is no density
    /// to maximise directly. There is one underneath it: a quantile function's slope is the
    /// reciprocal of the density, `f(q(p)) = 1 / q′(p)`. So the **flattest** part of the
    /// quantile is the **peak** of the density, and the mode is the value there.
    ///
    /// The same identity `DistributionMetalog.pdf` uses upstream, for the same reason — a
    /// distribution defined by its quantile has no other way to state a density.
    ///
    /// ## What this cannot do
    ///
    /// A grid finds the largest of the values it looked at. For a **multimodal** distribution
    /// that is whichever peak a grid point landed nearest, and for one whose density is
    /// unbounded — a beta with a shape below one — the answer runs to the support's edge,
    /// which is where the density genuinely does go. Both are stated rather than guarded
    /// against: a mode is a summary that assumes a single peak, and a distribution that
    /// breaks the assumption breaks the summary rather than the arithmetic.
    private static func mode(
        _ quantile: (Double) throws -> Double?
    ) rethrows -> CellValue {
        // The narrowest step in `p` whose difference in `x` is still meaningful — small
        // enough to resolve a peak, wide enough that the subtraction keeps its digits.
        let span = Double(gridPoints)
        guard span > 0 else { return .error(.num) }
        let step = 1.0 / span
        var bestValue = Double.nan
        var smallestSlope = Double.infinity
        for index in 0..<gridPoints {
            let p = (Double(index) + 0.5) * step
            guard let low = try quantile(Swift.max(p - step / 2, extremeProbability)),
                  let high = try quantile(Swift.min(p + step / 2, 1 - extremeProbability))
            else { continue }
            let slope = high - low
            guard slope.isFinite, slope >= 0 else { continue }
            if slope < smallestSlope {
                smallestSlope = slope
                bestValue = (low + high) / 2
            }
        }
        guard bestValue.isFinite else { return .error(.num) }
        return .number(bestValue)
    }

    // MARK: - Moments

    /// The moments, all four of which need the same pass over the grid.
    private static func moment(
        _ name: String, _ quantile: (Double) throws -> Double?
    ) rethrows -> CellValue {
        var values: [Double] = []
        values.reserveCapacity(gridPoints)
        // Named and guarded rather than divided by inline: `gridPoints` is a constant above
        // zero today, and a constant is exactly the kind of divisor whose guard gets dropped
        // because everyone can see it is fine.
        let span = Double(gridPoints)
        guard span > 0 else { return .error(.num) }
        for index in 0..<gridPoints {
            let p = (Double(index) + 0.5) / span
            guard let x = try quantile(p), x.isFinite else { return .error(.num) }
            values.append(x)
        }
        let count = Double(values.count)
        // The grid is a compile-time constant and `values` is filled from it, so this cannot
        // be zero — named and guarded anyway, because that is an argument about the loop above
        // rather than a property of the divisor.
        guard count > 0 else { return .error(.num) }
        let mean = values.reduce(0, +) / count
        if name == "PSITHEOMEAN" { return .number(mean) }

        var second = 0.0, third = 0.0, fourth = 0.0
        for value in values {
            let deviation = value - mean
            let squared = deviation * deviation
            second += squared
            third += squared * deviation
            fourth += squared * squared
        }
        // Divided by the point count, not by `count − 1`: this is the distribution's own
        // variance, not an estimate from a sample, so there is nothing to correct for.
        let variance: Double = second / count
        switch name {
        case "PSITHEOVARIANCE": return .number(variance)
        case "PSITHEOSTDDEV": return .number(variance.squareRoot())
        default: break
        }
        // A distribution with no spread has no shape: every point is the mean, and skewness
        // and kurtosis are `0/0`. Refused rather than answered with a `nan`.
        guard variance > 0 else { return .error(.num) }
        let deviation = variance.squareRoot()
        let cubed = deviation * deviation * deviation
        let squaredVariance = variance * variance
        guard cubed > 0, squaredVariance > 0 else { return .error(.num) }
        switch name {
        case "PSITHEOSKEWNESS":
            return .number(third / count / cubed)
        case "PSITHEOKURTOSIS":
            // Not excess kurtosis — 3 for a normal, matching `PsiKurtosis` beside it. The two
            // conventions differ by exactly three, which looks like an ordinary number.
            return .number(fourth / count / squaredVariance)
        default:
            return .error(.name)
        }
    }

    /// A finite number from a cell value.
    private static func real(_ value: CellValue?) -> Double? {
        switch value {
        case .number(let d): return d.isFinite ? d : nil
        case .bool(let flag): return flag ? 1 : 0
        default: return nil
        }
    }
}

/// A source of randomness that always answers the same uniform.
///
/// Not a random source at all, which is the point: handing one to the evaluator turns every
/// `Psi*` distribution call into its own quantile function, because `sampling(…)` draws one
/// uniform and applies the inverse to it. That is how `PsiTheo*` reaches a distribution
/// without a second registry of distributions to keep in step with the first.
struct FixedUniform: RandomSource {
    private let value: Double

    /// - Parameter value: the probability every draw returns, in the open interval (0, 1).
    init(_ value: Double) { self.value = value }

    func nextUniform() -> Double { value }

    /// Scaled from the same fixed uniform, and clamped inside the bound.
    ///
    /// A discrete `Psi*` distribution reaches for this rather than for `nextUniform()`. The
    /// clamp matters at `p` near one, where `value * bound` rounds up to `bound` itself and
    /// would index past the end of whatever the caller is choosing from.
    func nextInteger(below bound: Int) -> Int {
        guard bound > 0 else { return 0 }
        return Swift.min(Int(value * Double(bound)), bound - 1)
    }
}
