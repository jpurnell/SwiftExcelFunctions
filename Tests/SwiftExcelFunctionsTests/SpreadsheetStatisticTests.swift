import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import BusinessMath

/// The twelve remaining spreadsheet statistics.
///
/// Assertions are relationships and hand-computable arithmetic, never a recalled constant —
/// three of those failed correct code today.
final class SpreadsheetStatisticTests: XCTestCase {

    private func fn(_ name: String) throws -> ExcelFunction {
        try XCTUnwrap(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
    }
    private func call(_ name: String, _ a: CellValue...) throws -> CellValue { try fn(name).evaluate(a) }
    private func n(_ name: String, _ a: CellValue...) throws -> Double {
        guard case .number(let d) = try fn(name).evaluate(a) else {
            throw XCTSkip("\(name) did not return a number")
        }
        return d
    }
    private func row(_ v: [Double]) -> CellValue { .array(CellMatrix(row: v.map { .number($0) })) }

    // MARK: - Tails and inverses

    /// `CHISQ.INV` is the **left**-tailed inverse — the complement of `CHISQ.INV.RT`, and
    /// the pair that the legacy `CHIINV` maps to the *right* one of.
    func testChiSquaredInverseIsLeftTailed() throws {
        let left = try n("CHISQ.INV", .number(0.95), .number(10))
        let right = try n("CHISQ.INV.RT", .number(0.05), .number(10))
        XCTAssertEqual(left, right, accuracy: 1e-9,
                       "CHISQ.INV(p) and CHISQ.INV.RT(1−p) are the same point")
    }

    /// `T.DIST.RT` is one tail; `T.DIST.2T` is two. Exactly a factor of two apart.
    func testRightTailedTIsHalfTheTwoTailed() throws {
        let oneTail = try n("T.DIST.RT", .number(1.5), .number(9))
        let twoTail = try n("T.DIST.2T", .number(1.5), .number(9))
        XCTAssertEqual(twoTail, 2 * oneTail, accuracy: 1e-12)
    }

    // MARK: - Position within a sample

    /// `QUARTILE.INC(data, 2)` is the median, and quart 0 and 4 are the extremes.
    func testInclusiveQuartilesSpanTheData() throws {
        let data = row([1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(try n("QUARTILE.INC", data, .number(0)), 1, accuracy: 1e-12)
        XCTAssertEqual(try n("QUARTILE.INC", data, .number(2)), 5, accuracy: 1e-12)
        XCTAssertEqual(try n("QUARTILE.INC", data, .number(4)), 9, accuracy: 1e-12)
    }

    /// **`.EXC` excludes the endpoints, and that is the whole difference.** `QUARTILE.EXC`
    /// of quart 0 has no answer at all — the 0th percentile is outside an exclusive range —
    /// so it is `#NUM!` where `.INC` returns the minimum.
    func testExclusiveQuartilesRejectTheEndpoints() throws {
        let data = row([1, 2, 3, 4, 5, 6, 7, 8, 9])
        XCTAssertEqual(try call("QUARTILE.EXC", data, .number(0)), .error(.num))
        XCTAssertEqual(try call("QUARTILE.EXC", data, .number(4)), .error(.num))
        XCTAssertEqual(try n("QUARTILE.EXC", data, .number(2)), 5, accuracy: 1e-12)
    }

    /// `PERCENTILE.EXC` needs enough data for the requested rank to fall strictly inside:
    /// with `n` values only probabilities in `(1/(n+1), n/(n+1))` are answerable.
    func testExclusivePercentileNeedsRoomInside() throws {
        let data = row([1, 2, 3])
        XCTAssertEqual(try call("PERCENTILE.EXC", data, .number(0.1)), .error(.num))
        XCTAssertEqual(try n("PERCENTILE.EXC", data, .number(0.5)), 2, accuracy: 1e-12)
    }

    /// `PERCENTRANK.INC` is the inverse question: where does a value sit? The minimum
    /// ranks 0 and the maximum 1.
    func testPercentRankSpansZeroToOne() throws {
        let data = row([1, 2, 3, 4, 5])
        XCTAssertEqual(try n("PERCENTRANK.INC", data, .number(1)), 0, accuracy: 1e-9)
        XCTAssertEqual(try n("PERCENTRANK.INC", data, .number(5)), 1, accuracy: 1e-9)
        XCTAssertEqual(try n("PERCENTRANK.INC", data, .number(3)), 0.5, accuracy: 1e-9)
    }

    // MARK: - Dispersion and fit

    /// `AVEDEV` is the mean **absolute** deviation, not the standard one — computed here
    /// from the definition rather than recalled.
    func testAverageDeviation() throws {
        let values: [Double] = [4, 5, 6, 7, 5, 4, 3]
        let average = values.reduce(0, +) / Double(values.count)
        let expected = values.reduce(0) { $0 + abs($1 - average) } / Double(values.count)
        XCTAssertEqual(try n("AVEDEV", row(values)), expected, accuracy: 1e-12)
    }

    /// `TRIMMEAN` discards a **total** fraction split between both ends, and rounds the
    /// count down to a multiple of two so the trimming stays symmetric.
    func testTrimMeanTrimsBothEndsSymmetrically() throws {
        let data = row([1, 2, 3, 4, 5, 6, 7, 8, 9, 100])
        // 20% of 10 values is 2, one from each end: drops 1 and 100.
        let expected = [2.0, 3, 4, 5, 6, 7, 8, 9].reduce(0, +) / 8
        XCTAssertEqual(try n("TRIMMEAN", data, .number(0.2)), expected, accuracy: 1e-12)
    }

    /// At zero trimming it is just the mean.
    func testTrimMeanAtZeroIsTheMean() throws {
        let values: [Double] = [1, 2, 3, 4, 5]
        XCTAssertEqual(try n("TRIMMEAN", row(values), .number(0)), 3, accuracy: 1e-12)
    }

    /// `STEYX` is the standard error of the predicted `y` — zero when the fit is exact,
    /// because there is nothing left to err by.
    func testStandardErrorIsZeroOnAPerfectFit() throws {
        let y = row([2, 4, 6, 8, 10])
        let x = row([1, 2, 3, 4, 5])
        XCTAssertEqual(try n("STEYX", y, x), 0, accuracy: 1e-9)
    }

    func testStandardErrorIsPositiveWhenScattered() throws {
        XCTAssertGreaterThan(try n("STEYX", row([2, 5, 6, 8, 9]), row([1, 2, 3, 4, 5])), 0)
    }

    // MARK: - Probability over a discrete set

    /// `PROB(x_range, prob_range, lower, [upper])` sums the probabilities of outcomes in
    /// the interval. With no upper limit it is the probability of exactly `lower`.
    func testProbabilitySumsOverTheInterval() throws {
        let outcomes = row([0, 1, 2, 3])
        let weights = row([0.2, 0.3, 0.1, 0.4])
        XCTAssertEqual(try n("PROB", outcomes, weights, .number(1)), 0.3, accuracy: 1e-12)
        XCTAssertEqual(try n("PROB", outcomes, weights, .number(1), .number(2)), 0.4, accuracy: 1e-12)
    }

    /// The probabilities must be a distribution: anything not summing to 1 is `#NUM!`.
    func testProbabilitiesMustSumToOne() throws {
        XCTAssertEqual(
            try call("PROB", row([0, 1]), row([0.2, 0.3]), .number(0)), .error(.num))
    }

    // MARK: - Binning

    /// `FREQUENCY` returns **one more value than there are bins** — the last is everything
    /// above the highest bin, which is the element people forget exists.
    func testFrequencyReturnsOneMoreThanItsBins() throws {
        let data = row([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        let bins = row([3, 6])
        guard case .array(let matrix) = try call("FREQUENCY", data, bins) else {
            return XCTFail("FREQUENCY must return an array")
        }
        XCTAssertEqual(matrix.elements.count, 3)
        XCTAssertEqual(matrix.elements, [.number(3), .number(3), .number(4)])
    }

    /// A bin is inclusive of its upper bound: a value exactly on a boundary falls in the
    /// lower bin, not the higher one.
    func testBinBoundariesAreInclusive() throws {
        guard case .array(let matrix) = try call("FREQUENCY", row([3, 3, 4]), row([3])) else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(matrix.elements, [.number(2), .number(1)])
    }

    // MARK: - The two-sample t test

    /// `T.TEST(array1, array2, tails, type)` — identical samples differ by nothing, so a
    /// paired test on them is a probability of exactly 1.
    func testPairedTestOnIdenticalSamples() throws {
        let sample = row([3, 4, 5, 6, 7])
        XCTAssertEqual(try n("T.TEST", sample, sample, .number(2), .number(1)), 1, accuracy: 1e-9)
    }

    /// One tail is half of two, which is the relationship rather than a value.
    func testTailsArgumentHalvesTheAnswer() throws {
        let a = row([3, 4, 5, 6, 7])
        let b = row([5, 6, 8, 9, 11])
        let two = try n("T.TEST", a, b, .number(2), .number(3))
        let one = try n("T.TEST", a, b, .number(1), .number(3))
        XCTAssertEqual(two, 2 * one, accuracy: 1e-9)
    }
}
