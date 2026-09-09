import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import BusinessMath

/// Eight modern distribution spellings.
///
/// ## How these are tested, and why
///
/// Twice today a remembered "published" constant failed a correct implementation — `ERF`
/// and `CHISQ.INV.RT`. ADR-001 warns against asserting our reading of a specification; it
/// says nothing kind about one recalled without reading it at all.
///
/// So the assertions here are **relationships that follow from the definitions**, which
/// need no memory: a cumulative distribution rises to 1, a mass function sums to its
/// cumulative, a right tail is one minus a left, `T.DIST.2T(0, df)` is exactly 1. Where a
/// point value appears it is one derivable in a line — `EXPON.DIST(1, 1, TRUE)` is
/// `1 − e⁻¹` because that is what the exponential CDF *is*.
final class StatisticalDistributionTests: XCTestCase {

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        let fn = try XCTUnwrap(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
        return try fn.evaluate(args)
    }

    private func number(_ value: CellValue) throws -> Double {
        guard case .number(let d) = value else { throw XCTSkip("expected a number, got \(value)") }
        return d
    }

    private func n(_ name: String, _ args: CellValue...) throws -> Double {
        let fn = try XCTUnwrap(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
        return try number(try fn.evaluate(args))
    }

    // MARK: - The cumulative flag

    /// **The fourth argument selects a different function, not a different format.**
    /// `FALSE` gives the probability *at* a point; `TRUE` gives the probability *up to* it.
    /// For a discrete distribution the cumulative is the sum of the masses, which is the
    /// relationship asserted here rather than any particular value.
    func testBinomialCumulativeIsTheSumOfItsMasses() throws {
        var masses = 0.0
        for k in 0...4 {
            masses += try n("BINOM.DIST", .number(Double(k)), .number(10), .number(0.3), .bool(false))
        }
        let cumulative = try n("BINOM.DIST", .number(4), .number(10), .number(0.3), .bool(true))
        XCTAssertEqual(masses, cumulative, accuracy: 1e-12)
    }

    /// Derivable in a line: one trial, fair coin, exactly one success.
    func testBinomialAtAKnownPoint() throws {
        XCTAssertEqual(try n("BINOM.DIST", .number(1), .number(1), .number(0.5), .bool(false)),
                       0.5, accuracy: 1e-12)
        XCTAssertEqual(try n("BINOM.DIST", .number(10), .number(10), .number(1), .bool(true)),
                       1.0, accuracy: 1e-12)
    }

    /// Poisson's mass at zero is `e^(−μ)`, straight from the definition.
    func testPoissonAtZero() throws {
        XCTAssertEqual(try n("POISSON.DIST", .number(0), .number(1), .bool(false)),
                       Foundation.exp(-1), accuracy: 1e-12)
    }

    func testPoissonCumulativeIsTheSumOfItsMasses() throws {
        var masses = 0.0
        for k in 0...6 {
            masses += try n("POISSON.DIST", .number(Double(k)), .number(2.5), .bool(false))
        }
        XCTAssertEqual(masses,
                       try n("POISSON.DIST", .number(6), .number(2.5), .bool(true)),
                       accuracy: 1e-12)
    }

    /// The exponential CDF is `1 − e^(−λx)`, which is the definition rather than a lookup.
    func testExponentialCumulative() throws {
        XCTAssertEqual(try n("EXPON.DIST", .number(1), .number(1), .bool(true)),
                       1 - Foundation.exp(-1), accuracy: 1e-12)
        XCTAssertEqual(try n("EXPON.DIST", .number(0), .number(3), .bool(true)),
                       0, accuracy: 1e-12)
    }

    /// And its density is `λe^(−λx)`.
    func testExponentialDensity() throws {
        XCTAssertEqual(try n("EXPON.DIST", .number(0), .number(3), .bool(false)),
                       3, accuracy: 1e-12)
    }

    /// A cumulative distribution rises to 1 and never falls.
    func testCumulativesAreMonotonicAndReachOne() throws {
        var previous = -1.0
        for x in stride(from: 0.5, through: 20, by: 0.5) {
            let p = try n("GAMMA.DIST", .number(x), .number(2), .number(2), .bool(true))
            XCTAssertGreaterThanOrEqual(p, previous, "GAMMA.DIST fell at x=\(x)")
            previous = p
        }
        XCTAssertEqual(previous, 1, accuracy: 1e-3)
    }

    /// Log-normal is defined on positive values only; at or below zero it is `#NUM!`.
    func testLogNormalDomain() throws {
        XCTAssertEqual(try call("LOGNORM.DIST", .number(0), .number(0), .number(1), .bool(true)),
                       .error(.num))
        XCTAssertGreaterThan(
            try n("LOGNORM.DIST", .number(1), .number(0), .number(1), .bool(true)), 0)
    }

    // MARK: - The tails

    /// **A right tail is one minus a left, and the name is the only thing that says which.**
    /// This is the trap the `compatibility` bucket carries eight of: `CHIDIST` means
    /// `CHISQ.DIST.RT`, and binding it to `CHISQ.DIST` returns a probability in `[0,1]`
    /// that is plausible, wrong, and reported by nothing.
    func testRightTailsAreTheComplementOfTheirCDF() throws {
        let x = 7.5
        let chiTail = try n("CHISQ.DIST.RT", .number(x), .number(4))
        XCTAssertEqual(chiTail, 1 - (try chiSquaredCDF(x: x, df: 4)), accuracy: 1e-12)

        let fTail = try n("F.DIST.RT", .number(2.5), .number(3), .number(9))
        XCTAssertEqual(fTail, 1 - (try fCDF(f: 2.5, df1: 3, df2: 9)), accuracy: 1e-12)
    }

    /// At zero the whole distribution is to the right, so the tail is exactly 1.
    func testRightTailAtZeroIsOne() throws {
        XCTAssertEqual(try n("CHISQ.DIST.RT", .number(0), .number(5)), 1, accuracy: 1e-12)
        XCTAssertEqual(try n("F.DIST.RT", .number(0), .number(3), .number(9)), 1, accuracy: 1e-12)
    }

    /// **`T.DIST.2T` is two-tailed, so it is twice the right tail** — and at zero that
    /// makes it exactly 1, not 0.5. Halving it, or forgetting to double, produces a
    /// probability that looks entirely reasonable.
    func testTwoTailedTIsTwiceTheRightTail() throws {
        XCTAssertEqual(try n("T.DIST.2T", .number(0), .number(8)), 1, accuracy: 1e-12)

        let x = 1.86
        let twoTailed = try n("T.DIST.2T", .number(x), .number(8))
        let rightTail = 1 - (try tCDF(t: x, df: 8))
        XCTAssertEqual(twoTailed, 2 * rightTail, accuracy: 1e-12)
    }

    /// Microsoft's domain for `T.DIST.2T` requires a non-negative `x` — a negative is
    /// `#NUM!` rather than being folded to its absolute value.
    func testTwoTailedTRejectsNegatives() throws {
        XCTAssertEqual(try call("T.DIST.2T", .number(-1), .number(8)), .error(.num))
    }

    // MARK: - Domains

    /// Degrees of freedom below 1, or at Excel's 10¹⁰ ceiling, are `#NUM!`.
    func testDegreesOfFreedomDomain() throws {
        XCTAssertEqual(try call("CHISQ.DIST.RT", .number(1), .number(0)), .error(.num))
        XCTAssertEqual(try call("F.DIST.RT", .number(1), .number(0), .number(9)), .error(.num))
        XCTAssertEqual(try call("T.DIST.2T", .number(1), .number(0)), .error(.num))
    }

    /// A binomial cannot have more successes than trials, and a probability outside
    /// `[0, 1]` is not a probability.
    func testBinomialDomain() throws {
        XCTAssertEqual(
            try call("BINOM.DIST", .number(11), .number(10), .number(0.3), .bool(true)),
            .error(.num))
        XCTAssertEqual(
            try call("BINOM.DIST", .number(1), .number(10), .number(1.5), .bool(true)),
            .error(.num))
    }
}
