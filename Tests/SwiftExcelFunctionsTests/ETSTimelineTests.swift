import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// Reading the step out of a `FORECAST.ETS*` timeline.
///
/// The step is `FORECAST.ETS.STAT`'s statistic type 8 on its own, and it is where both of
/// Excel's timeline errors are decided — `#NUM!` when no constant step can be identified,
/// `#VALUE!` for duplicates. Neither ever reaches a forecasting model, which is why this
/// is tested against the timeline alone rather than through a fitted series.
///
/// **A gap is not an inconsistent step.** Excel documents support for up to 30% missing
/// points, so `1, 2, 4, 5` is a step of 1 with one point absent — not a series of steps
/// 1, 2, 1. That distinction is the whole of the detection: the step is the interval the
/// timeline is *on*, and every observation must land on it.
final class ETSTimelineTests: XCTestCase {

    private func step(_ timeline: [Double]) -> ETSResult<Double> {
        ETSTimeline.step(of: timeline)
    }

    private func stepValue(_ timeline: [Double], line: UInt = #line) throws -> Double {
        switch step(timeline) {
        case .success(let value):
            return value
        case .failure(let error):
            XCTFail("expected a step, got \(error)", line: line)
            throw XCTSkip("no step")
        }
    }

    private func stepError(_ timeline: [Double], line: UInt = #line) throws -> ExcelError {
        switch step(timeline) {
        case .success(let value):
            XCTFail("expected an error, got step \(value)", line: line)
            throw XCTSkip("no error")
        case .failure(let error):
            return error
        }
    }

    // MARK: - The step itself

    func testUnitStep() throws {
        XCTAssertEqual(try stepValue([1, 2, 3, 4, 5]), 1, accuracy: 1e-12)
    }

    /// Weekly dates as serial numbers, which is how a real timeline arrives.
    func testWeeklyStep() throws {
        XCTAssertEqual(try stepValue([44927, 44934, 44941, 44948]), 7, accuracy: 1e-12)
    }

    /// A fractional step is a step. Nothing here requires whole numbers.
    func testFractionalStep() throws {
        XCTAssertEqual(try stepValue([0, 0.25, 0.5, 0.75]), 0.25, accuracy: 1e-12)
    }

    /// **Sorting is implicit.** Excel documents that the timeline need not arrive sorted,
    /// and it sorts for its own calculations — so a descending timeline has the same step
    /// as the ascending one, not a negative step.
    func testUnsortedTimelineIsSortedFirst() throws {
        XCTAssertEqual(try stepValue([5, 1, 3, 2, 4]), 1, accuracy: 1e-12)
        XCTAssertEqual(try stepValue([4, 3, 2, 1]), 1, accuracy: 1e-12)
    }

    // MARK: - Gaps are not inconsistencies

    /// One missing point. The step is still 1; `3` is simply absent.
    func testSingleGapKeepsTheStep() throws {
        XCTAssertEqual(try stepValue([1, 2, 4, 5]), 1, accuracy: 1e-12)
    }

    /// Several gaps on a coarser step. The intervals are 2, 4, 2 and 6 — the timeline is
    /// on 2s, and the 4 and the 6 are one and two missing points respectively.
    func testGapsOnACoarserStep() throws {
        XCTAssertEqual(try stepValue([10, 12, 16, 18, 24]), 2, accuracy: 1e-12)
    }

    /// A gap at the start of the series is not visible at all — the timeline begins where
    /// it begins. This is here to record that the step is read from the intervals present,
    /// not from any assumption about where the series ought to have started.
    func testLeadingGapIsInvisible() throws {
        XCTAssertEqual(try stepValue([100, 101, 102]), 1, accuracy: 1e-12)
    }

    // MARK: - `#NUM!` — no constant step

    /// **The step is the smallest interval observed, not their greatest common divisor.**
    ///
    /// That distinction decides this test and is worth stating, because the alternative is
    /// nearly vacuous: any set of rational intervals has *some* common divisor, so a
    /// detector that looked for one would accept almost every timeline and report a step
    /// finer than anything present. `1, 2, 3.5` gives intervals of 1 and 1.5, whose common
    /// divisor is 0.5 — a value the timeline never exhibits. Under the smallest-interval
    /// rule the step is 1, and 1.5 is not a whole multiple of it, so there is no consistent
    /// step and the answer is `#NUM!`.
    func testInconsistentStepIsNum() throws {
        XCTAssertEqual(try stepError([1, 2, 3.5]), .num)
    }

    /// Irrational spacing, which no step divides.
    func testUnrelatedIntervalsAreNum() throws {
        XCTAssertEqual(try stepError([0, 1, 1 + Double.pi]), .num)
    }

    /// **A single point has no interval**, so there is nothing to read a step from.
    func testSinglePointIsNum() throws {
        XCTAssertEqual(try stepError([1]), .num)
    }

    func testEmptyTimelineIsNum() throws {
        XCTAssertEqual(try stepError([]), .num)
    }

    /// Non-finite entries cannot be ordered or subtracted meaningfully.
    func testNonFiniteIsNum() throws {
        XCTAssertEqual(try stepError([1, 2, Double.nan]), .num)
        XCTAssertEqual(try stepError([1, 2, Double.infinity]), .num)
    }

    // MARK: - `#VALUE!` — duplicates

    /// **Duplicates are `#VALUE!`, and they are decided before the step is.** A repeated
    /// timestamp gives an interval of zero, which would otherwise reduce every multiple to
    /// nonsense — so it is reported as the duplicate it is rather than as an inconsistent
    /// step.
    ///
    /// **Excel itself never reaches this branch**, and that is now measured rather than
    /// assumed: `FORECAST.ETS*` aggregates duplicate timestamps, so
    /// ``ETSArguments/paired(values:timeline:aggregation:)`` combines them before the step
    /// is read. What remains here is the contract of `step(of:)` called directly — a
    /// timeline still holding duplicates cannot yield a step, and saying so is better than
    /// returning a zero interval's worth of nonsense.
    func testDuplicateTimestampIsValue() throws {
        XCTAssertEqual(try stepError([1, 2, 2, 3]), .value)
    }

    /// A duplicate that only becomes adjacent after sorting is still a duplicate.
    func testDuplicateFoundAfterSorting() throws {
        XCTAssertEqual(try stepError([3, 1, 2, 1]), .value)
    }

    /// Every entry identical: a duplicate, not an empty timeline.
    func testAllIdenticalIsValue() throws {
        XCTAssertEqual(try stepError([5, 5, 5]), .value)
    }

    // MARK: - Tolerance

    /// Dates arrive as serial numbers with fractional parts, and arithmetic on them does
    /// not land exactly. A step detector that demanded exact equality would reject a
    /// perfectly ordinary monthly timeline, so the comparison is relative to the step.
    func testFloatingPointDriftIsTolerated() throws {
        let base = 44927.0
        let timeline = (0..<6).map { base + Double($0) * 30.0 + Double($0) * 1e-10 }
        XCTAssertEqual(try stepValue(timeline), 30, accuracy: 1e-6)
    }

    /// Drift large enough to be a real inconsistency is still rejected — the tolerance is
    /// for representation error, not for a timeline that is genuinely uneven.
    func testRealInconsistencyIsNotToleratedAsDrift() throws {
        XCTAssertEqual(try stepError([0, 30, 60, 95]), .num)
    }
}
