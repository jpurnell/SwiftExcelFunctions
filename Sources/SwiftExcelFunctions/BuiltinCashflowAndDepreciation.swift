import Foundation
import SwiftExcelCore
import BusinessMath

/// The `financial` rows that were bindable and unbound.
///
/// `MIRR`, `XNPV`, `CUMIPMT`, `CUMPRINC`, `DDB`, `RRI` and `PDURATION`.
///
/// ## Excel's sign convention, kept
///
/// Money paid out is negative and money received is positive, throughout. `CUMIPMT` and
/// `CUMPRINC` therefore return **negative** numbers for a loan, which surprises people and is
/// what Excel does; returning the magnitude would be friendlier and wrong.
public enum BuiltinCashflowAndDepreciation {

    /// Everything here, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        mirrFunc, xnpvFunc, cumipmt, cumprinc, ddb, rri, pduration
    ]

    // MARK: - Rates of return

    /// `MIRR(values, finance_rate, reinvest_rate)` — the modified internal rate of return.
    ///
    /// Bound to BusinessMath's `mirr`. Unlike `IRR` it has a closed form, because the two
    /// rates remove the polynomial: negatives are discounted at the finance rate and positives
    /// compounded at the reinvestment rate, and the answer is the ratio of the two.
    public static let mirrFunc = ExcelFunction(name: "MIRR", minArgs: 3, maxArgs: 3) { args in
        if let error = args.first(where: isError) { return error }
        let flows = flatten([args[0]]).compactMap(real)
        guard let finance = real(args[1]), let reinvest = real(args[2]) else {
            return .error(.value)
        }
        // Excel needs at least one of each sign; with none there is no rate to find.
        guard flows.contains(where: { $0 > 0 }), flows.contains(where: { $0 < 0 }) else {
            return .error(.div0)
        }
        do {
            return finite(try mirr(cashFlows: flows, financeRate: finance,
                                   reinvestmentRate: reinvest))
        } catch {
            return .error(.value)
        }
    }

    /// `XNPV(rate, values, dates)` — net present value over irregular dates.
    ///
    /// Bound to BusinessMath's `xnpv`. Excel's argument order puts the values before the
    /// dates and BusinessMath's takes dates first; the swap happens here, once.
    public static let xnpvFunc = ExcelFunction(name: "XNPV", minArgs: 3, maxArgs: 3) { args in
        if let error = args.first(where: isError) { return error }
        guard let rate = real(args[0]) else { return .error(.value) }
        let flows = flatten([args[1]]).compactMap(real)
        let dates = flatten([args[2]]).compactMap(date)
        guard flows.count == dates.count, !flows.isEmpty else { return .error(.num) }
        do {
            return finite(try xnpv(rate: rate, dates: dates, cashFlows: flows))
        } catch {
            return .error(.num)
        }
    }

    /// `RRI(nper, pv, fv)` — the rate an investment must earn to reach a value.
    ///
    /// The compound growth rate, which BusinessMath calls `cagr`. One period, one ratio:
    /// `(fv/pv)^(1/n) − 1`.
    public static let rri = ExcelFunction(name: "RRI", minArgs: 3, maxArgs: 3) { args in
        if let error = args.first(where: isError) { return error }
        guard let periods = real(args[0]), let present = real(args[1]),
              let future = real(args[2]) else { return .error(.value) }
        guard periods > 0, present != 0 else { return .error(.num) }
        let ratio = future / present
        guard ratio > 0 else { return .error(.num) }
        return finite(Foundation.pow(ratio, 1 / periods) - 1)
    }

    /// `PDURATION(rate, pv, fv)` — how many periods an investment needs.
    ///
    /// `RRI` rearranged for the period count instead of the rate.
    public static let pduration = ExcelFunction(
        name: "PDURATION", minArgs: 3, maxArgs: 3
    ) { args in
        if let error = args.first(where: isError) { return error }
        guard let rate = real(args[0]), let present = real(args[1]),
              let future = real(args[2]) else { return .error(.value) }
        guard rate > 0, present > 0, future > 0 else { return .error(.num) }
        return finite((Foundation.log(future) - Foundation.log(present))
                      / Foundation.log(1 + rate))
    }

    // MARK: - Cumulative payments

    /// `CUMIPMT(rate, nper, pv, start_period, end_period, type)` — interest paid over a span.
    public static let cumipmt = cumulative("CUMIPMT") { interest, _ in interest }

    /// `CUMPRINC(rate, nper, pv, start_period, end_period, type)` — principal repaid over one.
    public static let cumprinc = cumulative("CUMPRINC") { _, principal in principal }

    // MARK: - Depreciation

    /// `DDB(cost, salvage, life, period, [factor])` — double-declining-balance depreciation.
    ///
    /// The factor defaults to 2, which is what "double" means. **An instalment never takes the
    /// asset below salvage**, which is the rule that makes the last periods smaller than the
    /// formula alone would give — and the one an implementation forgets.
    public static let ddb = ExcelFunction(name: "DDB", minArgs: 4, maxArgs: 5) { args in
        if let error = args.first(where: isError) { return error }
        guard let cost = real(args[0]), let salvage = real(args[1]),
              let life = real(args[2]), let period = real(args[3]) else {
            return .error(.value)
        }
        let factor = args.count > 4 ? (real(args[4]) ?? 2) : 2
        guard cost >= 0, salvage >= 0, life > 0, period >= 1, period <= life, factor > 0 else {
            return .error(.num)
        }

        let rate = factor / life
        var remaining = cost
        var instalment = 0.0
        // Walked rather than closed-form, because the salvage floor makes each period depend
        // on the ones before it.
        for _ in 1...Int(period.rounded(.up)) {
            instalment = Swift.min(remaining * rate, Swift.max(0, remaining - salvage))
            remaining -= instalment
        }
        return finite(instalment)
    }

    // MARK: - Plumbing

    /// `CUMIPMT` and `CUMPRINC`, which walk the same schedule and report different halves.
    ///
    /// - Parameter pick: given a period's interest and principal, which one to accumulate.
    private static func cumulative(
        _ name: String, _ pick: @escaping @Sendable (Double, Double) -> Double
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 6, maxArgs: 6) { args in
            accumulate(args, pick)
        }
    }

    private static func accumulate(
        _ args: [CellValue], _ pick: (Double, Double) -> Double
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        guard let rate = real(args[0]), let periods = real(args[1]), let present = real(args[2]),
              let first = real(args[3]), let last = real(args[4]),
              let type = real(args[5]) else { return .error(.value) }
        guard rate > 0, periods > 0, present > 0, first >= 1, last >= first,
              last <= periods, type == 0 || type == 1 else { return .error(.num) }

        // The level payment, from the ordinary annuity formula.
        let growth = Foundation.pow(1 + rate, periods)
        guard growth != 1 else { return .error(.num) }
        var payment = -present * rate * growth / (growth - 1)
        if type == 1 { payment /= (1 + rate) }

        var balance = present
        var total = 0.0
        for period in 1...Int(last.rounded(.towardZero)) {
            // A payment at the start of the period earns no interest in it, which is the
            // whole of what `type` changes.
            let interest = (type == 1 && period == 1) ? 0 : -balance * rate
            let principal = payment - interest
            if Double(period) >= first { total += pick(interest, principal) }
            balance += principal
        }
        return finite(total)
    }

    private static func isError(_ value: CellValue) -> Bool {
        if case .error = value { return true }
        return false
    }

    private static func real(_ value: CellValue) -> Double? {
        BuiltinMathPrimitives.real(value)
    }

    private static func date(_ value: CellValue) -> Date? {
        guard let serial = real(value), serial >= 0 else { return nil }
        return BuiltinDateTimeFunctions.serialToDate(Int(serial))
    }

    private static func finite(_ value: Double) -> CellValue {
        value.isFinite ? .number(value) : .error(.num)
    }

    private static func flatten(_ args: [CellValue]) -> [CellValue] {
        var out: [CellValue] = []
        for value in args {
            if case .array(let matrix) = value {
                out.append(contentsOf: flatten(matrix.elements))
            } else {
                out.append(value)
            }
        }
        return out
    }
}
