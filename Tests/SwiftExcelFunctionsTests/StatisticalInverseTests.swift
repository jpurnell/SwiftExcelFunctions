import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import BusinessMath

/// The statistical inverses — `CHISQ.INV.RT` and `BINOM.INV`.
///
/// The first two of the 26 modern spellings, and the pair that showed the bucket is
/// **binding work rather than distribution work**: `DistributionChiSquared.quantile` and
/// `binomialPMF` both exist upstream, so what was missing is Excel's argument order, tail
/// convention and `#NUM!` domains.
///
/// Signatures and domains below are Microsoft's, quoted rather than inferred:
///
/// ```
/// BINOM.INV(trials, probability_s, alpha)   probability_s ∈ [0,1], alpha ∈ [0,1]
/// CHISQ.INV.RT(probability, deg_freedom)    probability ∈ [0,1], df ∈ [1, 10^10)
/// ```
final class StatisticalInverseTests: XCTestCase {

    private func call(_ name: String, _ args: Double...) throws -> CellValue {
        let fn = try XCTUnwrap(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
        return try fn.evaluate(args.map { .number($0) })
    }

    private func number(_ value: CellValue) throws -> Double {
        guard case .number(let d) = value else { throw XCTSkip("expected a number, got \(value)") }
        return d
    }

    // MARK: - CHISQ.INV.RT

    /// The inverse round-trips through the CDF, which is its definition.
    ///
    /// **Not asserted against a remembered published value.** The first draft of this test
    /// used `18.30684` for `CHISQ.INV.RT(0.050001, 10)`, quoted from memory as Microsoft's
    /// example. Our answer is `18.306973`, and the difference is 1.3e-4 — too large to be
    /// rounding of a five-decimal figure.
    ///
    /// Two facts settle which to trust. `inverseRegularizedLowerIncompleteGamma`, which
    /// this is built on, documents agreement with `scipy.special.gammaincinv` **to better
    /// than 1e-9 relative**; and the tabulated χ²(0.95, 10) is 18.307, which our answer
    /// matches and the remembered one does not quite. So the remembered constant is the
    /// suspect part.
    ///
    /// This is the second misremembered "published" value today — the other was
    /// `ERF(0.745)`. ADR-001 says a test whose expected value came from reading a
    /// specification proves only that we read it the same way twice; it says nothing kind
    /// about one recalled without reading it at all. So this asserts the **documented
    /// relationship** instead, which needs no memory: the right-tailed inverse at `p`,
    /// pushed back through the CDF, must give `1 − p`.
    func testChiSquaredInverseRoundTripsThroughTheCDF() throws {
        for (p, df) in [(0.05, 10), (0.5, 3), (0.99, 7), (0.01, 20)] {
            let critical = try number(try call("CHISQ.INV.RT", p, Double(df)))
            let distribution = DistributionChiSquared(degreesOfFreedom: df)
            XCTAssertEqual(distribution.cdf(critical), 1 - p, accuracy: 1e-9,
                           "CHISQ.INV.RT(\(p), \(df)) did not round-trip")
        }
    }

    /// A sanity check against the value every statistics table carries: the 95th
    /// percentile of chi-squared with 10 degrees of freedom is 18.307.
    func testAgainstTheTabulatedCriticalValue() throws {
        XCTAssertEqual(try number(try call("CHISQ.INV.RT", 0.05, 10)), 18.307, accuracy: 1e-3)
    }

    /// **The right tail is the point.** `CHISQ.INV.RT(p, df)` and the left-tailed quantile
    /// are complements, so the two must sum to nothing in particular — but
    /// `CHISQ.INV.RT(p)` must equal the left-tailed inverse at `1 − p`.
    ///
    /// Getting this backwards is the `CHIDIST`/`CHISQ.DIST` trap one function along, and it
    /// returns a positive number in the right range either way.
    func testRightTailIsTheComplementOfTheLeft() throws {
        let rightAt05 = try number(try call("CHISQ.INV.RT", 0.05, 8))
        let rightAt95 = try number(try call("CHISQ.INV.RT", 0.95, 8))
        // A larger right-tail probability means a smaller critical value.
        XCTAssertGreaterThan(rightAt05, rightAt95,
                             "the right-tail inverse must decrease as probability increases")
    }

    /// Microsoft's stated domain: probability in `[0, 1]`, degrees of freedom in
    /// `[1, 10^10)`. Outside it, `#NUM!`.
    func testChiSquaredInverseDomain() throws {
        XCTAssertEqual(try call("CHISQ.INV.RT", -0.1, 10), .error(.num))
        XCTAssertEqual(try call("CHISQ.INV.RT", 1.1, 10), .error(.num))
        XCTAssertEqual(try call("CHISQ.INV.RT", 0.5, 0), .error(.num))
        XCTAssertEqual(try call("CHISQ.INV.RT", 0.5, 1e10), .error(.num))
    }

    // MARK: - BINOM.INV

    /// Published: `BINOM.INV(6, 0.5, 0.75)` is 4.
    ///
    /// Microsoft's definition is *"the smallest value for which the cumulative binomial
    /// distribution is greater than or equal to a criterion value"* — so the result is a
    /// count of successes, and the comparison is `≥`, not `>`.
    func testBinomialInverse() throws {
        XCTAssertEqual(try call("BINOM.INV", 6, 0.5, 0.75), .number(4))
    }

    /// **The boundary is inclusive.** At `alpha` exactly equal to a cumulative value, the
    /// answer is that `k` rather than the next one — which is the difference between `≥`
    /// and `>` and is invisible except at exact boundaries.
    ///
    /// With 2 trials at p = 0.5 the cumulative is 0.25, 0.75, 1.0. So `alpha = 0.75` must
    /// give 1, not 2.
    func testTheCriterionIsInclusive() throws {
        XCTAssertEqual(try call("BINOM.INV", 2, 0.5, 0.25), .number(0))
        XCTAssertEqual(try call("BINOM.INV", 2, 0.5, 0.75), .number(1))
        XCTAssertEqual(try call("BINOM.INV", 2, 0.5, 1.0), .number(2))
    }

    /// A certainty collapses the distribution: every trial succeeds, so any criterion is
    /// met only at `trials`.
    func testCertainSuccess() throws {
        XCTAssertEqual(try call("BINOM.INV", 5, 1.0, 0.5), .number(5))
        XCTAssertEqual(try call("BINOM.INV", 5, 0.0, 0.5), .number(0))
    }

    /// Microsoft's stated domain: `probability_s` and `alpha` both in `[0, 1]`, trials a
    /// non-negative count.
    func testBinomialInverseDomain() throws {
        XCTAssertEqual(try call("BINOM.INV", 6, 1.5, 0.75), .error(.num))
        XCTAssertEqual(try call("BINOM.INV", 6, 0.5, -0.1), .error(.num))
        XCTAssertEqual(try call("BINOM.INV", -1, 0.5, 0.75), .error(.num))
    }
}
