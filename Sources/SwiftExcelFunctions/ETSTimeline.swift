import Foundation
import SwiftExcelCore

/// An answer, or the Excel error that replaces it.
///
/// `Result` cannot be used here: `ExcelError` is a plain `String`-backed enum and does not
/// conform to `Error`, which is the right decision upstream — an Excel error is a *value* a
/// cell holds, not something thrown — and it means the failure channel in this file needs
/// its own type.
public enum ETSResult<Success: Sendable>: Sendable {

    /// The computed answer.
    case success(Success)

    /// The error Excel would show in the cell instead.
    case failure(ExcelError)

    /// The answer as a `CellValue`, for returning straight out of a binding.
    ///
    /// - Parameter transform: How to render a success. Failures become `.error`.
    /// - Returns: The rendered success, or the failure as a cell error.
    public func cellValue(_ transform: (Success) -> CellValue) -> CellValue {
        switch self {
        case .success(let value): return transform(value)
        case .failure(let error): return .error(error)
        }
    }
}

extension ETSResult: Equatable where Success: Equatable {}

/// The timeline of a `FORECAST.ETS*` call: its step, and the two errors it can carry.
///
/// Excel's forecasting functions take a `timeline` alongside their values, and three of the
/// four error conditions in the published specification are decided by the timeline alone —
/// before any model is fitted, and regardless of which of the four functions was called:
///
/// | Condition | Error |
/// |---|---|
/// | No constant step can be identified | `#NUM!` |
/// | The timeline contains duplicate values | `#VALUE!` |
/// | Timeline and values differ in length | `#N/A` |
///
/// The first two live here; the third needs both ranges and belongs with the argument
/// preparation. The step itself is `FORECAST.ETS.STAT`'s statistic type 8, so this type
/// answers one of Excel's eight statistics on its own, with no forecasting involved.
///
/// ## A gap is not an inconsistent step
///
/// Excel documents support for up to 30% missing points, so `1, 2, 4, 5` is a step of 1
/// with one observation absent — not a timeline whose steps are 1, 2, 1. The step is the
/// interval the timeline is *on*, and every observation must land on it.
///
/// **The step is the smallest interval observed, not the greatest common divisor of the
/// intervals.** The alternative is close to vacuous: any set of rational intervals has some
/// common divisor, so a detector looking for one would accept nearly every timeline and
/// report a step finer than anything present. `1, 2, 3.5` has a common divisor of 0.5, a
/// value the timeline never exhibits; under the smallest-interval rule its step is 1, the
/// interval of 1.5 is not a whole multiple of 1, and the answer is `#NUM!` — which is what
/// "a constant step can't be identified" means.
///
/// ```swift
/// switch ETSTimeline.step(of: [44927, 44934, 44941]) {
/// case .success(let step): print(step)   // 7
/// case .failure(let error): print(error)
/// }
/// ```
public enum ETSTimeline {

    /// How far an interval may sit from a whole multiple of the step, relative to the step.
    ///
    /// Date timelines arrive as serial numbers and arithmetic on them does not land
    /// exactly, so a detector demanding exact equality would reject an ordinary monthly
    /// timeline. This tolerance is for representation error only: at `1e-9` of the step it
    /// admits accumulated floating-point drift and still rejects a timeline that is
    /// genuinely uneven by any margin a spreadsheet author would notice.
    static let relativeTolerance = 1e-9

    /// Reads the step from a timeline.
    ///
    /// The timeline is sorted first — Excel documents that it need not arrive in order and
    /// sorts implicitly for its own calculations — so a descending timeline yields the same
    /// positive step as its ascending twin rather than a negative one.
    ///
    /// - Parameter timeline: The timeline values, in any order.
    /// - Returns: The step, or `#NUM!` when no constant step can be identified and
    ///   `#VALUE!` when the timeline contains duplicates.
    public static func step(of timeline: [Double]) -> ETSResult<Double> {
        // Non-finite entries cannot be ordered or differenced, and sorting them is not
        // defined — so this is checked before anything touches the values.
        guard timeline.allSatisfy({ $0.isFinite }) else { return .failure(.num) }
        guard timeline.count >= 2 else { return .failure(.num) }

        let ordered = timeline.sorted()
        var intervals: [Double] = []
        intervals.reserveCapacity(ordered.count - 1)
        for index in 1..<ordered.count {
            let interval = ordered[index] - ordered[index - 1]
            // A repeated timestamp gives a zero interval, which would reduce every
            // multiple below to nonsense. It is reported as the duplicate it is rather
            // than as an inconsistent step, because that is the error Excel names for it.
            guard interval > 0 else { return .failure(.value) }
            intervals.append(interval)
        }

        // Bound and guarded rather than inferred from `intervals` being non-empty: the
        // fp-safety checker tracks the divisor symbol, and `candidate` is the divisor.
        guard let candidate = intervals.min(), candidate > 0 else { return .failure(.num) }
        for interval in intervals {
            let multiple = (interval / candidate).rounded()
            let expected = multiple * candidate
            guard abs(interval - expected) <= relativeTolerance * candidate else {
                return .failure(.num)
            }
        }
        return .success(candidate)
    }
}
