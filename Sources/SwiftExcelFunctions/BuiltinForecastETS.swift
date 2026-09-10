import Foundation
import BusinessMath
import SwiftExcelCore

/// `FORECAST.ETS.STAT` and `FORECAST.ETS.SEASONALITY`.
///
/// Both are thin: ``ETSArguments`` validates the ranges and puts the series on its step
/// grid, BusinessMath's `fitETS` does the mathematics, and this file chooses which field of
/// the result the caller asked for. Nothing here forecasts, and nothing here parses — the
/// division is the one recorded in ``ETSArguments``.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinForecastETS.all {
///     registry.register(fn)
/// }
/// ```
///
/// ## Statistic types
///
/// | Type | Answer | Source |
/// |---|---|---|
/// | 1–3 | alpha, beta, gamma | the fit's searched parameters |
/// | 4 | MASE | the fit's errors |
/// | 5 | SMAPE | likewise, on the **halved** denominator — see ``ETSArguments/Aggregation`` |
/// | 6–7 | MAE, RMSE | likewise |
/// | 8 | step size | ``ETSTimeline/step(of:)``, and **no model at all** |
///
/// Type 8 is deliberately answered before anything is fitted. The step is a property of the
/// timeline, so a series far too short to train on still has one, and routing type 8 through
/// the fit would turn a good answer into `#NUM!`.
public enum BuiltinForecastETS {

    /// Both forecasting statistics for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [statistic, seasonality]

    /// `FORECAST.ETS.STAT(values, timeline, statistic_type, [seasonality], [data_completion], [aggregation])`
    public static let statistic = ExcelFunction(
        name: "FORECAST.ETS.STAT", minArgs: 3, maxArgs: 6
    ) { args in
        guard case .number(let rawType) = args[2].resolved else { return .error(.value) }
        let type = Int(rawType)
        guard (1...8).contains(type) else { return .error(.num) }

        let options = readOptions(args, seasonalityAt: 3, completionAt: 4, aggregationAt: 5)
        switch options {
        case .failure(let error): return .error(error)
        case .success(let options):
            switch ETSArguments.paired(values: args[0], timeline: args[1],
                                       aggregation: options.aggregation) {
            case .failure(let error):
                return .error(error)
            case .success(let pair):
                // The step needs no model, and answering it here is what lets a series
                // too short to fit still report one.
                if type == 8 { return .number(pair.step) }
                return fitted(pair, options) { fit in
                    switch type {
                    case 1: return .number(fit.alpha)
                    case 2: return .number(fit.beta)
                    case 3: return .number(fit.gamma)
                    case 4: return fit.errors.mase.map { CellValue.number($0) } ?? .error(.na)
                    case 5: return .number(fit.errors.smape)
                    case 6: return .number(fit.errors.mae)
                    default: return .number(fit.errors.rmse)
                    }
                }
            }
        }
    }

    /// `FORECAST.ETS.SEASONALITY(values, timeline, [data_completion], [aggregation])`
    ///
    /// "The length of the repetitive pattern Excel detects." Detection is upstream's
    /// `dominantSeasonLength(maxLag:)`, reached through `ETSSeasonality.detect`, so this
    /// answers with the cycle the data supports rather than one the caller supplied.
    public static let seasonality = ExcelFunction(
        name: "FORECAST.ETS.SEASONALITY", minArgs: 2, maxArgs: 4
    ) { args in
        let options = readOptions(args, seasonalityAt: nil, completionAt: 2, aggregationAt: 3)
        switch options {
        case .failure(let error): return .error(error)
        case .success(let options):
            switch ETSArguments.paired(values: args[0], timeline: args[1],
                                       aggregation: options.aggregation) {
            case .failure(let error):
                return .error(error)
            case .success(let pair):
                return fitted(pair, options) { .number(Double($0.seasonLength)) }
            }
        }
    }

    // MARK: - Arguments

    /// The optional arguments the two functions share, in whichever positions they occupy.
    struct Options {
        var seasonality: ETSSeasonality = .detect
        var completion: ETSArguments.DataCompletion = .neighbourAverage
        var aggregation: ETSArguments.Aggregation = .average
    }

    /// Reads the optional arguments, each from its own position.
    ///
    /// - Parameters:
    ///   - args: The evaluated arguments.
    ///   - seasonalityAt: Where `seasonality` sits, or `nil` where the function has none.
    ///   - completionAt: Where `data_completion` sits.
    ///   - aggregationAt: Where `aggregation` sits.
    /// - Returns: The options, or the error Excel shows for a bad one.
    static func readOptions(
        _ args: [CellValue],
        seasonalityAt: Int?,
        completionAt: Int,
        aggregationAt: Int
    ) -> ETSResult<Options> {
        var options = Options()

        if let position = seasonalityAt, let raw = number(args, at: position) {
            // Excel's three cases in one numeric argument: 0 non-seasonal, 1 detect,
            // n an explicit cycle. 8,760 is its documented ceiling, being hours in a year.
            let periods = Int(raw)
            guard raw >= 0, raw <= 8_760, Double(periods).isEqual(to: raw) else {
                return .failure(.num)
            }
            switch periods {
            case 0: options.seasonality = .none
            case 1: options.seasonality = .detect
            default: options.seasonality = .periods(periods)
            }
        }
        if let raw = number(args, at: completionAt) {
            switch Int(raw) {
            case 0: options.completion = .zeros
            case 1: options.completion = .neighbourAverage
            default: return .failure(.num)
            }
        }
        if let raw = number(args, at: aggregationAt) {
            switch ETSArguments.Aggregation.code(Int(raw)) {
            case .failure(let error): return .failure(error)
            case .success(let aggregation): options.aggregation = aggregation
            }
        }
        return .success(options)
    }

    /// The numeric argument at `position`, or `nil` when it was omitted or left blank.
    ///
    /// - Parameters:
    ///   - args: The evaluated arguments.
    ///   - position: The index to read.
    /// - Returns: The number, or `nil` when absent.
    private static func number(_ args: [CellValue], at position: Int) -> Double? {
        guard position < args.count, case .number(let value) = args[position].resolved else {
            return nil
        }
        return value
    }

    // MARK: - Fitting

    /// Completes the series, fits it, and reads one field out of the result.
    ///
    /// - Parameters:
    ///   - pair: The validated pair.
    ///   - options: The completion and seasonality choices.
    ///   - read: Which part of the fit the caller asked for.
    /// - Returns: The requested value, or the Excel error the failure maps to.
    static func fitted(
        _ pair: ETSArguments.Paired,
        _ options: Options,
        _ read: (ETSFit<Double>) -> CellValue
    ) -> CellValue {
        switch ETSArguments.completed(pair, using: options.completion) {
        case .failure(let error):
            return .error(error)
        case .success(let series):
            // The model needs order and even spacing, not calendar meaning: the series is
            // already on a uniform grid, so synthetic consecutive days carry it faithfully
            // and no timestamp of the workbook's is reinterpreted as a date.
            let reference = Date(timeIntervalSince1970: 0)
            let periods = series.values.indices.map { index in
                Period.day(reference.addingTimeInterval(Double(index) * 86_400))
            }
            let timeSeries = TimeSeries(periods: periods, values: series.values)
            do {
                return read(try timeSeries.fitETS(seasonality: options.seasonality))
            } catch let failure as ForecastError {
                // Every way upstream can refuse is a computation with no result, which is
                // what `#NUM!` means in a cell. They are matched individually rather than
                // caught wholesale so that a new case upstream fails to compile here
                // instead of being silently folded into this answer.
                switch failure {
                case .insufficientData, .invalidParameter, .modelNotTrained,
                     .invalidConfidenceLevel:
                    return .error(.num)
                }
            } catch {
                return .error(.num)
            }
        }
    }
}
