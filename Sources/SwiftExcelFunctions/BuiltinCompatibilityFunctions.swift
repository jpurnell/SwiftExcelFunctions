import Foundation
import SwiftExcelCore

/// Excel's pre-2010 statistical spellings, kept working.
///
/// Excel 2010 renamed most of the statistical library — `CHIDIST` became `CHISQ.DIST.RT`,
/// `TINV` became `T.INV.2T` — and then kept every old name working for ever, because
/// twenty years of workbooks call them. A reader that answers only the modern spellings
/// cannot open a file written before 2010, which is most of the files there are.
///
/// ## Every one of these delegates
///
/// Not one reimplements its modern twin. `CHIDIST` calls `CHISQ.DIST.RT` and returns what it
/// returns, because a second implementation that could disagree with the first is the exact
/// failure this package exists to prevent — the same reason the mathematics lives in
/// BusinessMath rather than here. Delegation makes drift impossible rather than unlikely.
///
/// ## The mapping is the part that can be wrong
///
/// Twenty-one are plain aliases. Five are not, and each is a trap that returns a plausible
/// number rather than an error when it is read wrongly:
///
/// | Legacy | Modern | Why it is not an alias |
/// |---|---|---|
/// | `BETADIST` | `BETA.DIST(…, TRUE, [A], [B])` | cumulative only, and the flag sits **before** the bounds |
/// | `HYPGEOMDIST` | `HYPGEOM.DIST(…, FALSE)` | the mass function, not the cumulative |
/// | `LOGNORMDIST` | `LOGNORM.DIST(…, TRUE)` | cumulative only |
/// | `NEGBINOMDIST` | `NEGBINOM.DIST(…, FALSE)` | the mass function |
/// | `TDIST` | `T.DIST.RT` **or** `T.DIST.2T` | dispatches on a tails argument, and refuses negative `x` |
///
/// `TDIST` is the sharpest of them: it is not `T.DIST.2T` with a different name, and reading
/// it as one gives every single-tailed caller twice the probability they asked for.
///
/// **Provenance.** These pairings come from Microsoft's documentation rather than from Excel.
/// Documentation has been wrong four times in this project's short life — the `FORECAST.ETS`
/// aggregation codes were a different base *and* a different order than published. None of
/// these functions is called by any workbook in the 2,240-file corpus, so there is nothing to
/// check them against here; the five above are the ones worth a hand-built workbook.
public enum BuiltinCompatibilityFunctions {

    /// Every legacy spelling, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        betaDist, betaInv, binomDist, chiDist, chiInv, chiTest, confidence, critBinom,
        exponDist, fDist, fInv, fTest, gammaDist, gammaInv, hypGeomDist, logInv, logNormDist,
        negBinomDist, percentRank, poisson, quartile, tDist, tInv, tTest, weibull, zTest,
    ]

    // MARK: - The twenty-one plain aliases

    /// `BETAINV(probability, alpha, beta, [A], [B])` — now `BETA.INV`.
    public static let betaInv = alias("BETAINV", of: BuiltinStatisticalQuantiles.betaInverse)

    /// `BINOMDIST(number_s, trials, probability_s, cumulative)` — now `BINOM.DIST`.
    public static let binomDist = alias("BINOMDIST", of: BuiltinStatisticalDistributions.binomDist)

    /// `CHIDIST(x, deg_freedom)` — now `CHISQ.DIST.RT`, the **right** tail.
    ///
    /// Not `CHISQ.DIST`, which is left-tailed and returns a probability in the same range for
    /// every input. The name is the only thing that distinguishes them.
    public static let chiDist = alias(
        "CHIDIST", of: BuiltinStatisticalDistributions.chiSquaredDistRightTail)

    /// `CHIINV(probability, deg_freedom)` — now `CHISQ.INV.RT`.
    public static let chiInv = alias(
        "CHIINV", of: BuiltinStatisticalInverses.chiSquaredInverseRightTail)

    /// `CHITEST(actual_range, expected_range)` — now `CHISQ.TEST`.
    public static let chiTest = alias("CHITEST", of: BuiltinStatisticalTests.chiSquaredTest)

    /// `CONFIDENCE(alpha, standard_dev, size)` — now `CONFIDENCE.NORM`.
    ///
    /// The normal form, not `CONFIDENCE.T`: the legacy function assumed a known population
    /// deviation, and 2010 split that assumption out into the name.
    public static let confidence = alias(
        "CONFIDENCE", of: BuiltinStatisticalTests.confidenceNorm)

    /// `CRITBINOM(trials, probability_s, alpha)` — now `BINOM.INV`.
    ///
    /// The rename is total: nothing of the old name survives in the new one.
    public static let critBinom = alias("CRITBINOM", of: BuiltinStatisticalInverses.binomialInverse)

    /// `EXPONDIST(x, lambda, cumulative)` — now `EXPON.DIST`.
    public static let exponDist = alias("EXPONDIST", of: BuiltinStatisticalDistributions.exponDist)

    /// `FDIST(x, deg_freedom1, deg_freedom2)` — now `F.DIST.RT`, the **right** tail.
    ///
    /// `F.DIST` exists too and is left-tailed with a cumulative flag. The legacy name means
    /// the right-tailed one.
    public static let fDist = alias("FDIST", of: BuiltinStatisticalDistributions.fDistRightTail)

    /// `FINV(probability, deg_freedom1, deg_freedom2)` — now `F.INV.RT`.
    public static let fInv = alias("FINV", of: BuiltinStatisticalQuantiles.fInverseRightTail)

    /// `FTEST(array1, array2)` — now `F.TEST`.
    public static let fTest = alias("FTEST", of: BuiltinStatisticalTests.fTest)

    /// `GAMMADIST(x, alpha, beta, cumulative)` — now `GAMMA.DIST`.
    public static let gammaDist = alias("GAMMADIST", of: BuiltinStatisticalDistributions.gammaDist)

    /// `GAMMAINV(probability, alpha, beta)` — now `GAMMA.INV`.
    public static let gammaInv = alias("GAMMAINV", of: BuiltinStatisticalQuantiles.gammaInverse)

    /// `LOGINV(probability, mean, standard_dev)` — now `LOGNORM.INV`.
    public static let logInv = alias("LOGINV", of: BuiltinStatisticalQuantiles.logNormInverse)

    /// `PERCENTRANK(array, x, [significance])` — now `PERCENTRANK.INC`.
    ///
    /// The inclusive form. `PERCENTRANK.EXC` is a different function that did not exist
    /// before 2010, so there is no legacy spelling of it to confuse this with.
    public static let percentRank = alias(
        "PERCENTRANK", of: BuiltinSpreadsheetStatistics.percentRankInclusive)

    /// `POISSON(x, mean, cumulative)` — now `POISSON.DIST`.
    public static let poisson = alias("POISSON", of: BuiltinStatisticalDistributions.poissonDist)

    /// `QUARTILE(array, quart)` — now `QUARTILE.INC`.
    public static let quartile = alias(
        "QUARTILE", of: BuiltinSpreadsheetStatistics.quartileInclusive)

    /// `TINV(probability, deg_freedom)` — now `T.INV.2T`, the **two-tailed** inverse.
    ///
    /// The asymmetry is worth noticing: `TINV` is two-tailed while `TDIST` chooses its tails
    /// from an argument, so the legacy pair are not inverses of each other by default.
    public static let tInv = alias("TINV", of: BuiltinStatisticalQuantiles.tInverseTwoTailed)

    /// `TTEST(array1, array2, tails, type)` — now `T.TEST`.
    public static let tTest = alias("TTEST", of: BuiltinSpreadsheetStatistics.tTest)

    /// `WEIBULL(x, alpha, beta, cumulative)` — now `WEIBULL.DIST`.
    public static let weibull = alias("WEIBULL", of: BuiltinStatisticalTests.weibullDist)

    /// `ZTEST(array, x, [sigma])` — now `Z.TEST`.
    public static let zTest = alias("ZTEST", of: BuiltinStatisticalTests.zTest)

    // MARK: - The four whose cumulative flag is implied

    /// `BETADIST(x, alpha, beta, [A], [B])` — `BETA.DIST(…, TRUE, [A], [B])`.
    ///
    /// The flag is **inserted at position 3**, not appended. `BETA.DIST` puts `cumulative`
    /// before the optional bounds, so appending would pass `TRUE` as `A` and silently move
    /// the distribution onto `[TRUE, B]`.
    public static let betaDist = legacy(
        "BETADIST", of: BuiltinStatisticalDistributions.betaDist,
        inserting: .bool(true), at: 3, minArgs: 3, maxArgs: 5)

    /// `HYPGEOMDIST(sample_s, number_sample, population_s, number_pop)` —
    /// `HYPGEOM.DIST(…, FALSE)`, the probability mass rather than the cumulative.
    public static let hypGeomDist = legacy(
        "HYPGEOMDIST", of: BuiltinStatisticalTests.hypGeomDist,
        inserting: .bool(false), at: 4, minArgs: 4, maxArgs: 4)

    /// `LOGNORMDIST(x, mean, standard_dev)` — `LOGNORM.DIST(…, TRUE)`, cumulative only.
    public static let logNormDist = legacy(
        "LOGNORMDIST", of: BuiltinStatisticalDistributions.logNormDist,
        inserting: .bool(true), at: 3, minArgs: 3, maxArgs: 3)

    /// `NEGBINOMDIST(number_f, number_s, probability_s)` — `NEGBINOM.DIST(…, FALSE)`, the
    /// probability mass rather than the cumulative.
    public static let negBinomDist = legacy(
        "NEGBINOMDIST", of: BuiltinStatisticalTests.negBinomDist,
        inserting: .bool(false), at: 3, minArgs: 3, maxArgs: 3)

    // MARK: - The one that dispatches

    /// `TDIST(x, deg_freedom, tails)` — one tail or two, chosen by the third argument.
    ///
    /// **This is not `T.DIST.2T` under an old name.** `tails = 1` is the right-tailed
    /// probability and `tails = 2` is twice it; reading the function as always two-tailed
    /// hands every single-tailed caller double the probability they asked for, which is a
    /// number of exactly the right shape.
    ///
    /// It also refuses a negative `x`, which `T.DIST` accepts. The legacy function predates
    /// the symmetric form and Microsoft documents `#NUM!` there, so the refusal is Excel's
    /// rather than ours.
    public static let tDist = ExcelFunction(name: "TDIST", minArgs: 3, maxArgs: 3) { values in
        if let error = BuiltinStatisticalDistributions.firstError(values) { return error }
        guard let x = BuiltinStatisticalDistributions.real(values.first),
              let tails = BuiltinStatisticalDistributions.real(values[2]) else {
            return .error(.value)
        }
        guard x >= 0 else { return .error(.num) }

        let arguments = Array(values.prefix(2))
        switch tails {
        case 1: return try BuiltinSpreadsheetStatistics.tDistRightTail.evaluate(arguments)
        case 2: return try BuiltinStatisticalDistributions.tDistTwoTailed.evaluate(arguments)
        default: return .error(.num)
        }
    }

    // MARK: - Delegation

    /// A legacy name that means exactly what a modern one does.
    ///
    /// The arity is taken from the modern function rather than restated, so the two cannot
    /// fall out of step when one of them gains an optional argument.
    private static func alias(_ name: String, of modern: ExcelFunction) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: modern.minArgs, maxArgs: modern.maxArgs) { values in
            try modern.evaluate(values)
        }
    }

    /// A legacy name whose modern form takes one more argument than it does.
    ///
    /// - Parameters:
    ///   - name: The legacy spelling.
    ///   - modern: The function it delegates to.
    ///   - implied: The argument the legacy form does not take and always means.
    ///   - index: Where that argument sits in the modern signature — **not** always the end.
    ///   - minArgs: The legacy minimum.
    ///   - maxArgs: The legacy maximum.
    private static func legacy(_ name: String, of modern: ExcelFunction,
                               inserting implied: CellValue, at index: Int,
                               minArgs: Int, maxArgs: Int) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: minArgs, maxArgs: maxArgs) { values in
            var arguments = values
            // Clamped rather than trusted: the evaluator enforces `minArgs`, but a direct
            // caller is not obliged to, and inserting past the end would trap.
            arguments.insert(implied, at: min(index, arguments.count))
            return try modern.evaluate(arguments)
        }
    }
}
