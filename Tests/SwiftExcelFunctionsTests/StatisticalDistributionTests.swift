import Foundation
import Testing
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
@Suite struct StatisticalDistributionTests {

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        let fn = try #require(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
        return try fn.evaluate(args)
    }

    private func number(_ value: CellValue) throws -> Double {
        guard case .number(let d) = value else { throw TestFailure("expected a number, got \(value)") }
        return d
    }

    private func n(_ name: String, _ args: CellValue...) throws -> Double {
        let fn = try #require(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
        return try number(try fn.evaluate(args))
    }

    // MARK: - The cumulative flag

    /// **The fourth argument selects a different function, not a different format.**
    /// `FALSE` gives the probability *at* a point; `TRUE` gives the probability *up to* it.
    /// For a discrete distribution the cumulative is the sum of the masses, which is the
    /// relationship asserted here rather than any particular value.
    @Test func binomialCumulativeIsTheSumOfItsMasses() throws {
        var masses = 0.0
        for k in 0...4 {
            masses += try n("BINOM.DIST", .number(Double(k)), .number(10), .number(0.3), .bool(false))
        }
        let cumulative = try n("BINOM.DIST", .number(4), .number(10), .number(0.3), .bool(true))
        #expect(abs(masses - cumulative) <= 1e-12)
    }

    /// Derivable in a line: one trial, fair coin, exactly one success.
    @Test func binomialAtAKnownPoint() throws {
        #expect(try abs(n("BINOM.DIST", .number(1), .number(1), .number(0.5), .bool(false)) - 0.5) <= 1e-12)
        #expect(try abs(n("BINOM.DIST", .number(10), .number(10), .number(1), .bool(true)) - 1.0) <= 1e-12)
    }

    /// Poisson's mass at zero is `e^(−μ)`, straight from the definition.
    @Test func poissonAtZero() throws {
        #expect(try abs(n("POISSON.DIST", .number(0), .number(1), .bool(false)) - Foundation.exp(-1)) <= 1e-12)
    }

    @Test func poissonCumulativeIsTheSumOfItsMasses() throws {
        var masses = 0.0
        for k in 0...6 {
            masses += try n("POISSON.DIST", .number(Double(k)), .number(2.5), .bool(false))
        }
        #expect(try abs(masses - n("POISSON.DIST", .number(6), .number(2.5), .bool(true))) <= 1e-12)
    }

    /// The exponential CDF is `1 − e^(−λx)`, which is the definition rather than a lookup.
    @Test func exponentialCumulative() throws {
        #expect(try abs(n("EXPON.DIST", .number(1), .number(1), .bool(true)) - (1 - Foundation.exp(-1))) <= 1e-12)
        #expect(try abs(n("EXPON.DIST", .number(0), .number(3), .bool(true)) - 0) <= 1e-12)
    }

    /// And its density is `λe^(−λx)`.
    @Test func exponentialDensity() throws {
        #expect(try abs(n("EXPON.DIST", .number(0), .number(3), .bool(false)) - 3) <= 1e-12)
    }

    /// A cumulative distribution rises to 1 and never falls.
    @Test func cumulativesAreMonotonicAndReachOne() throws {
        var previous = -1.0
        for x in stride(from: 0.5, through: 20, by: 0.5) {
            let p = try n("GAMMA.DIST", .number(x), .number(2), .number(2), .bool(true))
            #expect(p >= previous, "GAMMA.DIST fell at x=\(x)")
            previous = p
        }
        #expect(abs(previous - 1) <= 1e-3)
    }

    /// Log-normal is defined on positive values only; at or below zero it is `#NUM!`.
    @Test func logNormalDomain() throws {
        #expect(try call("LOGNORM.DIST", .number(0), .number(0), .number(1), .bool(true)) == .error(.num))
        #expect(try n("LOGNORM.DIST", .number(1), .number(0), .number(1), .bool(true)) > 0)
    }

    // MARK: - The tails

    /// **A right tail is one minus a left, and the name is the only thing that says which.**
    /// This is the trap the `compatibility` bucket carries eight of: `CHIDIST` means
    /// `CHISQ.DIST.RT`, and binding it to `CHISQ.DIST` returns a probability in `[0,1]`
    /// that is plausible, wrong, and reported by nothing.
    @Test func rightTailsAreTheComplementOfTheirCDF() throws {
        let x = 7.5
        let chiTail = try n("CHISQ.DIST.RT", .number(x), .number(4))
        #expect(abs(chiTail - (1 - (try chiSquaredCDF(x: x, df: 4)))) <= 1e-12)

        let fTail = try n("F.DIST.RT", .number(2.5), .number(3), .number(9))
        #expect(abs(fTail - (1 - (try fCDF(f: 2.5, df1: 3, df2: 9)))) <= 1e-12)
    }

    /// At zero the whole distribution is to the right, so the tail is exactly 1.
    @Test func rightTailAtZeroIsOne() throws {
        #expect(try abs(n("CHISQ.DIST.RT", .number(0), .number(5)) - 1) <= 1e-12)
        #expect(try abs(n("F.DIST.RT", .number(0), .number(3), .number(9)) - 1) <= 1e-12)
    }

    /// **`T.DIST.2T` is two-tailed, so it is twice the right tail** — and at zero that
    /// makes it exactly 1, not 0.5. Halving it, or forgetting to double, produces a
    /// probability that looks entirely reasonable.
    @Test func twoTailedTIsTwiceTheRightTail() throws {
        #expect(try abs(n("T.DIST.2T", .number(0), .number(8)) - 1) <= 1e-12)

        let x = 1.86
        let twoTailed = try n("T.DIST.2T", .number(x), .number(8))
        let rightTail = 1 - (try tCDF(t: x, df: 8))
        #expect(abs(twoTailed - (2 * rightTail)) <= 1e-12)
    }

    /// Microsoft's domain for `T.DIST.2T` requires a non-negative `x` — a negative is
    /// `#NUM!` rather than being folded to its absolute value.
    @Test func twoTailedTRejectsNegatives() throws {
        #expect(try call("T.DIST.2T", .number(-1), .number(8)) == .error(.num))
    }

    // MARK: - Domains

    /// Degrees of freedom below 1, or at Excel's 10¹⁰ ceiling, are `#NUM!`.
    @Test func degreesOfFreedomDomain() throws {
        #expect(try call("CHISQ.DIST.RT", .number(1), .number(0)) == .error(.num))
        #expect(try call("F.DIST.RT", .number(1), .number(0), .number(9)) == .error(.num))
        #expect(try call("T.DIST.2T", .number(1), .number(0)) == .error(.num))
    }

    /// A binomial cannot have more successes than trials, and a probability outside
    /// `[0, 1]` is not a probability.
    @Test func binomialDomain() throws {
        #expect(try call("BINOM.DIST", .number(11), .number(10), .number(0.3), .bool(true)) == .error(.num))
        #expect(try call("BINOM.DIST", .number(1), .number(10), .number(1.5), .bool(true)) == .error(.num))
    }
}
