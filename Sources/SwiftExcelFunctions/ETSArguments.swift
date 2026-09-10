import Foundation
import SwiftExcelCore

/// The arguments every `FORECAST.ETS*` call shares, validated once.
///
/// All four forecasting functions — `FORECAST.ETS`, `.CONFINT`, `.SEASONALITY` and `.STAT` —
/// open with the same two arguments and answer the same errors for them. Validating that
/// boundary in one place is what stops two of them disagreeing about the same workbook.
///
/// ```swift
/// import SwiftExcelCore
///
/// let values = CellValue.array(CellMatrix(row: [.number(10), .number(20), .number(30)]))
/// let timeline = CellValue.array(CellMatrix(row: [.number(1), .number(2), .number(3)]))
/// switch ETSArguments.paired(values: values, timeline: timeline) {
/// case .success(let pair): print(pair.step)     // 1.0
/// case .failure(let error): print(error)
/// }
/// ```
///
/// ## What this layer owns
///
/// Excel's argument semantics, and nothing else. The mathematics — fitting, seasonality
/// detection, the error metrics — belongs upstream in BusinessMath, and none of it appears
/// here. The division is deliberate: a parser in the binding layer is a parser in the wrong
/// place, and every rule below is a rule about spreadsheets rather than about forecasting.
public enum ETSArguments {

    /// A `values`/`timeline` pair, ordered by time, with its step already read.
    ///
    /// Observations are optional because a blank cell is a *missing* observation rather
    /// than a zero — which is the distinction `data_completion` exists to resolve, and
    /// which is lost the moment a blank is coerced to a number.
    public struct Paired: Equatable, Sendable {

        /// The timestamps, ascending and free of duplicates.
        public let timeline: [Double]

        /// The observations, aligned to ``timeline``; `nil` where the cell was blank.
        public let observations: [Double?]

        /// The interval the timeline is on. See ``ETSTimeline/step(of:)``.
        public let step: Double

        /// The observations with blanks dropped, for callers that only want the numbers.
        public var values: [Double] { observations.compactMap { $0 } }
    }

    /// Pairs and validates the two ranges every forecasting function opens with.
    ///
    /// The order of the checks is itself a decision. Errors inside either range propagate
    /// first, because a range holding `#REF!` cannot be reasoned about at all; then the
    /// lengths, which is the only condition needing both ranges and the only `#N/A` in the
    /// specification; then the timeline's own step and duplicates. Reordering these would
    /// change which error a workbook shows without changing whether it fails.
    ///
    /// - Parameters:
    ///   - values: The `values` argument, a range or a single cell.
    ///   - timeline: The `timeline` argument, of matching length.
    /// - Returns: The ordered pair, or the error Excel shows: `#N/A` for a length mismatch,
    ///   `#VALUE!` for a non-numeric entry or a duplicate timestamp, `#NUM!` when no
    ///   constant step can be read, and any error found inside either range.
    public static func paired(values: CellValue, timeline: CellValue) -> ETSResult<Paired> {
        let valueCells = BuiltinAggregationFunctions.toArray(values)
        let timeCells = BuiltinAggregationFunctions.toArray(timeline)

        if let error = firstError(in: valueCells) ?? firstError(in: timeCells) {
            return .failure(error)
        }
        // The only condition that needs both ranges, and the specification's only `#N/A`.
        guard valueCells.count == timeCells.count else { return .failure(.na) }

        var stamps: [Double] = []
        var observations: [Double?] = []
        stamps.reserveCapacity(timeCells.count)
        observations.reserveCapacity(valueCells.count)
        for index in timeCells.indices {
            // A blank *timestamp* is a row with no place on the timeline — nothing can be
            // inferred about where it belonged — so it is the wrong type rather than a gap.
            guard case .number(let stamp) = timeCells[index].resolved else {
                return .failure(.value)
            }
            stamps.append(stamp)

            switch valueCells[index].resolved {
            case .number(let observation):
                observations.append(observation)
            case .blank:
                // A blank *value* is a missing observation, which is what
                // `data_completion` addresses. It keeps its timestamp.
                observations.append(nil)
            default:
                return .failure(.value)
            }
        }

        switch ETSTimeline.step(of: stamps) {
        case .failure(let error):
            return .failure(error)
        case .success(let step):
            // Sorted as pairs. Sorting the timeline alone would reassign every observation
            // to the wrong timestamp — a wrong answer that looks entirely plausible.
            let ordered = zip(stamps, observations).sorted { $0.0 < $1.0 }
            return .success(Paired(timeline: ordered.map(\.0),
                                   observations: ordered.map(\.1),
                                   step: step))
        }
    }

    /// The first error in a range, if any.
    ///
    /// - Parameter cells: The cells to scan.
    /// - Returns: The error found, or `nil` when the range holds none.
    private static func firstError(in cells: [CellValue]) -> ExcelError? {
        for cell in cells {
            if case .error(let error) = cell.resolved { return error }
        }
        return nil
    }
}

// MARK: - data_completion

public extension ETSArguments {

    /// Excel's `data_completion` argument: what a missing point is worth.
    enum DataCompletion: Equatable, Sendable {

        /// Excel's `0` — a missing point reads as zero.
        case zeros

        /// Excel's `1`, the default — a missing point is completed "to be the average of
        /// the neighboring points".
        case neighbourAverage
    }

    /// A series with no holes in it: every point of the step grid carries a value.
    struct Completed: Equatable, Sendable {

        /// Every timestamp from the first to the last, at the step.
        public let timeline: [Double]

        /// The observations, aligned to ``timeline``, with holes filled.
        public let values: [Double]

        /// The interval the timeline is on.
        public let step: Double

        /// How many points were absent and had to be filled.
        public let filledCount: Int
    }

    /// Puts a paired series back onto its own step grid, filling what is missing.
    ///
    /// Two kinds of hole arrive by different routes and are treated identically: a
    /// timestamp absent from the timeline, and a blank cell against a present timestamp.
    /// Excel's phrase for the argument — "missing points" — covers both, and a forecaster
    /// wants a series with no holes however they arose.
    ///
    /// **A run of missing points all take the same average.** That is the literal reading
    /// of "the average of the neighboring points": the neighbours are the nearest present
    /// values on either side of the *run*, not interpolated points beside each hole. Linear
    /// interpolation is the plausible alternative and is not what the wording says.
    ///
    /// A hole with only one neighbour — a blank first or last cell — takes that neighbour
    /// rather than an average, there being nothing to average it with.
    ///
    /// - Parameters:
    ///   - pair: The validated pair from ``paired(values:timeline:)``.
    ///   - completion: Excel's `data_completion` treatment.
    /// - Returns: The completed series, or `#NUM!` when nothing is present to estimate
    ///   from, or when more than 30% of the grid is missing.
    ///
    /// - Note: **The 30% ceiling's error code is provisional.** Excel documents support for
    ///   "up to 30% missing points" without naming what happens past it; `#NUM!` is this
    ///   library's reading of "cannot compute" rather than a measured answer.
    static func completed(_ pair: Paired, using completion: DataCompletion) -> ETSResult<Completed> {
        let step = pair.step
        guard step > 0, let first = pair.timeline.first, let last = pair.timeline.last else {
            return .failure(.num)
        }

        // The grid the timeline is on, which is what the observations are placed into.
        let spans = ((last - first) / step).rounded()
        guard spans.isFinite, spans >= 0 else { return .failure(.num) }
        let gridCount = Int(spans) + 1
        guard gridCount >= 1 else { return .failure(.num) }

        var grid = [Double?](repeating: nil, count: gridCount)
        for (stamp, observation) in zip(pair.timeline, pair.observations) {
            let offset = Int(((stamp - first) / step).rounded())
            guard offset >= 0, offset < gridCount else { return .failure(.num) }
            grid[offset] = observation
        }

        let presentCount = grid.reduce(into: 0) { total, slot in
            if slot != nil { total += 1 }
        }
        // Nothing present is not a 100% gap to be filled — there is nothing to fill from.
        guard presentCount > 0 else { return .failure(.num) }

        let missingCount = gridCount - presentCount
        // Bound and guarded: the fp-safety checker tracks the divisor symbol.
        let total = Double(gridCount)
        guard total > 0 else { return .failure(.num) }
        guard Double(missingCount) / total <= 0.30 else { return .failure(.num) }

        let filled: [Double]
        switch completion {
        case .zeros:
            filled = grid.map { $0 ?? 0 }
        case .neighbourAverage:
            filled = fillFromNeighbours(grid)
        }
        return .success(Completed(timeline: (0..<gridCount).map { first + Double($0) * step },
                                  values: filled,
                                  step: step,
                                  filledCount: missingCount))
    }

    /// Fills each hole with the average of the nearest present values around its run.
    ///
    /// - Parameter grid: The step grid, `nil` where a point is missing.
    /// - Returns: The grid with every hole filled. Holes at either end take their single
    ///   neighbour; a grid with no present value at all is returned unchanged, which
    ///   ``completed(_:using:)`` refuses before reaching here.
    private static func fillFromNeighbours(_ grid: [Double?]) -> [Double] {
        // The nearest present value at or before each index, and at or after it.
        var before = [Double?](repeating: nil, count: grid.count)
        var carried: Double?
        for index in grid.indices {
            carried = grid[index] ?? carried
            before[index] = carried
        }
        var after = [Double?](repeating: nil, count: grid.count)
        carried = nil
        for index in grid.indices.reversed() {
            carried = grid[index] ?? carried
            after[index] = carried
        }

        return grid.indices.map { index in
            if let present = grid[index] { return present }
            switch (before[index], after[index]) {
            case let (previous?, next?): return (previous + next) / 2
            case let (previous?, nil): return previous
            case let (nil, next?): return next
            case (nil, nil): return 0
            }
        }
    }
}
