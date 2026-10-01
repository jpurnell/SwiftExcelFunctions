import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// `aggregation` — combining values that share a timestamp.
///
/// **Every expectation in this file is measured against Excel for Mac rather than taken
/// from the published specification, which is wrong about this argument in three separate
/// ways.** See ``ETSArguments/Aggregation`` for the measurements and the method.
@Suite struct ETSAggregationTests {

    private func nums(_ v: [Double]) -> CellValue { .array(CellMatrix(row: v.map { .number($0) })) }

    /// A ten-point timeline with `3` repeated, carrying `group` at that timestamp.
    ///
    /// Ten points so that the completion ceiling is never what is under test, and `1, 2, 9`
    /// as the default group because every aggregate of it is distinct: average 4, sum 12,
    /// count 3, max 9, median 2, min 1.
    private func repeated(_ group: [Double]) -> (values: CellValue, timeline: CellValue) {
        var stamps: [Double] = [1, 2]
        var observations: [Double] = [0, 0]
        for value in group {
            stamps.append(3)
            observations.append(value)
        }
        for stamp in 4...10 {
            stamps.append(Double(stamp))
            observations.append(0)
        }
        return (nums(observations), nums(stamps))
    }

    private func pair(
        _ group: [Double],
        _ aggregation: ETSArguments.Aggregation,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ETSArguments.Paired {
        let ranges = repeated(group)
        switch ETSArguments.paired(values: ranges.values,
                                   timeline: ranges.timeline,
                                   aggregation: aggregation) {
        case .success(let pair):
            return pair
        case .failure(let error):
            Issue.record("expected a pair, got \(error)")
            throw TestFailure("no pair")
        }
    }

    /// The aggregated observation at the repeated timestamp.
    private func atThree(_ pair: ETSArguments.Paired) throws -> Double {
        let index = try #require(pair.timeline.firstIndex(of: 3))
        return try #require(pair.observations[index])
    }

    // MARK: - Duplicates are combined, not rejected

    /// **The headline correction.** Microsoft documents a duplicate timeline value as
    /// `#VALUE!`; Excel aggregates it. Eleven measured calls, no `#VALUE!` among them, and
    /// the answer changes with the aggregation code — which it could not do if duplicates
    /// were rejected.
    @Test func duplicateTimestampsAreAggregated() throws {
        let pair = try pair([1, 2, 9], .sum)
        #expect(pair.timeline == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
        #expect(try abs(atThree(pair) - 12) <= 1e-12)
    }

    /// The step is read *after* de-duplication. Read before, the repeated `3` gives a zero
    /// interval and the whole call fails as a duplicate — which is the ordering bug this
    /// pipeline had until the measurements came back.
    @Test func stepComesFromTheDeduplicatedTimeline() throws {
        #expect(try abs(pair([1, 2, 9], .average).step - 1) <= 1e-12)
    }

    // MARK: - The measured code mapping

    /// Codes are **1-based and alphabetical**, which is neither the order nor the base
    /// Microsoft publishes. Each expectation below is an aggregate of `1, 2, 9`.
    @Test func codeMapping() throws {
        let expected: [(Int, ETSArguments.Aggregation)] = [
            (1, .average), (2, .count), (3, .countA),
            (4, .max), (5, .median), (6, .min), (7, .sum),
        ]
        for (code, aggregation) in expected {
            switch ETSArguments.Aggregation.code(code) {
            case .success(let parsed):
                #expect(parsed == aggregation, "code \(code)")
            case .failure(let error):
                Issue.record("code \(code) should map to \(aggregation), got \(error)")
            }
        }
    }

    /// **Code `0` is `#NUM!`**, though the specification names it as both AVERAGE and the
    /// default. Measured twice, on two statistic types.
    @Test func codeZeroIsNum() throws {
        guard case .failure(let error) = ETSArguments.Aggregation.code(0) else {
            Issue.record("expected an error"); return
        }
        #expect(error == .num)
    }

    /// The default is AVERAGE — the specification is right about the function and wrong
    /// about its number.
    @Test func defaultIsAverage() throws {
        let ranges = repeated([1, 2, 9])
        guard case .success(let pair) = ETSArguments.paired(values: ranges.values,
                                                            timeline: ranges.timeline) else {
            Issue.record("pairing failed"); return
        }
        #expect(try abs(atThree(pair) - 4) <= 1e-12)
    }

    // MARK: - Each function

    @Test func average() throws {
        #expect(try abs(atThree(try pair([1, 2, 9], .average)) - 4) <= 1e-12)
    }

    @Test func sum() throws {
        #expect(try abs(atThree(try pair([1, 2, 9], .sum)) - 12) <= 1e-12)
    }

    @Test func max() throws {
        #expect(try abs(atThree(try pair([1, 2, 9], .max)) - 9) <= 1e-12)
    }

    @Test func min() throws {
        #expect(try abs(atThree(try pair([1, 2, 9], .min)) - 1) <= 1e-12)
    }

    /// Median of an odd group is its middle value once sorted.
    @Test func medianOfOddGroup() throws {
        #expect(try abs(atThree(try pair([1, 2, 9], .median)) - 2) <= 1e-12)
    }

    /// Median of an even group is the mean of the middle pair. Not measured — no even
    /// group was tested against Excel — so this is the conventional definition rather than
    /// an observation, and is the first thing to check if a workbook ever disagrees.
    @Test func medianOfEvenGroup() throws {
        #expect(try abs(atThree(try pair([1, 2, 3, 10], .median)) - 2.5) <= 1e-12)
    }

    /// **COUNT returns one less than the group size, which is not what the name means.**
    ///
    /// Measured on both of Excel's answers: a group of 2 gave 1, a group of 3 gave 2. It is
    /// reproduced rather than corrected, because the point of this layer is to answer what
    /// Excel answers. See ``ETSArguments/Aggregation`` for why the measurement is trusted.
    @Test func countIsGroupSizeLessOne() throws {
        #expect(try abs(atThree(try pair([1, 2, 9], .count)) - 2) <= 1e-12)
        #expect(try abs(atThree(try pair([0, 100], .count)) - 1) <= 1e-12)
    }

    /// `COUNTA` measured identically to `COUNT` in both datasets.
    @Test func countAMatchesCount() throws {
        #expect(try abs(atThree(try pair([1, 2, 9], .countA)) - 2) <= 1e-12)
    }

    // MARK: - Groups of one

    /// A timestamp appearing once is aggregated too — trivially, to itself — under every
    /// function except the counts, where a group of one measures as zero by the rule above.
    @Test func singleObservationIsUnchangedUnderValueFunctions() throws {
        for aggregation in [ETSArguments.Aggregation.average, .sum, .max, .min, .median] {
            let ranges = repeated([7])
            guard case .success(let pair) = ETSArguments.paired(values: ranges.values,
                                                                timeline: ranges.timeline,
                                                                aggregation: aggregation) else {
                Issue.record("pairing failed for \(aggregation)"); return
            }
            #expect(try abs(atThree(pair) - 7) <= 1e-12, "\(aggregation)")
        }
    }
}
