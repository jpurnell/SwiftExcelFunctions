import Foundation
import BusinessMath
import SwiftExcelCore

/// Risk Solver's distributions — the nine the corpus actually calls.
///
/// The mathematics is BusinessMath's. What lives here is the part that is Excel's:
/// Frontline's argument order, Frontline's parameterisation where it differs from
/// the library's, error propagation, and the answer a cell gives when nothing is
/// simulating.
///
/// Sampling is by **inverse transform** — one uniform from the caller's
/// ``RandomSource``, pushed through the distribution's own `quantile`. That keeps
/// the randomness where this package has always kept it, in the caller's hands,
/// and it means the distribution being sampled is the same object the library
/// would integrate. Nothing here draws from system entropy.
extension BuiltinRiskSolverFunctions {

    /// The nine distributions the corpus reaches, covering 1,166 of the Psi
    /// family's 1,950 calls.
    public static let distributions: [ExcelFunction] = [
        psiBernoulli, psiNormal, psiLogNormal, psiTriangular, psiDiscrete,
        psiUniform, psiBinomial, psiIntUniform, psiPoisson,
    ]

    // MARK: - Property functions, and why they need the AST

    /// The property functions a distribution can carry, recovered from the
    /// *unevaluated* arguments.
    ///
    /// This is the whole reason every distribution here is a context function. The
    /// evaluator evaluates arguments before calling, so `PsiBaseCase(5)` and a
    /// literal `5` both arrive as `.number(5)` — nothing in the value says which it
    /// was. Read as a parameter, a base case silently widens a support and produces
    /// numbers that look entirely reasonable.
    struct Attached {
        /// What to show when no simulation is running.
        var baseCase: CellValue?
        /// Parameters, with the property functions removed.
        var parameters: [CellValue]
        /// `PsiShift(delta)` — a constant added to every draw.
        var shift: Double?
        /// `PsiTruncate(min, max)` — bounds on the **value**, either end optional.
        var truncation: (low: Double?, high: Double?)?
        /// `PsiTruncateP(lower, upper)` — bounds on the **probability**, either end optional.
        var truncationByProbability: (low: Double?, high: Double?)?
    }

    /// The two numbers a truncation property carried, read back off its value.
    ///
    /// A blank is an open end rather than a zero, which is how a one-sided truncation says
    /// which side it left alone — and reading it as zero would bound a distribution at the
    /// origin, which for a cost or a duration looks entirely plausible.
    private static func bounds(_ value: CellValue) -> (low: Double?, high: Double?)? {
        guard case .array(let matrix) = value, matrix.elements.count == 2 else { return nil }
        return (openEnded(matrix.elements[0]), openEnded(matrix.elements[1]))
    }

    /// One end of a truncation: a number, or `nil` for an end that was left open.
    ///
    /// **Not `real(_:)`**, which reads a blank as zero — the very thing the note above warns
    /// about, and which this originally delegated to. `PsiTruncate(5,)` came back bounded at
    /// `[5, 0]`, an empty range, and the truncation was then dropped entirely by the
    /// span guard: a one-sided truncation silently did nothing. Caught by a test asserting
    /// the lower bound held, not by reading the code that had the warning written on it.
    private static func openEnded(_ value: CellValue) -> Double? {
        if case .blank = value { return nil }
        return real(value)
    }

    /// Splits evaluated arguments into parameters and properties.
    ///
    /// - Parameters:
    ///   - context: Carries `arguments`, the unevaluated ASTs.
    ///   - values: The same arguments, evaluated.
    /// - Returns: The parameters and any attached properties.
    static func attached(_ context: EvaluationContext, _ values: [CellValue]) -> Attached {
        var result = Attached(baseCase: nil, parameters: [], shift: nil,
                              truncation: nil, truncationByProbability: nil)
        for (index, value) in values.enumerated() {
            guard index < context.arguments.count,
                  case .function(let rawName, _) = context.arguments[index] else {
                result.parameters.append(value)
                continue
            }
            switch FunctionRegistry.canonical(rawName) {
            case "PSIBASECASE": result.baseCase = value
            case "PSISHIFT": result.shift = real(value)
            case "PSITRUNCATE": result.truncation = bounds(value)
            case "PSITRUNCATEP": result.truncationByProbability = bounds(value)
            // Labels and engine directives: recognised so they are not read as parameters,
            // and carrying nothing this evaluator can act on. See
            // `BuiltinRiskSolverProperties` for why registering them at all was the fix.
            case "PSINAME", "PSIUNITS", "PSICATEGORY",
                 "PSISTATIC", "PSILOCK", "PSICOLLECT", "PSISIXSIGMA":
                break
            default: result.parameters.append(value)
            }
        }
        return result
    }

    /// Wraps a distribution's inverse with whatever properties were attached to the call.
    ///
    /// Order matters and is the interesting part: **truncation happens on the untouched
    /// distribution, and the shift is applied after.** `PsiNormal(10, 2, PsiTruncate(5, 15),
    /// PsiShift(100))` draws between 5 and 15 and then moves to between 105 and 115. Applying
    /// the shift first would compare shifted values against unshifted bounds and truncate
    /// almost everything away — silently, since the result is still a number.
    ///
    /// - Parameters:
    ///   - inverse: the distribution's own quantile function.
    ///   - parts: the properties read off the call.
    /// - Returns: the quantile to draw from.
    static func modified(
        _ inverse: @escaping @Sendable (Double) throws -> Double, by parts: Attached
    ) -> @Sendable (Double) throws -> Double {
        var mapped = inverse
        if let byProbability = parts.truncationByProbability {
            mapped = restricted(mapped, between: byProbability.low, and: byProbability.high)
        }
        if let byValue = parts.truncation {
            // The probabilities the bounds sit at, found once by bisecting the inverse —
            // the distributions are reached through their quantiles, so there is no CDF to
            // ask. Sixty halvings take the bracket below a `Double`'s precision.
            let low = byValue.low.map { probability(of: $0, through: mapped) } ?? nil
            let high = byValue.high.map { probability(of: $0, through: mapped) } ?? nil
            mapped = restricted(mapped, between: low, and: high)
        }
        guard let shift = parts.shift else { return mapped }
        let base = mapped
        return { probability in try base(probability) + shift }
    }

    /// An inverse restricted to a span of probability, rescaled to stay a distribution.
    ///
    /// The remaining probability is stretched back over (0, 1) rather than clamped, which is
    /// what keeps the truncated distribution integrating to one. Clamping would pile every
    /// excluded draw onto an endpoint and report a spike where the model meant a bound.
    private static func restricted(
        _ inverse: @escaping @Sendable (Double) throws -> Double,
        between low: Double?, and high: Double?
    ) -> @Sendable (Double) throws -> Double {
        let start = low ?? 0, end = high ?? 1
        let span = end - start
        guard span > 0 else {
            // An upper bound at or below the lower one describes no distribution at all.
            // Refused — the caller turns a throw into `#NUM!` — rather than quietly handing
            // back the untruncated inverse, which is what this did and is how a one-sided
            // truncation managed to do nothing without saying so.
            return { _ in
                throw FormulaEvaluator.EvaluationError.typeMismatch(
                    expected: "a truncation whose upper bound exceeds its lower",
                    got: "an empty range")
            }
        }
        return { probability in try inverse(start + probability * span) }
    }

    /// `P(X ≤ x)`, by bisecting a quantile function.
    ///
    /// - Parameters:
    ///   - x: the value to locate.
    ///   - inverse: the quantile function to bisect.
    /// - Returns: the probability, or `nil` if the quantile cannot be evaluated.
    private static func probability(
        of x: Double, through inverse: @Sendable (Double) throws -> Double
    ) -> Double? {
        var low = 1e-12, high = 1 - 1e-12
        // silent: a quantile that cannot be evaluated here makes the bound unlocatable, which is what nil says
        guard let lowest = try? inverse(low), let highest = try? inverse(high) else { return nil }
        if x <= lowest { return 0 }
        if x >= highest { return 1 }
        for _ in 0..<60 {
            let middle = (low + high) / 2
            // silent: as above — the failure is reported by returning nil, and logging it per draw would be noise
            guard let value = try? inverse(middle) else { return nil }
            if value <= x { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// The first error among the arguments, if any.
    ///
    /// Propagated rather than absorbed, the same rule the lookups follow: the answer
    /// names the failure nearest the start of the argument list, which is the clue
    /// to where the trouble began.
    static func firstError(_ values: [CellValue]) -> CellValue? {
        values.first { if case .error = $0 { return true } else { return false } }
    }

    /// Builds a distribution function from a quantile.
    ///
    /// The shape every distribution here shares:
    ///
    /// 1. An error argument propagates.
    /// 2. Parameters outside the distribution's support are `#NUM!` — checked even
    ///    when idle, because a negative standard deviation is a modelling error
    ///    whether or not anything is simulating.
    /// 3. With a random source, one uniform becomes one draw.
    /// 4. Without one, the base case if there is one.
    /// 5. Otherwise `#VALUE!` — the same refusal `RAND()` makes. This package
    ///    supplies no randomness of its own and will not invent any; returning a
    ///    mean unasked would be a number nobody requested, indistinguishable
    ///    downstream from a real one.
    ///
    /// - Parameters:
    ///   - name: The Excel-facing name, already canonical.
    ///   - minArgs: Parameters required, before any property functions.
    ///   - maxArgs: Parameters accepted, plus room for the property functions.
    ///   - quantile: Builds the inverse CDF from the parameters, or `nil` if they
    ///     are out of support.
    static func sampling(
        _ name: String,
        minArgs: Int,
        maxArgs: Int?,
        quantile: @escaping @Sendable ([CellValue]) -> (@Sendable (Double) throws -> Double)?
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: minArgs, maxArgs: maxArgs) { context, values in
            if let error = firstError(values) { return error }
            let parts = attached(context, values)
            guard parts.parameters.count >= minArgs else { return .error(.value) }
            guard let inverse = quantile(parts.parameters) else { return .error(.num) }
            guard let random = context.random else { return parts.baseCase ?? .error(.value) }
            let drawing = modified(inverse, by: parts)
            do {
                return .number(try drawing(random.nextUniform()))
            } catch {
                // A quantile that cannot be evaluated at this probability — an
                // iterative inverse that did not converge, or a parameter set the
                // library rejects only on use. `#NUM!` is Excel's answer for a
                // computation that has no result.
                return .error(.num)
            }
        }
    }

    /// A finite number from a cell value, or `nil`.
    static func real(_ value: CellValue) -> Double? {
        switch value {
        case .number(let number): return number.isFinite ? number : nil
        case .bool(let flag): return flag ? 1 : 0
        case .blank: return 0
        default: return nil
        }
    }

    /// Every number in an argument, in reading order — a range, an array, or one cell.
    static func series(_ value: CellValue) -> [Double] {
        switch value {
        case .array(let matrix): return matrix.elements.compactMap(real)
        default: return real(value).map { [$0] } ?? []
        }
    }

    // MARK: - Continuous

    /// `PsiNormal(mu, sigma)` — 252 corpus calls across 13 workbooks.
    public static let psiNormal = sampling("PSINORMAL", minArgs: 2, maxArgs: 4) { args in
        guard let mean = real(args[0]), let stdDev = real(args[1]), stdDev > 0 else { return nil }
        let distribution = DistributionNormal(mean, stdDev)
        return { distribution.quantile($0) }
    }

    /// `PsiLogNormal(mean, stdev)` — 153 corpus calls.
    ///
    /// **The parameterisation differs from the library's, and this is the trap.**
    /// Frontline's `PsiLogNormal` takes the *arithmetic* mean and standard deviation
    /// — the mean of the values themselves. `DistributionLogNormal` takes the
    /// parameters of the *underlying normal*, on the log scale. Passing one where
    /// the other is expected returns a positive, plausibly-sized, wrong number.
    ///
    /// So the moments are converted here, which is exactly what a binding is for:
    ///
    /// ```
    /// σ² = ln(1 + s²/m²)
    /// µ  = ln(m) − σ²/2
    /// ```
    ///
    /// `PsiLogNorm2` is the form that takes the log-scale parameters directly, and
    /// must not be bound to this one.
    public static let psiLogNormal = sampling("PSILOGNORMAL", minArgs: 2, maxArgs: 4) { args in
        guard let mean = real(args[0]), let stdDev = real(args[1]),
              mean > 0, stdDev > 0 else { return nil }
        let variance = Foundation.log(1 + (stdDev * stdDev) / (mean * mean))
        guard variance > 0 else { return nil }
        let logMean = Foundation.log(mean) - variance / 2
        let distribution = DistributionLogNormal(logMean, variance.squareRoot())
        return { distribution.quantile($0) }
    }

    /// `PsiTriangular(min, likely, max)` — 130 corpus calls.
    ///
    /// Published as `(a, c, b)`, which positionally is **(min, likely, max)**: the
    /// middle argument is the mode, not the maximum. "Correcting" the order to
    /// (min, max, likely) still produces numbers inside a plausible range, which is
    /// why the order has its own test rather than only a comment.
    public static let psiTriangular = sampling("PSITRIANGULAR", minArgs: 3, maxArgs: 5) { args in
        guard let low = real(args[0]), let likely = real(args[1]), let high = real(args[2]),
              low <= likely, likely <= high, low < high else { return nil }
        let distribution = DistributionTriangular(low: low, high: high, base: likely)
        return { distribution.quantile($0) }
    }

    /// `PsiUniform(min, max)` — 33 corpus calls.
    public static let psiUniform = sampling("PSIUNIFORM", minArgs: 2, maxArgs: 4) { args in
        guard let low = real(args[0]), let high = real(args[1]), low < high else { return nil }
        let distribution = DistributionUniform(low, high)
        return { distribution.quantile($0) }
    }

    // MARK: - Discrete

    /// `PsiDiscrete(values, probabilities)` — 46 corpus calls.
    ///
    /// `DistributionDiscrete.quantile` returns an **index** into the value list, and
    /// `valueAt(_:)` maps it to the outcome. Returning the index would give 0, 1, 2 —
    /// plausible numbers, none of them one of the stated outcomes.
    public static let psiDiscrete = sampling("PSIDISCRETE", minArgs: 2, maxArgs: 4) { args in
        let values = series(args[0])
        let weights = series(args[1])
        guard !values.isEmpty, values.count == weights.count,
              weights.allSatisfy({ $0 >= 0 }), weights.reduce(0, +) > 0,
              let distribution = DistributionDiscrete(values: values, weights: weights) else {
            return nil
        }
        return { probability in
            distribution.valueAt(distribution.quantile(probability)) ?? values[0]
        }
    }

    /// `PsiBernoulli(p)` — 449 corpus calls across 9 workbooks, the most-called
    /// member of the family.
    ///
    /// A two-point distribution, so it is built as one rather than written out. That
    /// keeps the draw on the same machinery as ``psiDiscrete`` and adds no second
    /// implementation of anything.
    public static let psiBernoulli = sampling("PSIBERNOULLI", minArgs: 1, maxArgs: 3) { args in
        guard let p = real(args[0]), p >= 0, p <= 1,
              let distribution = DistributionDiscrete(values: [0, 1], weights: [1 - p, p]) else {
            return nil
        }
        return { probability in
            distribution.valueAt(distribution.quantile(probability)) ?? 0
        }
    }

    /// `PsiBinomial(n, p)` — 20 corpus calls.
    ///
    /// Inverse transform by accumulating BusinessMath's `binomialPMF` until the
    /// cumulative probability passes the draw. Walking the support rather than
    /// materialising it means no array of `n + 1` weights and no arbitrary cap on
    /// `n` — the cost is the value drawn, not the number of trials.
    public static let psiBinomial = sampling("PSIBINOMIAL", minArgs: 2, maxArgs: 4) { args in
        guard let trialsValue = real(args[0]), let p = real(args[1]),
              p >= 0, p <= 1, trialsValue >= 0,
              let trials = Int(exactly: trialsValue.rounded()) else { return nil }
        return { probability in
            var cumulative = 0.0
            for successes in 0...trials {
                cumulative += binomialPMF(n: trials, k: successes, p: p)
                if probability <= cumulative { return Double(successes) }
            }
            return Double(trials)
        }
    }

    /// `PsiIntUniform(a, b)` — every integer from `a` to `b`, both included.
    ///
    /// Inclusive at both ends is the part worth pinning: the draw is `[0, 1)`, so
    /// scaling across `b - a + 1` values reaches `b` exactly as the draw approaches
    /// one and never overshoots.
    public static let psiIntUniform = sampling("PSIINTUNIFORM", minArgs: 2, maxArgs: 4) { args in
        guard let lowValue = real(args[0]), let highValue = real(args[1]),
              let low = Int(exactly: lowValue.rounded()),
              let high = Int(exactly: highValue.rounded()), low <= high else { return nil }
        let span = high - low + 1
        return { probability in
            let offset = Swift.min(Int(probability * Double(span)), span - 1)
            return Double(low + offset)
        }
    }

    /// `PsiPoisson(lambda)` — arrivals in a fixed interval.
    public static let psiPoisson = sampling("PSIPOISSON", minArgs: 1, maxArgs: 3) { args in
        guard let lambda = real(args[0]), lambda >= 0,
              let distribution = DistributionPoisson(lambda: lambda) else { return nil }
        return { Double(distribution.quantile($0)) }
    }
}
