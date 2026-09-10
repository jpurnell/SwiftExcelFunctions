import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// `FORECAST.ETS.STAT` and `FORECAST.ETS.SEASONALITY`, through the registry.
///
/// **Almost nothing here asserts a value.** Excel's ETS has its own initialisation and its
/// own optimizer, so a fitted alpha of ours will not equal a fitted alpha of theirs, and a
/// test that demanded one would fail correct code. What is asserted instead is what must be
/// true of any correct implementation: parameters inside their bounds, errors non-negative,
/// SMAPE inside the range its denominator gives it, and the one statistic that *is* exact
/// because no model touches it — the step.
final class ForecastETSBindingTests: XCTestCase {

    private func fn(_ name: String) throws -> ExcelFunction {
        try XCTUnwrap(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
    }

    private func nums(_ v: [Double]) -> CellValue { .array(CellMatrix(row: v.map { .number($0) })) }

    /// Twelve points on a cycle of four, with a gentle upward drift so trend and season are
    /// both real. Three full cycles: `fitETS` requires at least two.
    private var seasonalValues: CellValue {
        nums([10, 20, 30, 20,
              12, 22, 32, 22,
              14, 24, 34, 24])
    }

    private var timeline: CellValue { nums(Array(1...12).map(Double.init)) }

    private func stat(_ type: Int, _ extra: CellValue...) throws -> CellValue {
        try fn("FORECAST.ETS.STAT")
            .evaluate([seasonalValues, timeline, .number(Double(type))] + extra)
    }

    private func statNumber(_ type: Int, _ extra: CellValue..., line: UInt = #line) throws -> Double {
        let result = try fn("FORECAST.ETS.STAT")
            .evaluate([seasonalValues, timeline, .number(Double(type))] + extra)
        guard case .number(let value) = result else {
            XCTFail("type \(type) returned \(result)", line: line)
            throw XCTSkip("not a number")
        }
        return value
    }

    // MARK: - Registration

    func testBothFunctionsAreRegistered() throws {
        XCTAssertNoThrow(try fn("FORECAST.ETS.STAT"))
        XCTAssertNoThrow(try fn("FORECAST.ETS.SEASONALITY"))
    }

    // MARK: - The smoothing parameters, 1–3

    /// Fitted parameters must lie in their bounds. Not *equal* anything — the search is
    /// ours and Excel's is theirs.
    func testSmoothingParametersAreInBounds() throws {
        for type in 1...3 {
            let value = try statNumber(type)
            XCTAssertGreaterThanOrEqual(value, 0, "type \(type)")
            XCTAssertLessThanOrEqual(value, 1, "type \(type)")
        }
    }

    // MARK: - The error metrics, 4–7

    /// Every error metric is a magnitude, so none may be negative.
    func testErrorMetricsAreNonNegative() throws {
        for type in 4...7 {
            XCTAssertGreaterThanOrEqual(try statNumber(type), 0, "type \(type)")
        }
    }

    /// **SMAPE's ceiling is 2, not 1** — measured against Excel, which uses the halved
    /// denominator. A result above 1 is therefore legal here and would be impossible under
    /// the other convention.
    func testSmapeIsWithinTheHalvedRange() throws {
        let smape = try statNumber(5)
        XCTAssertGreaterThanOrEqual(smape, 0)
        XCTAssertLessThanOrEqual(smape, 2)
    }

    /// MAE and RMSE measure the same residuals two ways, and squaring cannot make the
    /// average smaller: `RMSE ≥ MAE` for every possible series. A relationship, not a value.
    func testRootMeanSquareIsAtLeastTheMeanAbsolute() throws {
        XCTAssertGreaterThanOrEqual(try statNumber(7), try statNumber(6) - 1e-12)
    }

    // MARK: - The step, 8

    /// Exact, because no model is involved: the step is read off the timeline.
    func testStepIsExact() throws {
        XCTAssertEqual(try statNumber(8), 1, accuracy: 1e-12)
    }

    /// **Type 8 answers where the others cannot.** A two-point series is far too short to
    /// fit — `fitETS` needs two full cycles — but its step is still perfectly well defined.
    /// Binding type 8 through the fit would turn a good answer into `#NUM!`.
    func testStepAnswersOnASeriesTooShortToFit() throws {
        let result = try fn("FORECAST.ETS.STAT")
            .evaluate([nums([10, 20]), nums([1, 5]), .number(8)])
        XCTAssertEqual(result, .number(4))
    }

    // MARK: - Argument errors

    /// A statistic type outside 1…8 has no answer.
    func testUnknownStatisticTypeIsNum() throws {
        XCTAssertEqual(try stat(0), .error(.num))
        XCTAssertEqual(try stat(9), .error(.num))
    }

    /// The measured aggregation mapping applies here too: `0` is refused.
    func testAggregationZeroIsNum() throws {
        XCTAssertEqual(try stat(6, .number(0), .number(1), .number(0)), .error(.num))
    }

    /// Excel's `seasonality` argument: `0` non-seasonal, `1` detect, `n` explicit, and
    /// anything else `#NUM!`.
    func testNegativeSeasonalityIsNum() throws {
        XCTAssertEqual(try stat(6, .number(-2)), .error(.num))
    }

    /// A length mismatch is `#N/A` here exactly as it is at the pairing.
    func testLengthMismatchPropagates() throws {
        let result = try fn("FORECAST.ETS.STAT")
            .evaluate([nums([1, 2, 3]), nums([1, 2]), .number(8)])
        XCTAssertEqual(result, .error(.na))
    }

    // MARK: - SEASONALITY

    /// The cycle is four and the series says so. This is the one statistic where our answer
    /// and Excel's should agree exactly, because both read a pattern rather than fit one.
    func testSeasonalityFindsTheCycle() throws {
        let result = try fn("FORECAST.ETS.SEASONALITY").evaluate([seasonalValues, timeline])
        XCTAssertEqual(result, .number(4))
    }

    /// A monotone ramp has no repeating pattern, and **Excel answers `0`** — measured, on
    /// exactly this series. Our first reading was `1`, taken from upstream's non-seasonal
    /// cycle length, and it was wrong: "no repeating pattern" and "a pattern that repeats
    /// every period" are different claims, and only the second is a 1.
    func testSeasonalityOnANonSeasonalSeriesIsZero() throws {
        let ramp = nums([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
        let result = try fn("FORECAST.ETS.SEASONALITY").evaluate([ramp, timeline])
        XCTAssertEqual(result, .number(0))
    }
}
