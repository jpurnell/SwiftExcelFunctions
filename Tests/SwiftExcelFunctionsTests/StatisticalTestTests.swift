import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore
import BusinessMath

/// The remaining distributions and the two hypothesis tests.
///
/// `CHISQ.TEST` and `F.TEST` were the two rows I called blocked on "a statistic written
/// nowhere". That overstated it: each reduces to arithmetic over its inputs plus a CDF
/// that exists. `Σ(O−E)²/E` is a sum, and a variance ratio is a division — neither is an
/// algorithm anyone is missing.
@Suite struct StatisticalTestTests {

    private func fn(_ name: String) throws -> ExcelFunction {
        try #require(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
    }

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        try fn(name).evaluate(args)
    }

    private func n(_ name: String, _ args: CellValue...) throws -> Double {
        guard case .number(let d) = try fn(name).evaluate(args) else {
            throw TestFailure("\(name) did not return a number")
        }
        return d
    }

    private func row(_ values: [Double]) -> CellValue {
        .array(CellMatrix(row: values.map { .number($0) }))
    }

    // MARK: - The remaining distributions

    /// A discrete cumulative is the sum of its masses — the same relationship that graded
    /// `BINOM.DIST` and `POISSON.DIST`.
    @Test func negativeBinomialCumulativeIsTheSumOfItsMasses() throws {
        var masses = 0.0
        for k in 0...5 {
            masses += try n("NEGBINOM.DIST", .number(Double(k)), .number(3), .number(0.4), .bool(false))
        }
        #expect(try abs(masses - n("NEGBINOM.DIST", .number(5), .number(3), .number(0.4), .bool(true))) <= 1e-12)
    }

    @Test func hypergeometricCumulativeIsTheSumOfItsMasses() throws {
        var masses = 0.0
        for k in 0...3 {
            masses += try n("HYPGEOM.DIST",
                            .number(Double(k)), .number(4), .number(8), .number(20), .bool(false))
        }
        #expect(try abs(masses - n("HYPGEOM.DIST",
                             .number(3), .number(4), .number(8), .number(20), .bool(true))) <= 1e-12)
    }

    /// The Weibull CDF is `1 − e^(−(x/β)^α)`, straight from the definition.
    @Test func weibullCumulative() throws {
        let x = 2.0, alpha = 1.5, beta = 3.0
        let expected = 1 - Foundation.exp(-Foundation.pow(x / beta, alpha))
        #expect(try abs(n("WEIBULL.DIST", .number(x), .number(alpha), .number(beta), .bool(true)) - expected) <= 1e-12)
    }

    /// **`CONFIDENCE.NORM` returns a half-width, not an interval.** The value is added to
    /// and subtracted from the mean, so returning the full width would double every
    /// interval built on it.
    @Test func confidenceIsAHalfWidth() throws {
        // z(1 − α/2) · σ/√n. At α = 0.05 the multiplier is 1.959964.
        let half = try n("CONFIDENCE.NORM", .number(0.05), .number(2.5), .number(50))
        #expect(abs(half - (1.959964 * 2.5 / 50.0.squareRoot())) <= 1e-5)
    }

    /// `Z.TEST` returns a **one-tailed** probability: the chance of observing a sample mean
    /// at least this far above `x` if the true mean were `x`.
    @Test func zTestIsOneTailed() throws {
        let sample = row([3, 6, 7, 8, 6, 5, 4, 2, 1, 9])
        // At the sample's own mean the observation is exactly typical, so the one-tailed
        // probability is a half.
        let mean = 5.1
        #expect(try abs(n("Z.TEST", sample, .number(mean)) - 0.5) <= 1e-9)
    }

    // MARK: - The two tests

    /// `CHISQ.TEST(actual, expected)` — the p-value of the chi-squared statistic.
    ///
    /// **Identical arrays mean a statistic of zero**, and a chi-squared statistic of zero
    /// has a right-tail probability of exactly 1: the observation is as consistent with the
    /// expectation as anything could be.
    @Test func chiSquaredTestOnAPerfectFit() throws {
        let observed = row([10, 20, 30, 40])
        #expect(try abs(n("CHISQ.TEST", observed, observed) - 1) <= 1e-12)
    }

    /// And it agrees with the statistic computed by hand, pushed through the tail we
    /// already bound. Degrees of freedom for a single row is `n − 1`.
    @Test func chiSquaredTestMatchesItsStatistic() throws {
        let observed: [Double] = [30, 14, 34, 45, 57, 20]
        let expected: [Double] = [25, 17, 30, 50, 60, 18]

        var statistic = 0.0
        for (o, e) in zip(observed, expected) { statistic += (o - e) * (o - e) / e }
        let byHand = try n("CHISQ.DIST.RT", .number(statistic), .number(Double(observed.count - 1)))

        #expect(try abs(n("CHISQ.TEST", row(observed), row(expected)) - byHand) <= 1e-12)
    }

    /// `F.TEST(array1, array2)` — the **two-tailed** probability that two variances differ.
    ///
    /// Identical samples have a variance ratio of exactly 1, which sits at the centre of
    /// the F distribution, so the two-tailed probability is 1.
    @Test func fTestOnIdenticalSamples() throws {
        let sample = row([6, 7, 9, 15, 21])
        #expect(try abs(n("F.TEST", sample, sample) - 1) <= 1e-9)
    }

    /// The order of the arguments must not change the answer: `F.TEST(a, b)` and
    /// `F.TEST(b, a)` are the same question. A one-tailed implementation would fail this.
    @Test func fTestIsSymmetric() throws {
        let a = row([6, 7, 9, 15, 21])
        let b = row([20, 28, 31, 38, 40])
        #expect(try abs(n("F.TEST", a, b) - n("F.TEST", b, a)) <= 1e-9)
    }

    // MARK: - Domains

    @Test func testDomains() throws {
        let three = row([1, 2, 3])
        // Mismatched lengths cannot be compared cell by cell.
        #expect(try call("CHISQ.TEST", three, row([1, 2])) == .error(.na))
        // An expected frequency of zero divides by zero.
        #expect(try call("CHISQ.TEST", three, row([1, 0, 3])) == .error(.div0))
        // A variance test needs at least two observations in each sample.
        #expect(try call("F.TEST", row([1]), row([1, 2])) == .error(.div0))
    }
}
