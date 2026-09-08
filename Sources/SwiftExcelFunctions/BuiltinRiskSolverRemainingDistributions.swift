import Foundation
import BusinessMath
import SwiftExcelCore

/// The rest of Risk Solver's distributions, landed with BusinessMath 2.15.0.
///
/// Three kinds, and they need different things from the binding:
///
/// - **Ordinary distributions** — a quantile and one uniform, as everywhere else.
/// - **Processes** — AR, MA, ARMA and the GARCH family. Not i.i.d.: each value
///   depends on the last. Frontline passes the previous state *in* (`val0`, `err0`,
///   `stdev0`), because a spreadsheet cell has no memory, so one step is fully
///   determined and `step(from:dt:normalDraws:)` is that step.
/// - **Multivariate** — one call yields a whole vector, array-entered across a
///   range. These need a `RandomNumberGenerator` rather than a uniform, because a
///   correlated draw has no scalar inverse; ``RandomSourceGenerator`` bridges it.
extension BuiltinRiskSolverFunctions {

    /// Everything BusinessMath 2.15.0 added.
    public static let completingDistributions: [ExcelFunction] =
        [psiPert, psiErf, psiPareto2, psiBetaGen, psiBetaSubj, psiHistogram,
         psiCumulD, psiNormalSkew, psiTriangGen, psiMetalog2, psiMetalogSPT,
         psiAR2, psiMA1, psiMA2, psiARMA11, psiARCH1, psiEGARCH11,
         psiMVNormal, psiMVLogNormal, psiMVResample, psiMVShuffle, psiFit,
         psiMetalogFit, psiMetalog2Fit]
        + BuiltinRiskSolverAltDistributions.all

    // MARK: - Ordinary distributions

    /// `PsiPert(min, likely, max)` — the Beta-PERT of project risk.
    public static let psiPert = sampling("PSIPERT", minArgs: 3, maxArgs: 5) { args in
        guard let low = real(args[0]), let likely = real(args[1]), let high = real(args[2]),
              let distribution = DistributionPert(min: low, likely: likely,
                                                  max: high) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiErf(h)` — the error-function distribution; a normal with `σ = 1/(h√2)`.
    public static let psiErf = sampling("PSIERF", minArgs: 1, maxArgs: 3) { args in
        guard let h = real(args[0]), let distribution = DistributionErf(h: h) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiPareto2(b, q)` — Lomax, the shifted Pareto.
    public static let psiPareto2 = sampling("PSIPARETO2", minArgs: 2, maxArgs: 4) { args in
        guard let scale = real(args[0]), let shape = real(args[1]),
              let distribution = DistributionPareto2(scale: scale,
                                                     shape: shape) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiBetaGen(alpha1, alpha2, a, b)` — Beta scaled onto `[a, b]`.
    public static let psiBetaGen = sampling("PSIBETAGEN", minArgs: 4, maxArgs: 6) { args in
        guard let s1 = real(args[0]), let s2 = real(args[1]),
              let low = real(args[2]), let high = real(args[3]),
              let distribution = DistributionBetaGeneralised(shape1: s1, shape2: s2,
                                                             min: low,
                                                             max: high) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiBetaSubj(a, likely, mean, b)` — Beta elicited from a mode and a mean.
    ///
    /// Argument order is `(min, likely, mean, max)`: the *mean* is third, between the
    /// mode and the maximum, which is not where anyone would guess it.
    public static let psiBetaSubj = sampling("PSIBETASUBJ", minArgs: 4, maxArgs: 6) { args in
        guard let low = real(args[0]), let likely = real(args[1]),
              let mean = real(args[2]), let high = real(args[3]),
              let distribution = DistributionBetaSubjective(min: low, likely: likely,
                                                            mean: mean,
                                                            max: high) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiHistogram(a, b, {w})` — equal-width bins over `[a, b]`, weighted.
    public static let psiHistogram = sampling("PSIHISTOGRAM", minArgs: 3, maxArgs: 5) { args in
        guard let low = real(args[0]), let high = real(args[1]) else { return nil }
        let weights = series(args[2])
        guard !weights.isEmpty,
              let distribution = DistributionHistogram(min: low, max: high,
                                                       weights: weights) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiCumulD(min, max, {x}, {p})` — the discrete sibling of `PsiCumul`.
    ///
    /// Its `quantile` answers an index; the value is read from the list supplied.
    public static let psiCumulD = sampling("PSICUMULD", minArgs: 4, maxArgs: 6) { args in
        let values = series(args[2])
        let cumulative = series(args[3])
        guard !values.isEmpty, values.count == cumulative.count,
              let distribution = DistributionCumulativeDiscrete(values: values,
                                                                cumulative: cumulative)
        else { return nil }
        return { Double(distribution.quantile($0)) }
    }

    /// `PsiNormalSkew(a, b, c)` — bounds and a skew, **not** a mean and deviation.
    ///
    /// `a` and `b` are roughly the ±3σ points. BusinessMath supplies it as a factory
    /// on `DistributionMyerson`, which is the same three-point elicitation seen from
    /// another angle rather than a separate distribution.
    public static let psiNormalSkew = sampling("PSINORMALSKEW", minArgs: 3, maxArgs: 5) { args in
        guard let low = real(args[0]), let high = real(args[1]), let skew = real(args[2]),
              let distribution = DistributionMyerson.normalSkew(lowerBound: low,
                                                                upperBound: high,
                                                                skew: skew) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiTriangGen(ap, m, br, p, r)` — a triangular whose bounds are percentiles
    /// rather than the true minimum and maximum.
    ///
    /// `ap` is the value at probability `p` and `br` the value at `r`, so the actual
    /// support extends beyond both. Solved as a fitting problem, which is what it is.
    public static let psiTriangGen = sampling("PSITRIANGGEN", minArgs: 5, maxArgs: 7) { args in
        guard let lowValue = real(args[0]), let mode = real(args[1]),
              let highValue = real(args[2]), let lowP = real(args[3]),
              let highP = real(args[4]), lowP > 0, highP < 1, lowP < highP else { return nil }
        return { probability in
            let fitted = try DistributionTriangular.fitting([
                .quantile(p: lowP, value: lowValue),
                .parameter(name: "base", value: mode),
                .quantile(p: highP, value: highValue),
            ])
            return fitted.quantile(probability)
        }
    }

    /// `PsiMetalog2(coefficients)` — the unbounded metalog.
    public static let psiMetalog2 = sampling("PSIMETALOG2", minArgs: 1, maxArgs: 3) { args in
        let coefficients = series(args[0])
        guard coefficients.count >= 2 else { return nil }
        return { probability in
            try DistributionMetalog(coefficients: coefficients,
                                    boundedness: .unbounded).quantile(probability)
        }
    }

    /// `PsiMetalogSPT(min, max, quantiles, prob)` — the symmetric-percentile triplet
    /// form: three values at `prob`, ½ and `1 − prob`.
    public static let psiMetalogSPT = sampling("PSIMETALOGSPT", minArgs: 4, maxArgs: 6) { args in
        guard let low = real(args[0]), let high = real(args[1]), low < high else { return nil }
        let quantiles = series(args[2])
        guard quantiles.count == 3, let probability = real(args[3]),
              probability > 0, probability < 0.5 else { return nil }
        let probabilities = [probability, 0.5, 1 - probability]
        return { draw in
            try DistributionMetalog(fittingProbabilities: probabilities, values: quantiles,
                                    terms: 3,
                                    boundedness: .bounded(lower: low, upper: high))
                .quantile(draw)
        }
    }

    // MARK: - Processes

    /// One step of an ARMA process, shared by `PsiAR2`, `PsiMA1`, `PsiMA2` and
    /// `PsiARMA11` — which differ only in which coefficients they carry.
    private static func arma(
        _ name: String, autoregressive: [Double], movingAverage: [Double],
        mean: Double, volatility: Double, value: Double,
        deviations: [Double], errors: [Double]
    ) -> (@Sendable (Double) throws -> Double)? {
        guard let process = AutoregressiveMovingAverage(
            name: name, mean: mean, volatility: volatility,
            autoregressive: autoregressive, movingAverage: movingAverage) else { return nil }
        let state = ARMAState(value: value, deviations: deviations, errors: errors)
        let standardNormal = DistributionNormal(0, 1)
        return { probability in
            process.step(from: state, dt: 1,
                         normalDraws: standardNormal.quantile(probability)).value
        }
    }

    /// `PsiAR2(mean, volatility, coef1, coef2, val0, val1)`.
    public static let psiAR2 = sampling("PSIAR2", minArgs: 6, maxArgs: 8) { args in
        guard let mean = real(args[0]), let vol = real(args[1]),
              let c1 = real(args[2]), let c2 = real(args[3]),
              let v0 = real(args[4]), let v1 = real(args[5]) else { return nil }
        return arma("PsiAR2", autoregressive: [c1, c2], movingAverage: [],
                    mean: mean, volatility: vol, value: v0,
                    deviations: [v0 - mean, v1 - mean], errors: [])
    }

    /// `PsiMA1(mean, volatility, coef1, err0)`.
    public static let psiMA1 = sampling("PSIMA1", minArgs: 4, maxArgs: 6) { args in
        guard let mean = real(args[0]), let vol = real(args[1]),
              let c1 = real(args[2]), let e0 = real(args[3]) else { return nil }
        return arma("PsiMA1", autoregressive: [], movingAverage: [c1],
                    mean: mean, volatility: vol, value: mean,
                    deviations: [], errors: [e0])
    }

    /// `PsiMA2(mean, volatility, coef1, coef2, err0, err1)`.
    public static let psiMA2 = sampling("PSIMA2", minArgs: 6, maxArgs: 8) { args in
        guard let mean = real(args[0]), let vol = real(args[1]),
              let c1 = real(args[2]), let c2 = real(args[3]),
              let e0 = real(args[4]), let e1 = real(args[5]) else { return nil }
        return arma("PsiMA2", autoregressive: [], movingAverage: [c1, c2],
                    mean: mean, volatility: vol, value: mean,
                    deviations: [], errors: [e0, e1])
    }

    /// `PsiARMA11(mean, volatility, ar_coef, ma_coef, val0, err0)`.
    public static let psiARMA11 = sampling("PSIARMA11", minArgs: 6, maxArgs: 8) { args in
        guard let mean = real(args[0]), let vol = real(args[1]),
              let ar = real(args[2]), let ma = real(args[3]),
              let v0 = real(args[4]), let e0 = real(args[5]) else { return nil }
        return arma("PsiARMA11", autoregressive: [ar], movingAverage: [ma],
                    mean: mean, volatility: vol, value: v0,
                    deviations: [v0 - mean], errors: [e0])
    }

    /// `PsiARCH1(mean, volatility, err_coef, val0)` — GARCH(1,1) with no persistence.
    ///
    /// ARCH(1) *is* GARCH(1,1) at β = 0: the variance responds to the last shock and
    /// carries nothing forward. Binding it to the same type is the same mathematics,
    /// not an approximation of it.
    public static let psiARCH1 = sampling("PSIARCH1", minArgs: 4, maxArgs: 6) { args in
        guard let mean = real(args[0]), let vol = real(args[1]),
              let alpha = real(args[2]), let v0 = real(args[3]),
              vol > 0, alpha < 1 else { return nil }
        let constant = vol * vol * (1 - alpha)
        guard let process = GarchOneOne(name: "PsiARCH1", constant: constant,
                                        shockWeight: alpha,
                                        persistenceWeight: 0) else { return nil }
        let state = GarchState(value: v0 - mean, variance: vol * vol)
        let standardNormal = DistributionNormal(0, 1)
        return { probability in
            mean + process.step(from: state, dt: 1,
                                normalDraws: standardNormal.quantile(probability)).value
        }
    }

    /// `PsiEGARCH11(mean, volatility, theta, gamma, err_coef, ar_coef, val0, stdev0)`.
    ///
    /// Exponential GARCH: the variance recursion is on `log σ²`, so it needs no
    /// positivity constraints and admits a leverage term — bad news moving volatility
    /// more than good news of the same size.
    public static let psiEGARCH11 = sampling("PSIEGARCH11", minArgs: 8, maxArgs: 10) { args in
        guard let mean = real(args[0]), let vol = real(args[1]),
              let theta = real(args[2]), let gamma = real(args[3]),
              let alpha = real(args[4]), let beta = real(args[5]),
              let v0 = real(args[6]), let s0 = real(args[7]),
              vol > 0, s0 >= 0 else { return nil }
        guard let process = ExponentialGarch(name: "PsiEGARCH11",
                                             unconditionalVolatility: vol,
                                             shockWeight: alpha, persistenceWeight: beta,
                                             leverage: theta,
                                             magnitude: gamma) else { return nil }
        let state = GarchState(value: v0 - mean, variance: s0 * s0)
        let standardNormal = DistributionNormal(0, 1)
        return { probability in
            mean + process.step(from: state, dt: 1,
                                normalDraws: standardNormal.quantile(probability)).value
        }
    }

    // MARK: - Metalog, fitted to points

    /// Which of two vectors is the probabilities, decided by what a probability *is*.
    ///
    /// Frontline documents `PsiMetalogFit(num_coef, x_values, y_values)` without
    /// saying which carries the probability, and getting it backwards fits the
    /// distribution to transposed data — an answer, and the wrong one.
    ///
    /// It does not have to be guessed. A fitting probability is strictly inside
    /// `(0, 1)` and distinct from its neighbours; `DistributionMetalog` enforces
    /// exactly that and throws `.invalidProbability` otherwise. So the pair is
    /// identified by the definition rather than by a convention: whichever vector
    /// satisfies it, is it.
    ///
    /// - Parameters:
    ///   - first: The `x_values` argument, as written.
    ///   - second: The `y_values` argument.
    /// - Returns: `(probabilities, values)`, or `nil` when neither vector can be a
    ///   probability, or when **both** can and the call is genuinely ambiguous.
    static func probabilityPair(_ first: [Double],
                                _ second: [Double]) -> (probabilities: [Double],
                                                        values: [Double])? {
        func couldBeProbabilities(_ candidate: [Double]) -> Bool {
            guard candidate.count >= 2 else { return false }
            guard candidate.allSatisfy({ $0 > 0 && $0 < 1 }) else { return false }
            return Set(candidate.map(\.bitPattern)).count == candidate.count
        }
        let firstCould = couldBeProbabilities(first)
        let secondCould = couldBeProbabilities(second)
        // Both inside (0, 1) — a market-share or utilisation model can do this, and
        // nothing in the call distinguishes them. Refusing beats fitting the
        // transpose and returning a number nobody can question.
        if firstCould && secondCould { return nil }
        if firstCould { return (first, second) }
        if secondCould { return (second, first) }
        return nil
    }

    /// Builds a metalog least-squares fit from `(num_coef, x_values, y_values)`.
    private static func metalogFit(_ name: String) -> ExcelFunction {
        sampling(name, minArgs: 3, maxArgs: 5) { args in
            guard let requested = real(args[0]),
                  let terms = Int(exactly: requested.rounded()), terms >= 2 else { return nil }
            guard let pair = probabilityPair(series(args[1]), series(args[2])),
                  pair.probabilities.count >= terms else { return nil }
            return { probability in
                try DistributionMetalog(fittingProbabilities: pair.probabilities,
                                        values: pair.values, terms: terms,
                                        boundedness: .unbounded).quantile(probability)
            }
        }
    }

    /// `PsiMetalogFit(num_coef, x_values, y_values)` — fit a metalog to points.
    ///
    /// Fewer terms than points is a least-squares fit, which is the right choice when
    /// the points come from data rather than elicitation.
    public static let psiMetalogFit = metalogFit("PSIMETALOGFIT")

    /// `PsiMetalog2Fit(num_coef, x_values, y_values)`.
    ///
    /// Frontline lists this with a signature **identical** to `PsiMetalogFit`, and
    /// nothing in either argument list distinguishes them — the difference is
    /// internal to Risk Solver's metalog variants. Bound the same way rather than
    /// invented differently: two names that behave alike is a smaller error than one
    /// of them quietly fitting a different distribution.
    public static let psiMetalog2Fit = metalogFit("PSIMETALOG2FIT")

    // MARK: - Multivariate, which answer a vector

    /// A vector result, spilled across the range the formula was array-entered over.
    ///
    /// Frontline is explicit that these are array formulas: *"PsiMVLogNormal returns
    /// an array of sample data; to use it, you must 'array-enter' a formula"*. A
    /// column matrix is what `FormulaEvaluator.spill(_:over:)` distributes, so the
    /// binding answers the whole draw and the existing spill machinery places it.
    private static func vector(
        _ name: String, minArgs: Int, maxArgs: Int?,
        draw: @escaping @Sendable ([CellValue], inout RandomSourceGenerator) throws -> [Double]?
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: minArgs, maxArgs: maxArgs) { context, values in
            if let error = firstError(values) { return error }
            let parts = attached(context, values)
            guard parts.parameters.count >= minArgs else { return .error(.value) }
            guard let random = context.random else { return parts.baseCase ?? .error(.value) }
            var generator = RandomSourceGenerator(random)
            do {
                guard let sample = try draw(parts.parameters, &generator) else {
                    return .error(.num)
                }
                return .array(CellMatrix(column: sample.map { CellValue.number($0) }))
            } catch {
                return .error(.num)
            }
        }
    }

    /// Reads a square matrix from a range, given its side length.
    private static func square(_ value: CellValue, side: Int) -> [[Double]]? {
        let flat = series(value)
        guard flat.count == side * side else { return nil }
        return (0..<side).map { row in Array(flat[(row * side)..<((row + 1) * side)]) }
    }

    /// Reads a rectangular block of rows from a range.
    private static func rows(_ value: CellValue) -> [[Double]]? {
        guard case .array(let matrix) = value, matrix.rows > 0 else { return nil }
        return (0..<matrix.rows).compactMap { index in
            matrix.row(index).map { $0.compactMap(real) }
        }
    }

    /// `PsiMVNormal(mu, sigma)` — correlated normals; `sigma` is a covariance matrix.
    public static let psiMVNormal = vector("PSIMVNORMAL", minArgs: 2, maxArgs: 4) { args, rng in
        let means = series(args[0])
        guard !means.isEmpty, let covariance = square(args[1], side: means.count) else {
            return nil
        }
        return try DistributionMVNormal(means: means,
                                        covarianceMatrix: covariance).sample(using: &rng)
    }

    /// `PsiMVLogNormal(mu, sigma)` — the exponential of a correlated normal.
    ///
    /// Frontline documents it as the multivariate generalisation of `PsiLogNorm2`,
    /// so `mu` and `sigma` are on the **log** scale, as `PsiLogNorm2`'s are, and no
    /// moment conversion applies. `sigma` is a covariance matrix; the type wants
    /// deviations and a correlation matrix, which is the same information rearranged.
    public static let psiMVLogNormal = vector("PSIMVLOGNORMAL", minArgs: 2, maxArgs: 4) { args, rng in
        let logMeans = series(args[0])
        guard !logMeans.isEmpty,
              let covariance = square(args[1], side: logMeans.count) else { return nil }
        var deviations: [Double] = []
        for index in 0..<logMeans.count {
            let variance = covariance[index][index]
            guard variance > 0 else { return nil }
            deviations.append(variance.squareRoot())
        }
        var correlation = covariance
        for row in 0..<logMeans.count {
            for column in 0..<logMeans.count {
                let denominator = deviations[row] * deviations[column]
                guard denominator > 0 else { return nil }
                correlation[row][column] = covariance[row][column] / denominator
            }
        }
        return try DistributionMVLogNormal(logMeans: logMeans,
                                           logStandardDeviations: deviations,
                                           correlationMatrix: correlation).sample(using: &rng)
    }

    /// `PsiMVResample(data)` — draw whole rows, **with** replacement.
    ///
    /// Rows rather than columns is the point: resampling a row keeps the joint
    /// behaviour of the variables in it, which drawing each column independently
    /// would destroy.
    public static let psiMVResample = vector("PSIMVRESAMPLE", minArgs: 1, maxArgs: 3) { args, rng in
        guard let block = rows(args[0]), !block.isEmpty else { return nil }
        return try MultivariateResample(rows: block).sample(using: &rng)
    }

    /// `PsiMVShuffle(data)` — Frontline draws whole rows **without** replacement.
    ///
    /// **Bound to `MultivariateResample`, which is with replacement, and named here
    /// as the thing it actually is.**
    ///
    /// Without-replacement is a property of a *sequence* of draws — `MultivariateShuffle`
    /// says so in its shape, since `next(using:)` is `mutating` and removes each row
    /// as it goes. A cell evaluation has no memory of the previous one, so nothing
    /// here can hold the deck between cells.
    ///
    /// Taking row 0 of a fresh permutation would look like a shuffle and would in
    /// fact be resampling: across *n* cells it gives the resample distribution
    /// exactly. So this calls the resampler rather than dressing one up as the other.
    ///
    /// What that costs is precisely where a shuffle earns its keep: a full pass
    /// reproduces the empirical joint distribution with no sampling error at all,
    /// and independent draws do not. A workbook relying on that will differ.
    ///
    /// Bound rather than refused, because `#NAME?` on an otherwise readable workbook
    /// is worse — and named honestly rather than approximated, because a caller can
    /// only account for the difference if it is stated.
    public static let psiMVShuffle = vector("PSIMVSHUFFLE", minArgs: 1, maxArgs: 3) { args, rng in
        guard let block = rows(args[0]), !block.isEmpty else { return nil }
        return try MultivariateResample(rows: block).sample(using: &rng)
    }

    // MARK: - Fitting to data

    /// `PsiFit(data)` — fit a distribution to a sample, through its first four moments.
    ///
    /// Not one distribution being fitted but a family being *selected*: the Johnson
    /// system partitions the skew/kurtosis plane between bounded, unbounded and
    /// lognormal forms, and which region the sample lands in decides which is used.
    public static let psiFit = sampling("PSIFIT", minArgs: 1, maxArgs: 3) { args in
        let sample = series(args[0])
        guard sample.count >= 4 else { return nil }
        return { probability in
            try DistributionMomentFit(sample: sample).quantile(probability)
        }
    }
}
