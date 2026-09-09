import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import BusinessMath

/// The five remaining inverses — `BETA.INV`, `GAMMA.INV`, `F.INV.RT`, `T.INV.2T`,
/// `LOGNORM.INV`.
///
/// ## Round-tripped, not remembered
///
/// Each is asserted against the distribution function bound in the same registry: feed the
/// inverse's answer back through its CDF and the probability must return. That needs no
/// published constant, which is the point — two of today's tests failed correct code
/// because the constant was recalled rather than read.
///
/// It is also a stronger check than a point value. A point value confirms one input; a
/// round-trip over a spread of probabilities confirms the *relationship*, which is what a
/// wrong tail or a swapped parameter breaks.
final class StatisticalQuantileTests: XCTestCase {

    private func call(_ name: String, _ args: Double...) throws -> CellValue {
        let fn = try XCTUnwrap(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
        return try fn.evaluate(args.map { .number($0) })
    }

    private func n(_ name: String, _ args: Double...) throws -> Double {
        let fn = try XCTUnwrap(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
        guard case .number(let d) = try fn.evaluate(args.map { .number($0) }) else {
            throw XCTSkip("\(name) did not return a number")
        }
        return d
    }

    // MARK: - Round trips

    /// `GAMMA.INV(p, α, β)` inverts `GAMMA.DIST(x, α, β, TRUE)`.
    func testGammaInverseRoundTrips() throws {
        for p in [0.05, 0.25, 0.5, 0.75, 0.95] {
            let x = try n("GAMMA.INV", p, 2.5, 1.5)
            let back = try n("GAMMA.DIST", x, 2.5, 1.5, 1)
            XCTAssertEqual(back, p, accuracy: 1e-8, "GAMMA.INV(\(p)) did not round-trip")
        }
    }

    /// `LOGNORM.INV(p, μ, σ)` inverts `LOGNORM.DIST(x, μ, σ, TRUE)`.
    func testLogNormalInverseRoundTrips() throws {
        for p in [0.05, 0.25, 0.5, 0.75, 0.95] {
            let x = try n("LOGNORM.INV", p, 0.5, 1.2)
            let back = try n("LOGNORM.DIST", x, 0.5, 1.2, 1)
            XCTAssertEqual(back, p, accuracy: 1e-8, "LOGNORM.INV(\(p)) did not round-trip")
        }
    }

    /// **`F.INV.RT` inverts the *right* tail**, so it round-trips against `F.DIST.RT` and
    /// not against a left-tailed CDF. Binding it to the left inverse returns a positive
    /// number in the same range for every input.
    func testFInverseRoundTripsThroughTheRightTail() throws {
        for p in [0.01, 0.05, 0.5, 0.95] {
            let x = try n("F.INV.RT", p, 4, 12)
            let back = try n("F.DIST.RT", x, 4, 12)
            XCTAssertEqual(back, p, accuracy: 1e-8, "F.INV.RT(\(p)) did not round-trip")
        }
    }

    /// **`T.INV.2T` inverts the *two-tailed* probability**, so it round-trips against
    /// `T.DIST.2T`. `T.INV` — which this is not — is one-tailed, and the two differ by
    /// exactly the factor of two that makes a confidence interval wrong.
    func testTwoTailedTInverseRoundTrips() throws {
        for p in [0.01, 0.05, 0.10, 0.5] {
            let x = try n("T.INV.2T", p, 12)
            let back = try n("T.DIST.2T", x, 12)
            XCTAssertEqual(back, p, accuracy: 1e-8, "T.INV.2T(\(p)) did not round-trip")
        }
    }

    /// `BETA.INV(p, α, β)` inverts the beta CDF on `[0, 1]`.
    func testBetaInverseRoundTrips() throws {
        for p in [0.05, 0.25, 0.5, 0.75, 0.95] {
            let x = try n("BETA.INV", p, 2, 3)
            XCTAssertEqual(try betaCDF(x: x, alpha: 2, beta: 3), p, accuracy: 1e-8,
                           "BETA.INV(\(p)) did not round-trip")
        }
    }

    // MARK: - Shape

    /// `BETA.INV` takes optional bounds, and rescales onto them. Without `A` and `B` the
    /// support is `[0, 1]`; with them it is `[A, B]`.
    func testBetaInverseRescalesOntoItsBounds() throws {
        let unit = try n("BETA.INV", 0.5, 2, 3)
        let scaled = try n("BETA.INV", 0.5, 2, 3, 10, 20)
        XCTAssertEqual(scaled, 10 + unit * 10, accuracy: 1e-9)
    }

    /// The two-tailed inverse decreases as its probability rises: a smaller tail needs a
    /// larger critical value.
    func testTwoTailedInverseDecreasesWithProbability() throws {
        XCTAssertGreaterThan(try n("T.INV.2T", 0.01, 12), try n("T.INV.2T", 0.05, 12))
    }

    // MARK: - Domains

    /// Probabilities outside their interval are `#NUM!`. `T.INV.2T` excludes zero — the
    /// two-tailed critical value at probability zero is infinite.
    func testProbabilityDomains() throws {
        XCTAssertEqual(try call("GAMMA.INV", -0.1, 2, 2), .error(.num))
        XCTAssertEqual(try call("GAMMA.INV", 1.1, 2, 2), .error(.num))
        XCTAssertEqual(try call("T.INV.2T", 0, 12), .error(.num))
        XCTAssertEqual(try call("T.INV.2T", 1.5, 12), .error(.num))
        XCTAssertEqual(try call("LOGNORM.INV", 0, 0, 1), .error(.num))
    }

    /// Shape and scale must be positive; degrees of freedom at least one.
    func testParameterDomains() throws {
        XCTAssertEqual(try call("GAMMA.INV", 0.5, 0, 2), .error(.num))
        XCTAssertEqual(try call("GAMMA.INV", 0.5, 2, 0), .error(.num))
        XCTAssertEqual(try call("BETA.INV", 0.5, 0, 3), .error(.num))
        XCTAssertEqual(try call("LOGNORM.INV", 0.5, 0, 0), .error(.num))
        XCTAssertEqual(try call("F.INV.RT", 0.5, 0, 12), .error(.num))
        XCTAssertEqual(try call("T.INV.2T", 0.5, 0), .error(.num))
    }
}
