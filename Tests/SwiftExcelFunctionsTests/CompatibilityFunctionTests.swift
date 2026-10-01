import Foundation
import SwiftExcelCore
import Foundation
import Testing
@testable import SwiftExcelFunctions

/// Excel's pre-2010 statistical spellings, and what they actually mean.
///
/// ## Why these are tested structurally rather than numerically
///
/// Every one of these delegates to a modern function whose mathematics is already tested.
/// Re-asserting the numbers here would test the same code twice and prove nothing about the
/// thing that can actually be wrong, which is **the mapping**. `CHIDIST` is `CHISQ.DIST.RT`
/// and not `CHISQ.DIST`; get that backwards and every result is a probability in the right
/// range, plausible, and wrong. Nothing about the output says which one you got.
///
/// So the assertions compare a legacy name against the modern one it claims to be. A legacy
/// function that drifted from its twin would fail, which is the only failure mode delegation
/// leaves open.
///
/// **Provenance:** the mappings come from Microsoft's documented legacy/modern pairs, not
/// from Excel itself. Documentation has been wrong four times this cycle. The five that are
/// not plain aliases are the ones worth checking against a real workbook.
@Suite struct CompatibilityFunctionTests {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: [CellValue]) throws -> CellValue {
        let function = try #require(registry.function(named: name), "\(name) is not registered")
        return try function.evaluate(args)
    }

    private func n(_ values: Double...) -> [CellValue] { values.map { .number($0) } }

    // MARK: - Every legacy name resolves

    @Test func allTwentySixLegacyNamesAreRegistered() throws {
        let legacy = [
            "BETADIST", "BETAINV", "BINOMDIST", "CHIDIST", "CHIINV", "CHITEST", "CONFIDENCE",
            "CRITBINOM", "EXPONDIST", "FDIST", "FINV", "FTEST", "GAMMADIST", "GAMMAINV",
            "HYPGEOMDIST", "LOGINV", "LOGNORMDIST", "NEGBINOMDIST", "PERCENTRANK", "POISSON",
            "QUARTILE", "TDIST", "TINV", "TTEST", "WEIBULL", "ZTEST",
        ]
        #expect(legacy.count == 26)
        for name in legacy {
            #expect(registry.resolvedName(name) == FunctionRegistry.canonical(name), "\(name) is not registered")
        }
    }

    // MARK: - The plain aliases

    /// Each legacy name must agree with the modern one it stands for, argument for argument.
    @Test func plainAliasesAgreeWithTheirModernSpelling() throws {
        let cases: [(legacy: String, modern: String, args: [CellValue])] = [
            ("BETAINV",    "BETA.INV",        n(0.4, 2, 3)),
            ("BINOMDIST",  "BINOM.DIST",      [.number(3), .number(10), .number(0.3), .bool(true)]),
            ("CHIDIST",    "CHISQ.DIST.RT",   n(3.5, 4)),
            ("CHIINV",     "CHISQ.INV.RT",    n(0.25, 4)),
            ("CONFIDENCE", "CONFIDENCE.NORM", n(0.05, 2.5, 50)),
            ("CRITBINOM",  "BINOM.INV",       n(10, 0.3, 0.6)),
            ("EXPONDIST",  "EXPON.DIST",      [.number(0.5), .number(2), .bool(true)]),
            ("FDIST",      "F.DIST.RT",       n(2.5, 3, 7)),
            ("FINV",       "F.INV.RT",        n(0.25, 3, 7)),
            ("GAMMADIST",  "GAMMA.DIST",      [.number(2), .number(3), .number(1.5), .bool(true)]),
            ("GAMMAINV",   "GAMMA.INV",       n(0.4, 3, 1.5)),
            ("LOGINV",     "LOGNORM.INV",     n(0.4, 1, 0.5)),
            ("POISSON",    "POISSON.DIST",    [.number(3), .number(2.5), .bool(true)]),
            ("TINV",       "T.INV.2T",        n(0.1, 8)),
            ("WEIBULL",    "WEIBULL.DIST",    [.number(2), .number(1.5), .number(3), .bool(true)]),
        ]
        for (legacy, modern, args) in cases {
            let old = try call(legacy, args)
            let new = try call(modern, args)
            #expect(old == new, "\(legacy) must mean exactly \(modern)")
            if case .error = old { Issue.record("\(legacy) sample returned an error: \(old)") }
        }
    }

    /// The array-taking ones, kept separate because their arguments are ranges.
    @Test func arrayTakingAliasesAgree() throws {
        let a: CellValue = .array(CellMatrix(row: [1, 2, 3, 4].map { CellValue.number($0) }))
        let b: CellValue = .array(CellMatrix(row: [2, 3, 3, 5].map { CellValue.number($0) }))

        #expect(try call("CHITEST", [a, b]) == call("CHISQ.TEST", [a, b]))
        #expect(try call("FTEST", [a, b]) == call("F.TEST", [a, b]))
        #expect(try call("TTEST", [a, b, .number(2), .number(1)]) == call("T.TEST", [a, b, .number(2), .number(1)]))
        #expect(try call("ZTEST", [a, .number(2)]) == call("Z.TEST", [a, .number(2)]))
        #expect(try call("QUARTILE", [a, .number(1)]) == call("QUARTILE.INC", [a, .number(1)]))
        #expect(try call("PERCENTRANK", [a, .number(3)]) == call("PERCENTRANK.INC", [a, .number(3)]))
    }

    // MARK: - The five that are not aliases

    /// `LOGNORMDIST` is the cumulative form only; `LOGNORM.DIST` takes a flag.
    @Test func logNormDistIsAlwaysCumulative() throws {
        let args = n(2, 1, 0.5)
        let legacy = try call("LOGNORMDIST", args)
        #expect(try legacy == call("LOGNORM.DIST", args + [.bool(true)]))
        #expect(try legacy != call("LOGNORM.DIST", args + [.bool(false)]), "the density and the CDF must not be the same number here")
    }

    /// `HYPGEOMDIST` is the probability mass, not the cumulative.
    @Test func hypGeomDistIsNotCumulative() throws {
        let args = n(1, 4, 8, 20)
        let legacy = try call("HYPGEOMDIST", args)
        #expect(try legacy == call("HYPGEOM.DIST", args + [.bool(false)]))
        #expect(try legacy != call("HYPGEOM.DIST", args + [.bool(true)]))
    }

    /// `NEGBINOMDIST` is likewise the mass function.
    @Test func negBinomDistIsNotCumulative() throws {
        let args = n(3, 5, 0.4)
        let legacy = try call("NEGBINOMDIST", args)
        #expect(try legacy == call("NEGBINOM.DIST", args + [.bool(false)]))
        #expect(try legacy != call("NEGBINOM.DIST", args + [.bool(true)]))
    }

    /// `BETADIST` is cumulative, and the flag sits *inside* the argument list.
    ///
    /// `BETA.DIST(x, alpha, beta, cumulative, [A], [B])` — so the bounds move along by one.
    /// Appending rather than inserting would pass the cumulative flag as `A`.
    @Test func betaDistIsCumulativeAndTheBoundsStayInPlace() throws {
        #expect(try call("BETADIST", n(0.4, 2, 3)) == call("BETA.DIST", [.number(0.4), .number(2), .number(3), .bool(true)]))
        #expect(try call("BETADIST", n(4, 2, 3, 0, 10)) == call("BETA.DIST", [.number(4), .number(2), .number(3), .bool(true),
                                              .number(0), .number(10)]))
    }

    /// `TDIST` is not `T.DIST.2T`. It dispatches on a tails argument.
    @Test func tDistDispatchesOnItsTailsArgument() throws {
        #expect(try call("TDIST", n(1.5, 8, 1)) == call("T.DIST.RT", n(1.5, 8)), "one tail means the right tail")
        #expect(try call("TDIST", n(1.5, 8, 2)) == call("T.DIST.2T", n(1.5, 8)), "two tails means the two-tailed probability")
        #expect(try call("TDIST", n(1.5, 8, 1)) != call("TDIST", n(1.5, 8, 2)), "the tails argument has to change the answer")
    }

    @Test func tDistRefusesWhatExcelRefuses() throws {
        // Microsoft: TDIST returns #NUM! for negative x, unlike T.DIST.
        #expect(try call("TDIST", n(-1.5, 8, 2)) == .error(.num))
        // Tails is 1 or 2, and nothing else.
        #expect(try call("TDIST", n(1.5, 8, 3)) == .error(.num))
        #expect(try call("TDIST", n(1.5, 8, 0)) == .error(.num))
    }

    // MARK: - BETA.DIST, which had to be written rather than delegated to

    @Test func betaDistIsRegisteredInItsOwnRight() throws {
        #expect(registry.resolvedName("BETA.DIST") == "BETA.DIST")
    }

    /// Its CDF must be the inverse of `BETA.INV`, which is already tested.
    ///
    /// Holding the new function against an existing one is worth more than a literal: it
    /// checks the parameterisation agrees, which is where a beta implementation goes wrong.
    @Test func betaDistInvertsBetaInverse() throws {
        for probability in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let x = try call("BETA.INV", n(probability, 2, 3))
            guard case .number(let value) = x else { Issue.record("BETA.INV gave \(x)"); return }
            let back = try call("BETA.DIST", [.number(value), .number(2), .number(3), .bool(true)])
            guard case .number(let round) = back else { Issue.record("BETA.DIST gave \(back)"); return }
            #expect(abs(round - probability) <= 1e-6)
        }
    }

    @Test func betaDistRefusesADomainItCannotAnswer() throws {
        #expect(try call("BETA.DIST", [.number(0.5), .number(0), .number(3), .bool(true)]) == .error(.num), "alpha must be positive")
        #expect(try call("BETA.DIST", [.number(4), .number(2), .number(3), .bool(true),
                                              .number(10), .number(0)]) == .error(.num), "the bounds must be the right way round")
    }
}
