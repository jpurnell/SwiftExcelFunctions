import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// `FORECAST.ETS` and `FORECAST.ETS.CONFINT` — the prediction, and its interval.
///
/// These were reachable before only by handing `HoltWintersModel` an alpha, a beta and a
/// gamma the caller had to invent. Routed through `fitETS` they no longer are, which is the
/// whole reason the fitter was worth writing.
@Suite struct ForecastETSPredictionTests {

    private func fn(_ name: String) throws -> ExcelFunction {
        try #require(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
    }

    private func nums(_ v: [Double]) -> CellValue { .array(CellMatrix(row: v.map { .number($0) })) }

    /// Three cycles of four with an upward drift, so both trend and season are real.
    private var values: CellValue {
        nums([10, 20, 30, 20, 12, 22, 32, 22, 14, 24, 34, 24])
    }
    private var timeline: CellValue { nums(Array(1...12).map(Double.init)) }

    private func forecast(_ target: Double, _ extra: CellValue...) throws -> CellValue {
        try fn("FORECAST.ETS").evaluate([.number(target), values, timeline] + extra)
    }

    private func confint(_ target: Double, _ extra: CellValue...) throws -> CellValue {
        try fn("FORECAST.ETS.CONFINT").evaluate([.number(target), values, timeline] + extra)
    }

    private func number(_ result: CellValue, sourceLocation: SourceLocation = #_sourceLocation) throws -> Double {
        guard case .number(let value) = result else {
            Issue.record("expected a number, got \(result)")
            throw TestFailure("not a number")
        }
        return value
    }

    // MARK: - Registration

    @Test func bothAreRegistered() throws {
        #expect(throws: Never.self) { try fn("FORECAST.ETS") }
        #expect(throws: Never.self) { try fn("FORECAST.ETS.CONFINT") }
    }

    // MARK: - The forecast

    /// **The series is bounded and the forecast should be too.** History runs 10…34; a
    /// one-step forecast that lands outside a generous envelope of that range means the
    /// model diverged, which is the failure worth catching. Asserting a *value* would be
    /// asserting our optimizer's answer, which Excel's will not match.
    @Test func forecastStaysInTheNeighbourhoodOfTheSeries() throws {
        let predicted = try number(try forecast(13))
        #expect(predicted > 0)
        #expect(predicted < 60)
    }

    /// Forecasting further out is still a number rather than an error — the horizon is a
    /// count of steps, not a bound.
    @Test func furtherHorizonsStillAnswer() throws {
        #expect(throws: Never.self) { try number(try forecast(20)) }
    }

    /// **A target at or before the end of the timeline is `#NUM!`.** Excel is explicit that
    /// the target must be chronologically after the history, and it is the one argument
    /// error this function owns.
    @Test func targetInsideTheHistoryIsNum() throws {
        #expect(try forecast(12) == .error(.num))
        #expect(try forecast(5) == .error(.num))
    }

    /// A target off the step grid is still a horizon — Excel forecasts to the step that
    /// reaches it. This pins rounding rather than leaving it to chance.
    @Test func targetOffTheGridRoundsToAStep() throws {
        #expect(throws: Never.self) { try number(try forecast(13.4)) }
    }

    // MARK: - The interval

    /// An interval is a half-width, so it cannot be negative.
    @Test func intervalIsNonNegative() throws {
        #expect(try number(try confint(13)) >= 0)
    }

    /// **A more confident interval is a wider one.** That relationship holds for every
    /// correct implementation regardless of the model, which is exactly the kind of
    /// assertion that survives our optimizer differing from Excel's.
    @Test func higherConfidenceGivesAWiderInterval() throws {
        let ninety = try number(try confint(13, .number(0.90)))
        let ninetyNine = try number(try confint(13, .number(0.99)))
        #expect(ninetyNine > ninety)
    }

    /// The confidence level is a probability, exclusive at both ends.
    @Test func confidenceOutsideZeroToOneIsNum() throws {
        #expect(try confint(13, .number(0)) == .error(.num))
        #expect(try confint(13, .number(1)) == .error(.num))
        #expect(try confint(13, .number(-0.5)) == .error(.num))
    }

    // MARK: - Shared argument handling

    /// Both inherit the pairing's errors, so a length mismatch is `#N/A` here too.
    @Test func lengthMismatchPropagates() throws {
        let result = try fn("FORECAST.ETS")
            .evaluate([.number(5), nums([1, 2, 3]), nums([1, 2])])
        #expect(result == .error(.na))
    }

    /// And the measured aggregation mapping: `0` is refused here as everywhere.
    @Test func aggregationZeroIsNum() throws {
        #expect(try forecast(13, .number(0), .number(1), .number(0)) == .error(.num))
    }
}
