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
    public static let all: [ExcelFunction] = [statistic, seasonality, prediction, interval]

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
                return fitted(pair, options) { fit, _ in
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
                return fitted(pair, options) { fit, _ in
                    // **Zero when nothing was detected**, measured against Excel: a
                    // monotone ramp answers 0, not 1. Upstream reports a non-seasonal fit
                    // as a cycle of 1, which is right for a model and wrong for this
                    // question — "no repeating pattern" and "a pattern that repeats every
                    // period" are different answers, and 1 would claim the second.
                    fit.seasonalityWasDetected ? .number(Double(fit.seasonLength)) : .number(0)
                }
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
    ///   - read: Which part of the fit the caller asked for, given the fit and the
    ///     completed series it was fitted to.
    /// - Returns: The requested value, or the Excel error the failure maps to.
    static func fitted(
        _ pair: ETSArguments.Paired,
        _ options: Options,
        _ read: (ETSFit<Double>, TimeSeries<Double>) -> CellValue
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
                return read(try timeSeries.fitETS(seasonality: options.seasonality), timeSeries)
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

// MARK: - The prediction and its interval

public extension BuiltinForecastETS {

    /// `FORECAST.ETS(target_date, values, timeline, [seasonality], [data_completion], [aggregation])`
    ///
    /// Routed through `fitETS`, so the caller no longer has to invent an alpha, a beta and
    /// a gamma to get a forecast — which was the only way to reach `HoltWintersModel`
    /// before, and the reason the fitter was worth writing.
    static var prediction: ExcelFunction {
        ExcelFunction(name: "FORECAST.ETS", minArgs: 3, maxArgs: 6) { args in
            predict(args, confidence: nil)
        }
    }

    /// `FORECAST.ETS.CONFINT(target_date, values, timeline, [confidence_level], [seasonality], [data_completion], [aggregation])`
    ///
    /// The **half-width** of the interval around the forecast, which is what Excel returns —
    /// not the bounds themselves. A caller draws the band as `FORECAST.ETS ± CONFINT`.
    static var interval: ExcelFunction {
        ExcelFunction(name: "FORECAST.ETS.CONFINT", minArgs: 3, maxArgs: 7) { args in
            // The confidence level occupies position 3 here, displacing the three shared
            // options by one — which is the only structural difference between the two.
            var level = 0.95
            if args.count > 3, case .number(let raw) = args[3].resolved {
                guard raw > 0, raw < 1 else { return .error(.num) }
                level = raw
            }
            return predict(args, confidence: level)
        }
    }

    /// Forecasts to a target date, optionally returning the interval half-width instead.
    ///
    /// - Parameters:
    ///   - args: The evaluated arguments.
    ///   - confidence: The confidence level for an interval, or `nil` for a point forecast.
    /// - Returns: The forecast, the half-width, or the Excel error.
    private static func predict(_ args: [CellValue], confidence: Double?) -> CellValue {
        guard case .number(let target) = args[0].resolved else {
            if case .error(let error) = args[0].resolved { return .error(error) }
            return .error(.value)
        }
        // CONFINT inserts confidence_level at 3, so its shared options all shift by one.
        let shift = confidence == nil ? 0 : 1
        let options = readOptions(args, seasonalityAt: 3 + shift,
                                  completionAt: 4 + shift, aggregationAt: 5 + shift)
        switch options {
        case .failure(let error):
            return .error(error)
        case .success(let options):
            switch ETSArguments.paired(values: args[1], timeline: args[2],
                                       aggregation: options.aggregation) {
            case .failure(let error):
                return .error(error)
            case .success(let pair):
                guard let last = pair.timeline.last, pair.step > 0 else { return .error(.num) }
                // **The target must lie beyond the history.** Excel says so explicitly, and
                // it is the one argument error these two own that the statistics do not.
                guard target > last else { return .error(.num) }
                let horizon = Int(((target - last) / pair.step).rounded(.up))
                guard horizon >= 1 else { return .error(.num) }
                return forecastValue(pair, options, horizon: horizon, confidence: confidence)
            }
        }
    }

    /// Fits, forecasts `horizon` steps, and reads the last of them.
    ///
    /// - Parameters:
    ///   - pair: The validated pair.
    ///   - options: Completion and seasonality choices.
    ///   - horizon: How many steps past the history the target sits.
    ///   - confidence: The confidence level, or `nil` for a point forecast.
    /// - Returns: The value at the target, or the Excel error.
    private static func forecastValue(
        _ pair: ETSArguments.Paired,
        _ options: Options,
        horizon: Int,
        confidence: Double?
    ) -> CellValue {
        fitted(pair, options) { fit, series in
            // A forecast can still refuse after a successful fit — a horizon the model
            // cannot reach, or an interval it cannot form — so the error is caught and
            // named rather than dropped by a `try?`.
            do {
                guard let level = confidence else {
                    let path = try fit.model.trainedForecast(from: series, horizon: horizon)
                    guard let predicted = path.valuesArray.last else { return .error(.num) }
                    return .number(predicted)
                }
                let band = try fit.model.forecastWithConfidence(
                    timeSeries: series, periods: horizon, confidenceLevel: level)
                guard let upper = band.upperBound.valuesArray.last,
                      let centre = band.forecast.valuesArray.last else { return .error(.num) }
                // The half-width, which is what Excel reports — not the bounds.
                return .number(abs(upper - centre))
            } catch let failure as ForecastError {
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
