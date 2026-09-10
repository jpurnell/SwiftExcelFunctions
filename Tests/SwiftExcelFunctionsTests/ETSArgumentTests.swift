import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// Turning `FORECAST.ETS*`'s two ranges into numbers, and deciding `#N/A`.
///
/// Every one of the four forecasting functions takes `values` and `timeline` as its first
/// two arguments, so this is the boundary all of them share. Nothing here forecasts: it
/// pairs two ranges, coerces what it finds, and reports the mismatch Excel calls `#N/A`.
final class ETSArgumentTests: XCTestCase {

    private func nums(_ v: [Double]) -> CellValue { .array(CellMatrix(row: v.map { .number($0) })) }

    private func paired(
        _ values: CellValue,
        _ timeline: CellValue,
        line: UInt = #line
    ) throws -> ETSArguments.Paired {
        switch ETSArguments.paired(values: values, timeline: timeline) {
        case .success(let pair):
            return pair
        case .failure(let error):
            XCTFail("expected a pair, got \(error)", line: line)
            throw XCTSkip("no pair")
        }
    }

    private func pairError(
        _ values: CellValue,
        _ timeline: CellValue,
        line: UInt = #line
    ) throws -> ExcelError {
        switch ETSArguments.paired(values: values, timeline: timeline) {
        case .success:
            XCTFail("expected an error", line: line)
            throw XCTSkip("no error")
        case .failure(let error):
            return error
        }
    }

    // MARK: - The ordinary case

    func testPairsTwoRanges() throws {
        let pair = try paired(nums([10, 20, 30]), nums([1, 2, 3]))
        XCTAssertEqual(pair.timeline, [1, 2, 3])
        XCTAssertEqual(pair.values, [10, 20, 30])
    }

    /// **Pairing happens before sorting.** A value belongs to its own timestamp, so the two
    /// ranges are zipped in the order they arrive and only then ordered together. Sorting
    /// the timeline alone would silently reassign every value to the wrong date, which is
    /// the kind of wrong answer that looks entirely plausible in a cell.
    func testValuesFollowTheirTimestampsThroughSorting() throws {
        let pair = try paired(nums([10, 20, 30]), nums([3, 1, 2]))
        XCTAssertEqual(pair.timeline, [1, 2, 3])
        XCTAssertEqual(pair.values, [20, 30, 10])
    }

    // MARK: - `#N/A` — the ranges disagree in length

    /// The one error condition needing both ranges, and the only one Excel answers `#N/A`.
    func testLengthMismatchIsNotAvailable() throws {
        XCTAssertEqual(try pairError(nums([10, 20, 30]), nums([1, 2])), .na)
        XCTAssertEqual(try pairError(nums([10, 20]), nums([1, 2, 3])), .na)
    }

    /// Empty ranges are a mismatch with nothing to forecast rather than a length error;
    /// they agree in length, so the timeline decides, and a timeline of nothing has no step.
    func testTwoEmptyRangesAreNum() throws {
        XCTAssertEqual(try pairError(.array(CellMatrix(row: [])), .array(CellMatrix(row: []))), .num)
    }

    // MARK: - Coercion

    /// A single cell is a range of one — which is still too short to have a step, but it
    /// must pair rather than reject, or the error would be the wrong one.
    func testSingleCellsPairAndThenFailOnTheStep() throws {
        XCTAssertEqual(try pairError(.number(10), .number(1)), .num)
    }

    /// **Blanks in the values are missing observations, not errors.** That is what
    /// `data_completion` exists to handle, so a blank keeps its timestamp and is carried
    /// forward as absent rather than rejected or read as zero.
    func testBlankValueIsMissingRatherThanZero() throws {
        let pair = try paired(
            .array(CellMatrix(row: [.number(10), .blank, .number(30)])),
            nums([1, 2, 3]))
        XCTAssertEqual(pair.timeline, [1, 2, 3])
        XCTAssertEqual(pair.observations, [10, nil, 30])
    }

    /// Text where a number belongs is `#VALUE!` — it is not a gap, it is the wrong type.
    func testTextInValuesIsValue() throws {
        XCTAssertEqual(
            try pairError(.array(CellMatrix(row: [.number(10), .text("x"), .number(30)])),
                          nums([1, 2, 3])),
            .value)
    }

    /// A blank *timestamp* is not a missing observation — it is a row with no place on the
    /// timeline, and nothing can be inferred about where it belonged.
    func testBlankTimestampIsValue() throws {
        XCTAssertEqual(
            try pairError(nums([10, 20, 30]),
                          .array(CellMatrix(row: [.number(1), .blank, .number(3)]))),
            .value)
    }

    /// An error anywhere in either range propagates, as it does everywhere else in the
    /// library: a range holding `#DIV/0!` cannot be forecast from.
    func testErrorInEitherRangePropagates() throws {
        XCTAssertEqual(
            try pairError(.array(CellMatrix(row: [.number(10), .error(.div0), .number(30)])),
                          nums([1, 2, 3])),
            .div0)
        XCTAssertEqual(
            try pairError(nums([10, 20, 30]),
                          .array(CellMatrix(row: [.number(1), .error(.ref), .number(3)]))),
            .ref)
    }

    // MARK: - The step comes with the pair

    /// The pair carries the step because every caller needs it and re-deriving it per
    /// statistic would let two of them disagree.
    func testPairCarriesTheStep() throws {
        XCTAssertEqual(try paired(nums([10, 20, 30]), nums([44927, 44934, 44941])).step,
                       7, accuracy: 1e-12)
    }

    /// **A duplicate timestamp is combined, not rejected** — measured against Excel, which
    /// contradicts the published specification. The pair that comes back is shorter than
    /// the ranges that went in, and the aggregate is `data_completion`'s input like any
    /// other observation. See ``ETSArguments/Aggregation`` for the measurements.
    ///
    /// This test previously asserted `#VALUE!` on the strength of Microsoft's documentation
    /// and was marked provisional when written; the measurement is why it now reads the
    /// other way.
    func testDuplicateTimestampsAreCombined() throws {
        let pair = try paired(nums([10, 20, 30]), nums([1, 2, 2]))
        XCTAssertEqual(pair.timeline, [1, 2])
        XCTAssertEqual(pair.observations, [10, 25])   // default AVERAGE of 20 and 30
    }
}
