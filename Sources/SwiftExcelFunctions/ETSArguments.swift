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
