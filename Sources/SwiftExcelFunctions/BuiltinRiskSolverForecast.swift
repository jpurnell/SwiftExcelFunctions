import Foundation
import SwiftExcelCore
import BusinessMath

/// The four `PsiForecast*` functions whose mathematics already existed.
///
/// Each takes a range of historical observations, in reading order, and answers the value
/// forecast `horizon` periods beyond the last of them. `horizon` defaults to 1 — the next
/// period — because that is the question a spreadsheet asks most often and the one a reader
/// assumes when the argument is absent.
///
/// ## What is bound and what is written out, and why the difference
///
/// `PsiForecastLinear` **binds**: `LinearTrend` in BusinessMath fits an array and projects
/// from it, so this hands it the numbers and asks.
///
/// The other three do not, and the reason is worth stating rather than leaving as an
/// inconsistency. BusinessMath has *smoothers* — `movingAverage(window:)`,
/// `exponentialMovingAverage(alpha:)` — which answer "what was the level at each past point",
/// and an async streaming `doubleExponentialSmoothing`. A **forecast** is a different
/// question: it is what the level implies about a period that has not happened. Routing
/// through a smoother to take its last value would add indirection without adding an opinion,
/// and for Holt's method it would not work at all, since the forecast needs the trend
/// component the smoother does not return.
///
/// So the three recursions are written here, each stated in its own documentation. That is a
/// deliberate exception to this package's rule about not holding a second copy of upstream
/// mathematics — there is no first copy of *these* to be second to.
///
/// ## Not measurable
///
/// As with every `Psi*`, the argument order follows Frontline's documentation and cannot be
/// put to Excel: a workbook containing one opens without the add-in reading `#NAME?`. Each
/// signature is stated below so a later measurement has something specific to contradict.
public enum BuiltinRiskSolverForecast {

    /// Everything here, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        psiForecastMovingAvg, psiForecastExp, psiForecastDoubleExp, psiForecastLinear
    ]

    // MARK: - Reading the arguments

    /// The observations, in reading order, and the horizon.
    private struct Request {
        let observations: [Double]
        let horizon: Int
    }

    /// Reads the history and the horizon from a call.
    ///
    /// - Parameters:
    ///   - values: the evaluated arguments.
    ///   - horizonIndex: which argument carries the horizon, when one is supplied.
    /// - Returns: the request, or `nil` when the history is unusable.
    private static func request(_ values: [CellValue], horizonIndex: Int) -> Request? {
        guard let first = values.first else { return nil }
        let observations = BuiltinRiskSolverFunctions.series(first)
        guard !observations.isEmpty else { return nil }
        var horizon = 1
        if values.count > horizonIndex,
           let requested = BuiltinRiskSolverFunctions.real(values[horizonIndex]) {
            horizon = Int(requested.rounded(.towardZero))
        }
        guard horizon >= 1 else { return nil }
        return Request(observations: observations, horizon: horizon)
    }

    // MARK: - The four

    /// `PsiForecastMovingAvg(data, window, [horizon])`.
    ///
    /// The mean of the last `window` observations, carried forward. **Flat**: a moving average
    /// holds no trend, so every horizon gives the same number, and that is the method rather
    /// than a simplification. A caller who wants the forecast to move wants
    /// ``psiForecastLinear`` or ``psiForecastDoubleExp``.
    public static let psiForecastMovingAvg = ExcelFunction(
        name: "PSIFORECASTMOVINGAVG", minArgs: 2, maxArgs: 3
    ) { values in
        guard let request = request(values, horizonIndex: 2),
              let requested = BuiltinRiskSolverFunctions.real(values[1]) else {
            return .error(.value)
        }
        let window = Int(requested.rounded(.towardZero))
        guard window >= 1, window <= request.observations.count else { return .error(.num) }
        let recent = Array(request.observations.suffix(window))
        return .number(mean(recent))
    }

    /// `PsiForecastExp(data, alpha, [horizon])` — simple exponential smoothing.
    ///
    /// `sₜ = α·xₜ + (1 − α)·sₜ₋₁`, started at the first observation, and the forecast is the
    /// final level carried forward. **Also flat**, for the same reason: simple exponential
    /// smoothing estimates a level and no trend.
    ///
    /// `alpha` is the weight on the newest observation, so 1 forecasts the last value alone
    /// and values near 0 barely move off the first. Outside `(0, 1]` it is not a smoothing
    /// weight at all and is refused.
    public static let psiForecastExp = ExcelFunction(
        name: "PSIFORECASTEXP", minArgs: 2, maxArgs: 3
    ) { values in
        guard let request = request(values, horizonIndex: 2),
              let alpha = BuiltinRiskSolverFunctions.real(values[1]) else {
            return .error(.value)
        }
        guard alpha > 0, alpha <= 1 else { return .error(.num) }
        var level = request.observations[0]
        for observation in request.observations.dropFirst() {
            level = alpha * observation + (1 - alpha) * level
        }
        return .number(level)
    }

    /// `PsiForecastDoubleExp(data, alpha, beta, [horizon])` — Holt's linear method.
    ///
    /// Two recursions rather than one, because a trending series needs somewhere to keep the
    /// trend:
    ///
    /// ```
    /// levelₜ = α·xₜ + (1 − α)·(levelₜ₋₁ + trendₜ₋₁)
    /// trendₜ = β·(levelₜ − levelₜ₋₁) + (1 − β)·trendₜ₋₁
    /// ```
    ///
    /// and the forecast `h` periods out is `level + h·trend`. **This one moves with the
    /// horizon**, which is the whole difference from the two above — and the reason it could
    /// not have been routed through a smoother, which returns levels and discards the trend.
    ///
    /// The trend starts at the first difference, which needs two observations; one is refused
    /// rather than started at zero, since a zero trend would silently make this the simple
    /// method under the double method's name.
    public static let psiForecastDoubleExp = ExcelFunction(
        name: "PSIFORECASTDOUBLEEXP", minArgs: 3, maxArgs: 4
    ) { values in
        guard let request = request(values, horizonIndex: 3),
              let alpha = BuiltinRiskSolverFunctions.real(values[1]),
              let beta = BuiltinRiskSolverFunctions.real(values[2]) else {
            return .error(.value)
        }
        guard alpha > 0, alpha <= 1, beta > 0, beta <= 1 else { return .error(.num) }
        let observations = request.observations
        guard observations.count >= 2 else { return .error(.num) }

        var level = observations[0]
        var trend = observations[1] - observations[0]
        for observation in observations.dropFirst() {
            let previousLevel = level
            level = alpha * observation + (1 - alpha) * (level + trend)
            trend = beta * (level - previousLevel) + (1 - beta) * trend
        }
        return .number(level + Double(request.horizon) * trend)
    }

    /// `PsiForecastLinear(data, [horizon])` — ordinary least squares on the period index.
    ///
    /// The one of the four that is a **binding**: `LinearTrend` fits an array of values and
    /// projects from it, so the fit and the projection are both upstream and this supplies
    /// the numbers.
    ///
    /// `projectValues(steps:)` returns the whole projection, of which the horizon's step is
    /// wanted — so a horizon of 1 reads the first projected value, not the last.
    public static let psiForecastLinear = ExcelFunction(
        name: "PSIFORECASTLINEAR", minArgs: 1, maxArgs: 2
    ) { values in
        guard let request = request(values, horizonIndex: 1) else { return .error(.value) }
        guard request.observations.count >= 2 else { return .error(.num) }
        var trend = LinearTrend<Double>()
        do {
            try trend.fit(values: request.observations)
        } catch {
            // A fit that cannot be made — every observation identical, so the slope is
            // undetermined. `#NUM!` is Excel's answer for a computation with no result.
            return .error(.num)
        }
        let projected = trend.projectValues(steps: request.horizon)
        guard let value = projected.last, value.isFinite else { return .error(.num) }
        return .number(value)
    }
}
