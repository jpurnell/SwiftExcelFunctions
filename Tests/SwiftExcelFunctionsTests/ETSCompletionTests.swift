import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// `data_completion` — putting a series back onto its own step grid.
///
/// Excel documents two treatments: `0` reads a missing point as zero, `1` (the default)
/// completes it "to be the average of the neighboring points". Both are decided here, not
/// upstream: a forecaster wants a series with no holes in it, and which value fills a hole
/// is a spreadsheet argument rather than a modelling choice.
///
/// **Two kinds of hole arrive by different routes and are treated the same.** A timestamp
/// absent from the timeline is a gap; a blank cell against a present timestamp is a missing
/// observation. Both are points on the grid with no value, and Excel's two words for the
/// argument — "missing points" — cover both.
final class ETSCompletionTests: XCTestCase {

    private func nums(_ v: [Double]) -> CellValue { .array(CellMatrix(row: v.map { .number($0) })) }

    private func cells(_ v: [Double?]) -> CellValue {
        .array(CellMatrix(row: v.map { $0.map { CellValue.number($0) } ?? .blank }))
    }

    private func complete(
        values: CellValue,
        timeline: CellValue,
        _ completion: ETSArguments.DataCompletion,
        line: UInt = #line
    ) throws -> ETSArguments.Completed {
        guard case .success(let pair) = ETSArguments.paired(values: values, timeline: timeline) else {
            XCTFail("pairing failed", line: line)
            throw XCTSkip("no pair")
        }
        switch ETSArguments.completed(pair, using: completion) {
        case .success(let completed):
            return completed
        case .failure(let error):
            XCTFail("expected a completed series, got \(error)", line: line)
            throw XCTSkip("no series")
        }
    }

    // MARK: - Nothing missing

    /// A series already on its grid is returned unchanged, and says so.
    func testCompleteSeriesIsUntouched() throws {
        let done = try complete(values: nums([10, 20, 30]), timeline: nums([1, 2, 3]),
                                .neighbourAverage)
        XCTAssertEqual(done.timeline, [1, 2, 3])
        XCTAssertEqual(done.values, [10, 20, 30])
        XCTAssertEqual(done.filledCount, 0)
    }

    // MARK: - A gap in the timeline

    /// `1, 2, 4, 5` is a step of 1 with `3` absent. The grid restores it.
    func testTimelineGapIsFilledWithTheNeighbourAverage() throws {
        let done = try complete(values: nums([10, 20, 40, 50]), timeline: nums([1, 2, 4, 5]),
                                .neighbourAverage)
        XCTAssertEqual(done.timeline, [1, 2, 3, 4, 5])
        XCTAssertEqual(done.values, [10, 20, 30, 40, 50])   // (20 + 40) / 2
        XCTAssertEqual(done.filledCount, 1)
    }

    /// The same gap under `0`, which reads a missing point as zero rather than estimating.
    func testTimelineGapIsFilledWithZero() throws {
        let done = try complete(values: nums([10, 20, 40, 50]), timeline: nums([1, 2, 4, 5]),
                                .zeros)
        XCTAssertEqual(done.values, [10, 20, 0, 40, 50])
        XCTAssertEqual(done.filledCount, 1)
    }

    // MARK: - A blank observation

    /// A blank cell against a present timestamp is the same hole by another route.
    func testBlankObservationIsFilledLikeAGap() throws {
        let done = try complete(
            values: cells([10, 20, nil, 40, 50, 60, 70, 80, 90, 100]),
            timeline: nums([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
            .neighbourAverage)
        XCTAssertEqual(done.values, [10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
        XCTAssertEqual(done.filledCount, 1)
    }

    // MARK: - Runs, edges, and the decisions in them

    /// **A run of missing points all take the same average**, which is the literal reading
    /// of "the average of the neighboring points": the neighbours are the nearest present
    /// values either side of the *run*, not the interpolated points beside each hole.
    ///
    /// The two readings are distinguishable here, which is the point of the test. Ours fills
    /// both holes with 35 — the average of 20 at `t=2` and 50 at `t=5`. Linear interpolation
    /// would give 30 and 40, and is the reading Excel's wording does not support.
    func testRunOfMissingPointsSharesOneAverage() throws {
        // Long enough that two holes are 20% of the grid: this tests the filling, not the
        // 30% ceiling, and a three-point series with one hole would trip the ceiling instead.
        let done = try complete(
            values: nums([10, 20, 50, 60, 70, 80, 90, 100]),
            timeline: nums([1, 2, 5, 6, 7, 8, 9, 10]),
            .neighbourAverage)
        XCTAssertEqual(done.timeline, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(done.values, [10, 20, 35, 35, 50, 60, 70, 80, 90, 100])
        XCTAssertEqual(done.filledCount, 2)                 // (20 + 50) / 2, twice
    }

    /// **A hole at the start has only one neighbour**, so there is no average to take and
    /// the single neighbour is used. A gap cannot occur at the start of a *timeline* — the
    /// series begins where it begins — so this arises only from a blank leading cell.
    func testLeadingBlankUsesItsOnlyNeighbour() throws {
        let done = try complete(
            values: cells([nil, 20, 30, 40, 50, 60, 70, 80, 90, 100]),
            timeline: nums([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
            .neighbourAverage)
        XCTAssertEqual(done.values, [20, 20, 30, 40, 50, 60, 70, 80, 90, 100])
        XCTAssertEqual(done.filledCount, 1)
    }

    /// The same at the end.
    func testTrailingBlankUsesItsOnlyNeighbour() throws {
        let done = try complete(
            values: cells([10, 20, 30, 40, 50, 60, 70, 80, 90, nil]),
            timeline: nums([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
            .neighbourAverage)
        XCTAssertEqual(done.values, [10, 20, 30, 40, 50, 60, 70, 80, 90, 90])
        XCTAssertEqual(done.filledCount, 1)
    }

    /// Under `zeros` an edge hole is simply zero — no neighbour question arises.
    func testLeadingBlankUnderZeros() throws {
        let done = try complete(
            values: cells([nil, 20, 30, 40, 50, 60, 70, 80, 90, 100]),
            timeline: nums([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
            .zeros)
        XCTAssertEqual(done.values, [0, 20, 30, 40, 50, 60, 70, 80, 90, 100])
    }

    /// Every observation blank: nothing to estimate from, and nothing to forecast.
    func testAllObservationsBlankIsNum() throws {
        guard case .success(let pair) = ETSArguments.paired(values: cells([nil, nil, nil]),
                                                            timeline: nums([1, 2, 3])) else {
            return XCTFail("pairing failed")
        }
        guard case .failure(let error) = ETSArguments.completed(pair, using: .neighbourAverage) else {
            return XCTFail("expected an error")
        }
        XCTAssertEqual(error, .num)
    }

    // MARK: - The 30% ceiling

    /// **Excel documents support for "up to 30% missing points", and this is where that
    /// bites.** Eight observations on a grid of ten is two holes, 20%, comfortably inside it.
    func testThirtyPercentMissingIsAllowed() throws {
        // Present at 1…7 and 10; the holes are at 8 and 9.
        let done = try complete(values: nums([1, 2, 3, 4, 5, 6, 7, 10]),
                                timeline: nums([1, 2, 3, 4, 5, 6, 7, 10]),
                                .neighbourAverage)
        XCTAssertEqual(done.timeline.count, 10)
        XCTAssertEqual(done.filledCount, 2)
    }

    /// Past the ceiling. **The error code here is provisional** — Excel documents the 30%
    /// support without naming what happens beyond it, and `#NUM!` is this library's reading
    /// of "cannot compute" rather than an observed answer. See the note on
    /// ``ETSArguments/completed(_:using:)``.
    func testBeyondThirtyPercentIsNum() throws {
        // A grid of 11 (1…11) holding four observations: seven holes, 64%.
        guard case .success(let pair) = ETSArguments.paired(values: nums([10, 20, 30, 40]),
                                                            timeline: nums([1, 2, 3, 11])) else {
            return XCTFail("pairing failed")
        }
        guard case .failure(let error) = ETSArguments.completed(pair, using: .neighbourAverage) else {
            return XCTFail("expected an error")
        }
        XCTAssertEqual(error, .num)
    }
}
