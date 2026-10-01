import Foundation
import Testing
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
@Suite struct ETSTimelineTests {

    private func step(_ timeline: [Double]) -> ETSResult<Double> {
        ETSTimeline.step(of: timeline)
    }

    private func stepValue(_ timeline: [Double], sourceLocation: SourceLocation = #_sourceLocation) throws -> Double {
        switch step(timeline) {
        case .success(let value):
            return value
        case .failure(let error):
            Issue.record("expected a step, got \(error)")
            throw TestFailure("no step")
        }
    }

    private func stepError(_ timeline: [Double], sourceLocation: SourceLocation = #_sourceLocation) throws -> ExcelError {
        switch step(timeline) {
        case .success(let value):
            Issue.record("expected an error, got step \(value)")
            throw TestFailure("no error")
        case .failure(let error):
            return error
        }
    }

    // MARK: - The step itself

    @Test func unitStep() throws {
        #expect(try abs(stepValue([1, 2, 3, 4, 5]) - 1) <= 1e-12)
    }

    /// Weekly dates as serial numbers, which is how a real timeline arrives.
    @Test func weeklyStep() throws {
        #expect(try abs(stepValue([44927, 44934, 44941, 44948]) - 7) <= 1e-12)
    }

    /// A fractional step is a step. Nothing here requires whole numbers.
    @Test func fractionalStep() throws {
        #expect(try abs(stepValue([0, 0.25, 0.5, 0.75]) - 0.25) <= 1e-12)
    }

    /// **Sorting is implicit.** Excel documents that the timeline need not arrive sorted,
    /// and it sorts for its own calculations — so a descending timeline has the same step
    /// as the ascending one, not a negative step.
    @Test func unsortedTimelineIsSortedFirst() throws {
        #expect(try abs(stepValue([5, 1, 3, 2, 4]) - 1) <= 1e-12)
        #expect(try abs(stepValue([4, 3, 2, 1]) - 1) <= 1e-12)
    }

    // MARK: - Gaps are not inconsistencies

    /// One missing point. The step is still 1; `3` is simply absent.
    @Test func singleGapKeepsTheStep() throws {
        #expect(try abs(stepValue([1, 2, 4, 5]) - 1) <= 1e-12)
    }

    /// Several gaps on a coarser step. The intervals are 2, 4, 2 and 6 — the timeline is
    /// on 2s, and the 4 and the 6 are one and two missing points respectively.
    @Test func gapsOnACoarserStep() throws {
        #expect(try abs(stepValue([10, 12, 16, 18, 24]) - 2) <= 1e-12)
    }

    /// A gap at the start of the series is not visible at all — the timeline begins where
    /// it begins. This is here to record that the step is read from the intervals present,
    /// not from any assumption about where the series ought to have started.
    @Test func leadingGapIsInvisible() throws {
        #expect(try abs(stepValue([100, 101, 102]) - 1) <= 1e-12)
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
    @Test func inconsistentStepIsNum() throws {
        #expect(try stepError([1, 2, 3.5]) == .num)
    }

    /// Irrational spacing, which no step divides.
    @Test func unrelatedIntervalsAreNum() throws {
        #expect(try stepError([0, 1, 1 + Double.pi]) == .num)
    }

    /// **A single point has no interval**, so there is nothing to read a step from.
    @Test func singlePointIsNum() throws {
        #expect(try stepError([1]) == .num)
    }

    @Test func emptyTimelineIsNum() throws {
        #expect(try stepError([]) == .num)
    }

    /// Non-finite entries cannot be ordered or subtracted meaningfully.
    @Test func nonFiniteIsNum() throws {
        #expect(try stepError([1, 2, Double.nan]) == .num)
        #expect(try stepError([1, 2, Double.infinity]) == .num)
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
    @Test func duplicateTimestampIsValue() throws {
        #expect(try stepError([1, 2, 2, 3]) == .value)
    }

    /// A duplicate that only becomes adjacent after sorting is still a duplicate.
    @Test func duplicateFoundAfterSorting() throws {
        #expect(try stepError([3, 1, 2, 1]) == .value)
    }

    /// Every entry identical: a duplicate, not an empty timeline.
    @Test func allIdenticalIsValue() throws {
        #expect(try stepError([5, 5, 5]) == .value)
    }

    // MARK: - Tolerance

    /// Dates arrive as serial numbers with fractional parts, and arithmetic on them does
    /// not land exactly. A step detector that demanded exact equality would reject a
    /// perfectly ordinary monthly timeline, so the comparison is relative to the step.
    @Test func floatingPointDriftIsTolerated() throws {
        let base = 44927.0
        let timeline = (0..<6).map { base + Double($0) * 30.0 + Double($0) * 1e-10 }
        #expect(try abs(stepValue(timeline) - 30) <= 1e-6)
    }

    /// Drift large enough to be a real inconsistency is still rejected — the tolerance is
    /// for representation error, not for a timeline that is genuinely uneven.
    @Test func realInconsistencyIsNotToleratedAsDrift() throws {
        #expect(try stepError([0, 30, 60, 95]) == .num)
    }
}
