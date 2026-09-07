import Foundation
import BusinessMath
import SwiftExcelCore

/// The rest of Risk Solver's distributions — everything BusinessMath 2.14.0 can
/// back that the corpus does not happen to call.
///
/// Same machinery as the nine in ``BuiltinRiskSolverFunctions/distributions``:
/// inverse transform through the distribution's own `quantile`, driven by one
/// uniform from the caller's ``RandomSource``, with property functions read from
/// the unevaluated AST.
///
/// What is different here is how much of the work is *parameterisation*. Frontline
/// and BusinessMath frequently name the same distribution with different
/// parameters, and every one of those is a place where passing the arguments
/// straight through returns a number of the right sign and the wrong magnitude.
/// Each conversion below is commented with the identity it applies.
extension BuiltinRiskSolverFunctions {

    /// Distributions beyond the nine the corpus calls.
    public static let furtherDistributions: [ExcelFunction] = [
        psiBeta, psiBurr12, psiCauchy, psiChiSquare, psiCumul, psiDagum,
        psiDblTriang, psiDisUniform, psiErlang, psiExponential, psiFDist,
        psiFatigueLife, psiFrechet, psiGamma, psiGeneral, psiGeometric,
        psiHypSecant, psiHyperGeo, psiInvNormal, psiJohnsonSB, psiJohnsonSU,
        psiKumaraswamy, psiLaplace, psiLevy, psiLogLogistic, psiLogNorm2,
        psiLogarithmic, psiLogistic, psiMaxExtreme, psiMinExtreme, psiMyerson,
        psiNegBinomial, psiPareto, psiPearson5, psiPearson6, psiRayleigh,
        psiReciprocal, psiStudent, psiWeibull, psiResample, psiShuffle,
        psiMomentFit, psiAR1, psiGARCH11, psiMetalog,
    ]

    // MARK: - Continuous, parameters passed straight through

    /// `PsiBeta(alpha1, alpha2)` — the standard two-shape Beta on `[0, 1]`.
    public static let psiBeta = sampling("PSIBETA", minArgs: 2, maxArgs: 4) { args in
        guard let a = real(args[0]), let b = real(args[1]), a > 0, b > 0 else { return nil }
        let distribution = DistributionBeta(alpha: a, beta: b)
        return { distribution.quantile($0) }
    }

    /// `PsiBurr12(loc, scale, shape1, shape2)` — Burr type XII.
    public static let psiBurr12 = sampling("PSIBURR12", minArgs: 4, maxArgs: 6) { args in
        guard let loc = real(args[0]), let scale = real(args[1]),
              let s1 = real(args[2]), let s2 = real(args[3]),
              let distribution = DistributionBurr12(location: loc, scale: scale,
                                                    shape1: s1, shape2: s2) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiCauchy(loc, lambda)` — location and scale.
    ///
    /// Frontline's prose contradicts its own signature about which argument is
    /// which; BusinessMath took the signature as authoritative and so does this.
    public static let psiCauchy = sampling("PSICAUCHY", minArgs: 2, maxArgs: 4) { args in
        guard let loc = real(args[0]), let scale = real(args[1]),
              let distribution = DistributionCauchy(location: loc, scale: scale) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiChiSquare(df)` — degrees of freedom.
    public static let psiChiSquare = sampling("PSICHISQUARE", minArgs: 1, maxArgs: 3) { args in
        guard let df = real(args[0]), df >= 1,
              let degrees = Int(exactly: df.rounded()) else { return nil }
        let distribution = DistributionChiSquared(degreesOfFreedom: degrees)
        return { distribution.quantile($0) }
    }

    /// `PsiDagum(loc, scale, shape1, shape2)` — Burr type III.
    public static let psiDagum = sampling("PSIDAGUM", minArgs: 4, maxArgs: 6) { args in
        guard let loc = real(args[0]), let scale = real(args[1]),
              let s1 = real(args[2]), let s2 = real(args[3]),
              let distribution = DistributionDagum(location: loc, scale: scale,
                                                   shape1: s1, shape2: s2) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiDblTriang(min, likely, max, p)` — two triangular pieces meeting at the
    /// mode, with `p` the probability mass below it.
    public static let psiDblTriang = sampling("PSIDBLTRIANG", minArgs: 4, maxArgs: 6) { args in
        guard let low = real(args[0]), let likely = real(args[1]),
              let high = real(args[2]), let p = real(args[3]),
              let distribution = DistributionDoubleTriangular(min: low, likely: likely,
                                                              max: high, p: p) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiErlang(k, beta)` — Gamma with an integer shape; `k` stages of scale `beta`.
    public static let psiErlang = sampling("PSIERLANG", minArgs: 2, maxArgs: 4) { args in
        guard let k = real(args[0]), let scale = real(args[1]), k >= 1,
              let stages = Int(exactly: k.rounded()),
              let distribution = DistributionErlang(stages: stages, scale: scale) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiExponential(beta)` — **`beta` is the mean, and BusinessMath takes a rate.**
    ///
    /// `DistributionExponential` is documented "Rate parameter (λ > 0, mean = 1/λ)",
    /// so the scale Frontline states must be inverted. Passing `beta` straight
    /// through gives a distribution with mean `1/beta` — for a beta of 100, a mean
    /// of 0.01 rather than 100, which is wrong by four orders of magnitude while
    /// still being a positive number of the right shape.
    public static let psiExponential = sampling("PSIEXPONENTIAL", minArgs: 1, maxArgs: 3) { args in
        guard let scale = real(args[0]) else { return nil }
        guard scale > 0 else { return nil }
        let rate = 1 / scale
        let distribution = DistributionExponential(rate)
        return { distribution.quantile($0) }
    }

    /// `PsiFDist(df1, df2)` — the F ratio's two degrees of freedom.
    public static let psiFDist = sampling("PSIFDIST", minArgs: 2, maxArgs: 4) { args in
        guard let d1 = real(args[0]), let d2 = real(args[1]), d1 >= 1, d2 >= 1,
              let df1 = Int(exactly: d1.rounded()),
              let df2 = Int(exactly: d2.rounded()) else { return nil }
        let distribution = DistributionF(df1: df1, df2: df2)
        return { distribution.quantile($0) }
    }

    /// `PsiFatigueLife(loc, scale, shape)` — Birnbaum-Saunders.
    public static let psiFatigueLife = sampling("PSIFATIGUELIFE", minArgs: 3, maxArgs: 5) { args in
        guard let loc = real(args[0]), let scale = real(args[1]), let shape = real(args[2]),
              let distribution = DistributionFatigueLife(location: loc, scale: scale,
                                                         shape: shape) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiFrechet(loc, scale, shape)` — extreme value type II, SciPy's `invweibull`.
    public static let psiFrechet = sampling("PSIFRECHET", minArgs: 3, maxArgs: 5) { args in
        guard let loc = real(args[0]), let scale = real(args[1]), let shape = real(args[2]),
              let distribution = DistributionFrechet(location: loc, scale: scale,
                                                     shape: shape) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiGamma(alpha, beta)` — real shape, so **not** `DistributionGamma`.
    ///
    /// `DistributionGamma` takes `r: Int`, an integer shape, because it builds the
    /// draw as a sum of `r` exponentials. Frontline's `alpha` is real, and rounding
    /// it would silently answer a different distribution — `PsiGamma(2.5, 1)` is not
    /// `PsiGamma(2, 1)`. The free `gammaQuantile(p:shape:scale:)` takes both as
    /// reals and is the correct primitive here.
    public static let psiGamma = sampling("PSIGAMMA", minArgs: 2, maxArgs: 4) { args in
        guard let shape = real(args[0]), let scale = real(args[1]),
              shape > 0, scale > 0 else { return nil }
        return { probability in
            // The gamma's support starts at zero, and a quantile is undefined at the
            // closed end of [0, 1). `nextUniform()` can return exactly zero, so this
            // is reachable rather than defensive.
            guard probability > 0 else { return 0 }
            return try gammaQuantile(p: probability, shape: shape, scale: scale)
        }
    }

    /// `PsiGeometric(p)` — trials until the first success.
    public static let psiGeometric = sampling("PSIGEOMETRIC", minArgs: 1, maxArgs: 3) { args in
        guard let p = real(args[0]), p > 0, p <= 1 else { return nil }
        let distribution = DistributionGeometric(p)
        return { Double(distribution.quantile($0)) }
    }

    /// `PsiHypSecant(loc, scale)` — hyperbolic secant.
    public static let psiHypSecant = sampling("PSIHYPSECANT", minArgs: 2, maxArgs: 4) { args in
        guard let loc = real(args[0]), let scale = real(args[1]),
              let distribution = DistributionHypSecant(loc: loc, scale: scale) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiInvNormal(mu, lambda)` — inverse Gaussian, a.k.a. Wald.
    public static let psiInvNormal = sampling("PSIINVNORMAL", minArgs: 2, maxArgs: 4) { args in
        guard let mu = real(args[0]), let lambda = real(args[1]),
              let distribution = DistributionInverseGaussian(mu: mu,
                                                             lambda: lambda) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiJohnsonSB(shape1, shape2, min, max)` — the bounded Johnson.
    public static let psiJohnsonSB = sampling("PSIJOHNSONSB", minArgs: 4, maxArgs: 6) { args in
        guard let s1 = real(args[0]), let s2 = real(args[1]),
              let low = real(args[2]), let high = real(args[3]),
              let distribution = DistributionJohnsonSB(shape1: s1, shape2: s2,
                                                       min: low, max: high) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiJohnsonSU(shape1, shape2, loc, scale)` — the unbounded Johnson.
    public static let psiJohnsonSU = sampling("PSIJOHNSONSU", minArgs: 4, maxArgs: 6) { args in
        guard let s1 = real(args[0]), let s2 = real(args[1]),
              let loc = real(args[2]), let scale = real(args[3]),
              let distribution = DistributionJohnsonSU(shape1: s1, shape2: s2,
                                                       location: loc,
                                                       scale: scale) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiKumaraswamy(shape1, shape2, min, max)`.
    public static let psiKumaraswamy = sampling("PSIKUMARASWAMY", minArgs: 4, maxArgs: 6) { args in
        guard let s1 = real(args[0]), let s2 = real(args[1]),
              let low = real(args[2]), let high = real(args[3]),
              let distribution = DistributionKumaraswamy(shape1: s1, shape2: s2,
                                                         min: low, max: high) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiLaplace(loc, beta)` — the double exponential; `beta` is the scale.
    public static let psiLaplace = sampling("PSILAPLACE", minArgs: 2, maxArgs: 4) { args in
        guard let loc = real(args[0]), let scale = real(args[1]),
              let distribution = DistributionLaplace(location: loc, scale: scale) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiLevy(loc, scale)` — stable with α = ½. Heavy tailed; the mean does not exist.
    public static let psiLevy = sampling("PSILEVY", minArgs: 2, maxArgs: 4) { args in
        guard let loc = real(args[0]), let scale = real(args[1]),
              let distribution = DistributionLevy(location: loc, scale: scale) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiLogLogistic(gamma, beta, alpha)` — SciPy's `fisk`.
    ///
    /// Frontline's argument order is **location, scale, shape**, which happens to
    /// match BusinessMath's positionally. Worth stating because the names do not:
    /// `alpha` is the shape and arrives third.
    public static let psiLogLogistic = sampling("PSILOGLOGISTIC", minArgs: 3, maxArgs: 5) { args in
        guard let loc = real(args[0]), let scale = real(args[1]), let shape = real(args[2]),
              let distribution = DistributionLogLogistic(location: loc, scale: scale,
                                                         shape: shape) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiLogNorm2(mu, sigma)` — the **log-scale** parameters, passed straight through.
    ///
    /// This is the counterpart to `PsiLogNormal`, which takes the arithmetic moments
    /// and converts them. Here `mu` and `sigma` already describe the underlying
    /// normal, so no conversion is applied — and binding the two to the same
    /// treatment would make one of them wrong.
    public static let psiLogNorm2 = sampling("PSILOGNORM2", minArgs: 2, maxArgs: 4) { args in
        guard let mu = real(args[0]), let sigma = real(args[1]), sigma > 0 else { return nil }
        let distribution = DistributionLogNormal(mu, sigma)
        return { distribution.quantile($0) }
    }

    /// `PsiLogistic(mu, s)` — **`s` is the scale; BusinessMath takes the deviation.**
    ///
    /// A logistic distribution's standard deviation is `s·π/√3`, about 1.814 times
    /// its scale. Passing the scale straight through narrows the distribution by
    /// that factor — a plausible-looking answer that is wrong at every percentile
    /// except the median.
    public static let psiLogistic = sampling("PSILOGISTIC", minArgs: 2, maxArgs: 4) { args in
        guard let mu = real(args[0]), let scale = real(args[1]), scale > 0 else { return nil }
        // π/√3, expressed as a multiplication so there is no divisor to guard:
        // √(1/3) is 1/√3, and both literals are constants.
        let deviation = scale * Double.pi * (1.0 / 3.0).squareRoot()
        let distribution = DistributionLogistic(mu, deviation)
        return { distribution.quantile($0) }
    }

    /// `PsiMaxExtreme(m, s)` — right-skewed Gumbel.
    public static let psiMaxExtreme = sampling("PSIMAXEXTREME", minArgs: 2, maxArgs: 4) { args in
        guard let loc = real(args[0]), let scale = real(args[1]),
              let distribution = DistributionMaxExtreme(location: loc,
                                                        scale: scale) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiMinExtreme(m, s)` — left-skewed Gumbel.
    ///
    /// A distinct distribution from ``psiMaxExtreme``, not its negation, which is
    /// the shortcut BusinessMath's own work list warns against taking.
    public static let psiMinExtreme = sampling("PSIMINEXTREME", minArgs: 2, maxArgs: 4) { args in
        guard let loc = real(args[0]), let scale = real(args[1]),
              let distribution = DistributionMinExtreme(location: loc,
                                                        scale: scale) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiMyerson(a, b, c, t)` — a three-point elicitation, `t` the tail probability.
    public static let psiMyerson = sampling("PSIMYERSON", minArgs: 3, maxArgs: 6) { args in
        guard let low = real(args[0]), let mode = real(args[1]),
              let high = real(args[2]) else { return nil }
        let probability = args.count > 3 ? (real(args[3]) ?? 0.9) : 0.9
        guard let distribution = DistributionMyerson(low: low, mode: mode, high: high,
                                                     probability: probability) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiNegBinomial(s, p)` — failures before the `s`-th success.
    public static let psiNegBinomial = sampling("PSINEGBINOMIAL", minArgs: 2, maxArgs: 4) { args in
        guard let s = real(args[0]), let p = real(args[1]), s >= 1,
              let successes = Int(exactly: s.rounded()),
              let distribution = DistributionNegativeBinomial(successes: successes,
                                                              p: p) else { return nil }
        return { Double(distribution.quantile($0)) }
    }

    /// `PsiPareto(theta, a)` — scale then shape, matching BusinessMath positionally.
    public static let psiPareto = sampling("PSIPARETO", minArgs: 2, maxArgs: 4) { args in
        guard let scale = real(args[0]), let shape = real(args[1]),
              scale > 0, shape > 0 else { return nil }
        let distribution = DistributionPareto(scale: scale, shape: shape)
        return { distribution.quantile($0) }
    }

    /// `PsiPearson5(alpha, beta)` — the inverse gamma.
    public static let psiPearson5 = sampling("PSIPEARSON5", minArgs: 2, maxArgs: 4) { args in
        guard let alpha = real(args[0]), let beta = real(args[1]),
              let distribution = DistributionPearson5(alpha: alpha, beta: beta) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiPearson6(alpha1, alpha2, beta)` — the beta prime.
    public static let psiPearson6 = sampling("PSIPEARSON6", minArgs: 3, maxArgs: 5) { args in
        guard let a1 = real(args[0]), let a2 = real(args[1]), let beta = real(args[2]),
              let distribution = DistributionPearson6(alpha1: a1, alpha2: a2,
                                                      beta: beta) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiRayleigh(beta)` — the scale.
    public static let psiRayleigh = sampling("PSIRAYLEIGH", minArgs: 1, maxArgs: 3) { args in
        guard let scale = real(args[0]), scale > 0 else { return nil }
        let distribution = DistributionRayleigh(scale: scale)
        return { distribution.quantile($0) }
    }

    /// `PsiReciprocal(min, max)` — log-uniform.
    public static let psiReciprocal = sampling("PSIRECIPROCAL", minArgs: 2, maxArgs: 4) { args in
        guard let low = real(args[0]), let high = real(args[1]),
              let distribution = DistributionReciprocal(min: low, max: high) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiStudent(df)` — Student's t.
    public static let psiStudent = sampling("PSISTUDENT", minArgs: 1, maxArgs: 3) { args in
        guard let df = real(args[0]), df >= 1,
              let degrees = Int(exactly: df.rounded()) else { return nil }
        let distribution = DistributionT(degreesOfFreedom: degrees)
        return { distribution.quantile($0) }
    }

    /// `PsiWeibull(alpha, beta)` — shape then scale.
    public static let psiWeibull = sampling("PSIWEIBULL", minArgs: 2, maxArgs: 4) { args in
        guard let shape = real(args[0]), let scale = real(args[1]),
              shape > 0, scale > 0 else { return nil }
        let distribution = DistributionWeibull(shape: shape, scale: scale)
        return { distribution.quantile($0) }
    }

    /// `PsiHyperGeo(n, D, M)` — successes in `n` draws without replacement from a
    /// population of `M` containing `D` marked items.
    ///
    /// Frontline's page contradicts itself, defining the count as successes and then
    /// calling `D` failures. BusinessMath resolved `D` as the **marked** items —
    /// its `REFERENCE` is `scipy.stats.hypergeom`, whose corresponding argument is
    /// the marked category, and binding to a reference while inverting one of its
    /// arguments would make every cross-check meaningless. This follows that.
    public static let psiHyperGeo = sampling("PSIHYPERGEO", minArgs: 3, maxArgs: 5) { args in
        guard let n = real(args[0]), let d = real(args[1]), let m = real(args[2]),
              let draws = Int(exactly: n.rounded()),
              let successes = Int(exactly: d.rounded()),
              let population = Int(exactly: m.rounded()),
              let distribution = DistributionHyperGeometric(draws: draws, successes: successes,
                                                            population: population) else { return nil }
        return { Double(distribution.quantile($0)) }
    }

    /// `PsiLogarithmic(p)` — the logarithmic series distribution, discrete.
    public static let psiLogarithmic = sampling("PSILOGARITHMIC", minArgs: 1, maxArgs: 3) { args in
        guard let p = real(args[0]),
              let distribution = DistributionLogarithmic(p: p) else { return nil }
        return { Double(distribution.quantile($0)) }
    }

    /// `PsiMomentFit(mean, stdev, skew, kurtosis)` — a distribution fitted to four
    /// moments, through the Johnson system.
    ///
    /// Kurtosis is the **non-excess** convention here, so a normal is 3 rather than
    /// 0, matching BusinessMath's default. Frontline documents the same, and the two
    /// conventions differ by exactly 3 — a difference that produces a valid-looking
    /// distribution with the wrong tails rather than an error.
    public static let psiMomentFit = sampling("PSIMOMENTFIT", minArgs: 2, maxArgs: 6) { args in
        guard let mean = real(args[0]), let deviation = real(args[1]),
              deviation > 0 else { return nil }
        let skew = args.count > 2 ? (real(args[2]) ?? 0) : 0
        let kurtosis = args.count > 3 ? (real(args[3]) ?? 3) : 3
        // Not every (skew, kurtosis) pair describes a distribution — the two are
        // constrained by kurtosis >= skew² + 1, and outside that region there is
        // nothing to fit. Constructing inside the sampler lets the caller's catch
        // turn that into #NUM! rather than swallowing it here.
        return { probability in
            let fitted = try DistributionMomentFit(mean: mean, standardDeviation: deviation,
                                                   skewness: skew, kurtosis: kurtosis)
            return fitted.quantile(probability)
        }
    }

    // MARK: - Processes, which carry their previous state in the arguments

    // A process draw is not i.i.d.: each value depends on the last. That looked at
    // first like something a stateless cell evaluation could not express — but
    // Frontline's signatures pass the previous state *in*, precisely because a
    // spreadsheet cell has no memory either. `val0`, `err0` and `stdev0` are
    // arguments, supplied by the cell above. So one step is fully determined, and
    // `StochasticProcess.step(from:dt:normalDraws:)` is exactly that step.

    /// `PsiAR1(mean, volatility, coef1, val0)` — one step of a mean-reverting series.
    ///
    /// `Xₜ = µ + φ(Xₜ₋₁ − µ) + σZ`, with `val0` supplying `Xₜ₋₁`. Stationarity needs
    /// `|φ| < 1`; at φ = 1 the process is a random walk with no long-run mean, which
    /// `AutoregressiveOne` refuses rather than silently modelling.
    public static let psiAR1 = sampling("PSIAR1", minArgs: 4, maxArgs: 6) { args in
        guard let mean = real(args[0]), let volatility = real(args[1]),
              let phi = real(args[2]), let previous = real(args[3]),
              let process = AutoregressiveOne(name: "PsiAR1", persistence: phi,
                                              longRunMean: mean,
                                              shockVolatility: volatility) else { return nil }
        let standardNormal = DistributionNormal(0, 1)
        return { probability in
            process.step(from: previous, dt: 1,
                         normalDraws: standardNormal.quantile(probability))
        }
    }

    /// `PsiGARCH11(mean, volatility, err_coef, ar_coef, val0, stdev0)` — one step of a
    /// GARCH(1,1) return series.
    ///
    /// `σ²ₜ = ω + α·r²ₜ₋₁ + β·σ²ₜ₋₁`, with `val0` and `stdev0` supplying the previous
    /// return and its volatility.
    ///
    /// **One inference, stated because it is one.** `GarchOneOne` takes the constant
    /// `ω`; Frontline states a `volatility`. Read as the *long-run* volatility — the
    /// name it is given throughout this family, and the quantity a modeller actually
    /// knows — it fixes `ω` through the stationary variance, `ω = σ²(1 − α − β)`.
    /// That requires `α + β < 1`, which is also the stationarity condition, so a
    /// parameterisation that fails it has no long-run volatility to state.
    public static let psiGARCH11 = sampling("PSIGARCH11", minArgs: 6, maxArgs: 8) { args in
        guard let mean = real(args[0]), let volatility = real(args[1]),
              let alpha = real(args[2]), let beta = real(args[3]),
              let previousValue = real(args[4]), let previousDeviation = real(args[5]),
              volatility > 0, previousDeviation >= 0 else { return nil }
        let persistence = alpha + beta
        guard persistence < 1 else { return nil }
        let constant = volatility * volatility * (1 - persistence)
        guard let process = GarchOneOne(name: "PsiGARCH11", constant: constant,
                                        shockWeight: alpha,
                                        persistenceWeight: beta) else { return nil }
        // The state holds the previous *return*, centred at zero, so the mean comes
        // off the way in and back on the way out.
        let state = GarchState(value: previousValue - mean,
                               variance: previousDeviation * previousDeviation)
        let standardNormal = DistributionNormal(0, 1)
        return { probability in
            mean + process.step(from: state, dt: 1,
                                normalDraws: standardNormal.quantile(probability)).value
        }
    }

    /// `PsiMetalog(min, max, coefficients)` — Keelin's quantile-parameterised
    /// distribution, bounded to `[min, max]`.
    ///
    /// Frontline documents this as `PsiMetalog(min, max, coefficients, prop_fcns)`,
    /// and the fourth is not a parameter: `prop_fcn` is Frontline's general
    /// property-function slot, the one that carries `PsiTruncate`, `PsiBaseCase` and
    /// `PsiName`. `attached(_:_:)` already removes those before a distribution sees
    /// its arguments, so the parameters here are the three that remain — which is
    /// also why the leading bounds being "optional" never creates an ambiguity about
    /// whether argument one is a bound or a coefficient.
    public static let psiMetalog = sampling("PSIMETALOG", minArgs: 3, maxArgs: 5) { args in
        guard let low = real(args[0]), let high = real(args[1]), low < high else { return nil }
        let coefficients = series(args[2])
        guard coefficients.count >= 2 else { return nil }
        return { probability in
            let distribution = try DistributionMetalog(
                coefficients: coefficients,
                boundedness: .bounded(lower: low, upper: high))
            return distribution.quantile(probability)
        }
    }

    // MARK: - Taking a list rather than parameters

    /// `PsiCumul(a, b, {x}, {p})` — a piecewise-linear CDF through the given points.
    public static let psiCumul = sampling("PSICUMUL", minArgs: 4, maxArgs: 6) { args in
        guard let low = real(args[0]), let high = real(args[1]) else { return nil }
        let values = series(args[2])
        let probabilities = series(args[3])
        guard !values.isEmpty, values.count == probabilities.count,
              let distribution = DistributionCumul(lower: low, upper: high, values: values,
                                                   probabilities: probabilities) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiGeneral(a, b, {x}, {w})` — a piecewise-linear *density* through weighted points.
    ///
    /// The sibling of ``psiCumul`` and not the same thing: this states a density,
    /// that one states a cumulative.
    public static let psiGeneral = sampling("PSIGENERAL", minArgs: 4, maxArgs: 6) { args in
        guard let low = real(args[0]), let high = real(args[1]) else { return nil }
        let values = series(args[2])
        let weights = series(args[3])
        guard !values.isEmpty, values.count == weights.count,
              let distribution = DistributionGeneral(lower: low, upper: high, values: values,
                                                     weights: weights) else { return nil }
        return { distribution.quantile($0) }
    }

    /// `PsiDisUniform({x})` — uniform over an explicit set of values.
    ///
    /// `quantile` returns an index, as it does for `PsiDiscrete`; the value is read
    /// out of the list the caller supplied.
    public static let psiDisUniform = sampling("PSIDISUNIFORM", minArgs: 1, maxArgs: 3) { args in
        let values = series(args[0])
        guard !values.isEmpty,
              let distribution = DistributionDiscreteUniform(values: values) else { return nil }
        return { probability in
            let index = distribution.quantile(probability)
            return index >= 0 && index < values.count ? values[index] : values[0]
        }
    }

    /// `PsiResample(data)` — draw from the data **with** replacement.
    public static let psiResample = sampling("PSIRESAMPLE", minArgs: 1, maxArgs: 3) { args in
        let values = series(args[0])
        guard !values.isEmpty,
              let distribution = DistributionDiscreteUniform(values: values) else { return nil }
        return { probability in
            let index = distribution.quantile(probability)
            return index >= 0 && index < values.count ? values[index] : values[0]
        }
    }

    /// `PsiShuffle(data)` — draw from the data **without** replacement.
    ///
    /// Sampling without replacement is a property of a *sequence* of draws, and a
    /// cell evaluation is a single draw with no memory of the last one. So for one
    /// cell this is the same answer as ``psiResample``, and across many cells it is
    /// not what Frontline would produce — a permutation never repeats a value and
    /// this can.
    ///
    /// Bound anyway, and documented, because the alternative is `#NAME?` on a
    /// workbook that is otherwise readable. Honouring the distinction needs
    /// simulation-level state that this package does not have and should not invent.
    public static let psiShuffle = sampling("PSISHUFFLE", minArgs: 1, maxArgs: 3) { args in
        let values = series(args[0])
        guard !values.isEmpty,
              let distribution = DistributionDiscreteUniform(values: values) else { return nil }
        return { probability in
            let index = distribution.quantile(probability)
            return index >= 0 && index < values.count ? values[index] : values[0]
        }
    }
}
