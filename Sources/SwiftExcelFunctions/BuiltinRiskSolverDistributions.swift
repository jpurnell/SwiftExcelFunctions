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
    }

    /// Splits evaluated arguments into parameters and properties.
    ///
    /// - Parameters:
    ///   - context: Carries `arguments`, the unevaluated ASTs.
    ///   - values: The same arguments, evaluated.
    /// - Returns: The parameters and any attached properties.
    static func attached(_ context: EvaluationContext, _ values: [CellValue]) -> Attached {
        var result = Attached(baseCase: nil, parameters: [])
        for (index, value) in values.enumerated() {
            guard index < context.arguments.count,
                  case .function(let rawName, _) = context.arguments[index] else {
                result.parameters.append(value)
                continue
            }
            switch FunctionRegistry.canonical(rawName) {
            case "PSIBASECASE": result.baseCase = value
            case "PSINAME": break            // a label; carries no numeric meaning
            default: result.parameters.append(value)
            }
        }
        return result
    }

    /// The first error among the arguments, if any.
    ///
    /// Propagated rather than absorbed, the same rule the lookups follow: the answer
    /// names the failure nearest the start of the argument list, which is the clue
    /// to where the trouble began.
    private static func firstError(_ values: [CellValue]) -> CellValue? {
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
    private static func sampling(
        _ name: String,
        minArgs: Int,
        maxArgs: Int?,
        quantile: @escaping @Sendable ([CellValue]) -> (@Sendable (Double) -> Double)?
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: minArgs, maxArgs: maxArgs) { context, values in
            if let error = firstError(values) { return error }
            let parts = attached(context, values)
            guard parts.parameters.count >= minArgs else { return .error(.value) }
            guard let inverse = quantile(parts.parameters) else { return .error(.num) }
            if let random = context.random {
                return .number(inverse(random.nextUniform()))
            }
            return parts.baseCase ?? .error(.value)
        }
    }

    /// A finite number from a cell value, or `nil`.
    private static func real(_ value: CellValue) -> Double? {
        switch value {
        case .number(let number): return number.isFinite ? number : nil
        case .bool(let flag): return flag ? 1 : 0
        case .blank: return 0
        default: return nil
        }
    }

    /// Every number in an argument, in reading order — a range, an array, or one cell.
    private static func series(_ value: CellValue) -> [Double] {
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
