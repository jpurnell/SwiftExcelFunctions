import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// The four `PsiForecast*` functions.
///
/// ## What is checkable
///
/// A forecast of a perfectly linear series is arithmetic: `[2, 4, 6, 8, 10]` continues at 12
/// and 14, and any method that claims to follow a trend has to say so. That makes the trend
/// methods verifiable without a reference value — and the **flat** methods verifiable too, by
/// the same series, since they must *fail* to follow it.
///
/// That contrast is the point of the suite: a moving average and Holt's method differ only in
/// whether the forecast moves with the horizon, and on a trending series that difference is
/// the whole answer.
final class RiskSolverForecastTests: XCTestCase {

    private struct NoCells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
    }
    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func call(_ name: String, _ arguments: [CellValue]) throws -> CellValue {
        let fn = try XCTUnwrap(FunctionRegistry.builtin.function(named: name))
        return try fn.evaluate(arguments)
    }

    private func number(_ name: String, _ arguments: [CellValue]) throws -> Double {
        let answer = try call(name, arguments)
        guard case .number(let d) = answer else {
            XCTFail("\(name) gave \(answer)"); return .nan
        }
        return d
    }

    /// `[2, 4, 6, 8, 10]` — a clean trend of 2 per period.
    private static let trending = CellValue.array(
        CellMatrix(row: (1...5).map { CellValue.number(Double($0) * 2) }))
    /// A series with no trend at all.
    private static let flat = CellValue.array(
        CellMatrix(row: [7, 7, 7, 7, 7].map(CellValue.number)))

    // MARK: - Linear, the binding

    /// The one that binds upstream: `LinearTrend` fits and projects.
    func testLinearFollowsAPerfectTrend() throws {
        XCTAssertEqual(try number("PSIFORECASTLINEAR", [Self.trending]), 12, accuracy: 1e-9)
        XCTAssertEqual(try number("PSIFORECASTLINEAR", [Self.trending, .number(2)]), 14,
                       accuracy: 1e-9)
        XCTAssertEqual(try number("PSIFORECASTLINEAR", [Self.trending, .number(5)]), 20,
                       accuracy: 1e-9)
    }

    /// A flat series forecasts flat, at its own level.
    func testLinearOnAFlatSeries() throws {
        XCTAssertEqual(try number("PSIFORECASTLINEAR", [Self.flat]), 7, accuracy: 1e-9)
    }

    // MARK: - The flat methods

    /// **A moving average holds no trend**, so every horizon is the same number.
    ///
    /// On `[2,4,6,8,10]` with a window of 3 it forecasts the mean of the last three — 8 —
    /// and goes on forecasting 8 however far out it is asked. That is the method, not a
    /// shortcoming, and it is why the answer sits *below* the series' own next value.
    func testTheMovingAverageIsFlatAndBehindATrend() throws {
        let three = try number("PSIFORECASTMOVINGAVG", [Self.trending, .number(3)])
        XCTAssertEqual(three, 8, accuracy: 1e-9)
        XCTAssertEqual(try number("PSIFORECASTMOVINGAVG",
                                  [Self.trending, .number(3), .number(5)]), three,
                       accuracy: 1e-12, "the horizon cannot move a flat forecast")
        XCTAssertLessThan(three, 12, "a moving average lags a rising series")
    }

    /// The window must exist within the data.
    func testTheWindowIsBounded() throws {
        XCTAssertEqual(try call("PSIFORECASTMOVINGAVG", [Self.trending, .number(0)]),
                       .error(.num))
        XCTAssertEqual(try call("PSIFORECASTMOVINGAVG", [Self.trending, .number(9)]),
                       .error(.num), "a window longer than the history has no mean")
    }

    /// Simple exponential smoothing is also flat, and `alpha` says how much it forgets.
    ///
    /// At `alpha = 1` it keeps only the newest observation, so the forecast is the last
    /// value exactly — the easiest point at which to check the recursion is the right way
    /// round, since a reversed one would answer the *first* value here.
    func testExponentialSmoothingAtItsExtremes() throws {
        XCTAssertEqual(try number("PSIFORECASTEXP", [Self.trending, .number(1)]), 10,
                       accuracy: 1e-9)
        // Small alpha barely moves off the first observation.
        XCTAssertLessThan(try number("PSIFORECASTEXP", [Self.trending, .number(0.01)]), 4)
        // And it is flat: the horizon changes nothing.
        let one = try number("PSIFORECASTEXP", [Self.trending, .number(0.5)])
        XCTAssertEqual(try number("PSIFORECASTEXP", [Self.trending, .number(0.5), .number(4)]),
                       one, accuracy: 1e-12)
    }

    /// `alpha` outside `(0, 1]` is not a smoothing weight.
    func testTheSmoothingWeightIsBounded() throws {
        XCTAssertEqual(try call("PSIFORECASTEXP", [Self.trending, .number(0)]), .error(.num))
        XCTAssertEqual(try call("PSIFORECASTEXP", [Self.trending, .number(1.5)]), .error(.num))
    }

    // MARK: - Holt, the one that moves

    /// **Holt's method keeps a trend, so the forecast moves with the horizon.**
    ///
    /// The difference from the two above, and the reason it could not be routed through a
    /// smoother: a smoother returns levels and discards the trend component the forecast
    /// needs. On a perfect trend it recovers it, so this lands on the series' continuation.
    func testHoltFollowsATrendAndMovesWithTheHorizon() throws {
        let one = try number("PSIFORECASTDOUBLEEXP",
                             [Self.trending, .number(0.5), .number(0.5)])
        let three = try number("PSIFORECASTDOUBLEEXP",
                               [Self.trending, .number(0.5), .number(0.5), .number(3)])
        XCTAssertEqual(one, 12, accuracy: 1e-6)
        XCTAssertEqual(three, 16, accuracy: 1e-6)
        XCTAssertGreaterThan(three, one, "a trending forecast must move with the horizon")
    }

    /// The trend starts at the first difference, which needs two observations.
    ///
    /// One is refused rather than started at zero — a zero trend would quietly make this the
    /// simple method under the double method's name.
    func testHoltNeedsTwoObservations() throws {
        let single = CellValue.array(CellMatrix(row: [CellValue.number(5)]))
        XCTAssertEqual(try call("PSIFORECASTDOUBLEEXP",
                                [single, .number(0.5), .number(0.5)]), .error(.num))
    }

    // MARK: - Shared

    /// Empty history is refused by all four.
    func testAnEmptyHistoryIsRefused() throws {
        let empty = CellValue.array(CellMatrix(row: []))
        XCTAssertEqual(try call("PSIFORECASTLINEAR", [empty]), .error(.value))
        XCTAssertEqual(try call("PSIFORECASTMOVINGAVG", [empty, .number(2)]), .error(.value))
        XCTAssertEqual(try call("PSIFORECASTEXP", [empty, .number(0.5)]), .error(.value))
        XCTAssertEqual(try call("PSIFORECASTDOUBLEEXP",
                                [empty, .number(0.5), .number(0.5)]), .error(.value))
    }

    /// A horizon below one is not a forecast.
    func testTheHorizonMustBeAhead() throws {
        XCTAssertEqual(try call("PSIFORECASTLINEAR", [Self.trending, .number(0)]),
                       .error(.value))
    }
}
