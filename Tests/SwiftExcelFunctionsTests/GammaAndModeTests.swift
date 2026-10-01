import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore
import BusinessMath

/// The remaining tractable statistics — the gamma pair, the normal helpers, the modes, and
/// two counting functions.
@Suite struct GammaAndModeTests {

    private func fn(_ name: String) throws -> ExcelFunction {
        try #require(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
    }
    private func call(_ name: String, _ a: CellValue...) throws -> CellValue { try fn(name).evaluate(a) }
    private func n(_ name: String, _ a: CellValue...) throws -> Double {
        guard case .number(let d) = try fn(name).evaluate(a) else {
            throw TestFailure("\(name) did not return a number")
        }
        return d
    }
    private func row(_ v: [Double]) -> CellValue { .array(CellMatrix(row: v.map { .number($0) })) }

    // MARK: - Gamma

    /// **Γ extends the factorial**, and `Γ(n) = (n−1)!` is the relationship that says so —
    /// asserted rather than a table of values.
    @Test func gammaExtendsTheFactorial() throws {
        #expect(try abs(n("GAMMA", .number(1)) - 1) <= 1e-12)      // 0!
        #expect(try abs(n("GAMMA", .number(5)) - 24) <= 1e-9)      // 4!
        #expect(try abs(n("GAMMA", .number(6)) - 120) <= 1e-9)     // 5!
    }

    /// `Γ(½)` is `√π`, the one non-integer value worth pinning because it is exact.
    @Test func gammaAtAHalf() throws {
        #expect(try abs(n("GAMMA", .number(0.5)) - Double.pi.squareRoot()) <= 1e-12)
    }

    /// Γ has poles at zero and every negative integer, where Excel answers `#NUM!` rather
    /// than an infinity a later cell would carry into a sum.
    @Test func gammaPoles() throws {
        #expect(try call("GAMMA", .number(0)) == .error(.num))
        #expect(try call("GAMMA", .number(-1)) == .error(.num))
        #expect(try call("GAMMA", .number(-4)) == .error(.num))
        // A *non-integer* negative is defined, and negative.
        #expect(try n("GAMMA", .number(-0.5)) < 0)
    }

    /// `GAMMALN.PRECISE(x)` is `ln(Γ(x))`, which is the relationship rather than a value —
    /// and it exists precisely where Γ itself overflows.
    @Test func gammaLogarithmMatchesTheLogOfGamma() throws {
        for x in [0.5, 1.0, 2.5, 7.0] {
            #expect(try abs(n("GAMMALN.PRECISE", .number(x)) - Foundation.log(try n("GAMMA", .number(x)))) <= 1e-9)
        }
        // Γ(200) overflows a Double; its logarithm does not.
        #expect(try n("GAMMALN.PRECISE", .number(200)).isFinite)
    }

    @Test func gammaLogarithmDomain() throws {
        #expect(try call("GAMMALN.PRECISE", .number(0)) == .error(.num))
        #expect(try call("GAMMALN.PRECISE", .number(-1)) == .error(.num))
    }

    // MARK: - The normal helpers

    /// **`GAUSS(z)` is `Φ(z) − ½`** — the area between the mean and `z`, not the whole
    /// left tail. At zero it is 0, where the CDF is 0.5.
    @Test func gaussIsTheAreaFromTheMean() throws {
        #expect(try abs(n("GAUSS", .number(0)) - 0) <= 1e-12)
        let z = 1.5
        #expect(try abs(n("GAUSS", .number(z)) - (normalCDF(x: z) - 0.5)) <= 1e-12)
        // Symmetric about zero.
        #expect(try abs(n("GAUSS", .number(-z)) - -(try n("GAUSS", .number(z)))) <= 1e-12)
    }

    /// `PHI(x)` is the standard normal **density**, `e^(−x²/2)/√(2π)`.
    @Test func phiIsTheDensity() throws {
        #expect(try abs(n("PHI", .number(0)) - (1 / (2 * Double.pi).squareRoot())) <= 1e-12)
        let x = 1.2
        #expect(try abs(n("PHI", .number(x)) - (Foundation.exp(-x * x / 2) / (2 * Double.pi).squareRoot())) <= 1e-12)
    }

    // MARK: - Counting

    /// `PERMUTATIONA(n, k)` counts arrangements **with** repetition, so it is `n^k` — where
    /// `PERMUT` counts without and is the falling factorial. The two differ from `k = 2`.
    @Test func permutationsWithRepetition() throws {
        #expect(try abs(n("PERMUTATIONA", .number(3), .number(2)) - 9) <= 1e-12)
        #expect(try abs(n("PERMUTATIONA", .number(2), .number(3)) - 8) <= 1e-12)
        #expect(try abs(n("PERMUTATIONA", .number(5), .number(0)) - 1) <= 1e-12)
    }

    /// `BINOM.DIST.RANGE(trials, p, s, [s2])` sums the mass over an inclusive range, so
    /// summing the whole support gives exactly 1.
    @Test func binomialRangeOverTheWholeSupport() throws {
        #expect(try abs(n("BINOM.DIST.RANGE", .number(10), .number(0.3), .number(0), .number(10)) - 1) <= 1e-12)
    }

    /// With no upper bound it is a single mass, which must equal `BINOM.DIST` at that point.
    @Test func binomialRangeAtOnePointIsItsMass() throws {
        #expect(try abs(n("BINOM.DIST.RANGE", .number(10), .number(0.3), .number(4)) - n("BINOM.DIST", .number(4), .number(10), .number(0.3), .bool(false))) <= 1e-12)
    }

    // MARK: - Modes

    /// `MODE.SNGL` is the most frequent value, and the **first** one when several tie —
    /// which is why it is the "single" spelling.
    @Test func singleModeTakesTheFirstOnATie() throws {
        #expect(try abs(n("MODE.SNGL", row([3, 7, 7, 3, 9])) - 3) <= 1e-12)
        #expect(try abs(n("MODE.SNGL", row([5, 5, 2, 2, 2])) - 2) <= 1e-12)
    }

    /// **No value repeating is `#N/A`, not zero.** A set with no mode has no answer, and
    /// zero is a value the data might legitimately contain.
    @Test func noModeIsNotAvailable() throws {
        #expect(try call("MODE.SNGL", row([1, 2, 3, 4])) == .error(.na))
        #expect(try call("MODE.MULT", row([1, 2, 3, 4])) == .error(.na))
    }

    /// `MODE.MULT` returns **every** tied mode, in the order they first appear.
    @Test func multipleModesAreAllReturned() throws {
        guard case .array(let matrix) = try call("MODE.MULT", row([3, 7, 7, 3, 9])) else {
            Issue.record("MODE.MULT must return an array"); return
        }
        #expect(matrix.elements == [.number(3), .number(7)])
    }

    // MARK: - Exclusive percent rank

    /// `PERCENTRANK.EXC` uses the `1/(n+1)` convention, so neither endpoint reaches 0 or 1
    /// — the difference from `.INC`, and the same one `QUARTILE.EXC` carries.
    @Test func exclusivePercentRankNeverReachesTheEndpoints() throws {
        let data = row([1, 2, 3, 4])
        let lowest = try n("PERCENTRANK.EXC", data, .number(1))
        let highest = try n("PERCENTRANK.EXC", data, .number(4))
        #expect(lowest > 0)
        #expect(highest < 1)
        #expect(abs(lowest - 0.2) <= 1e-9)   // 1/(4+1)
        #expect(abs(highest - 0.8) <= 1e-9)  // 4/(4+1)
    }
}
