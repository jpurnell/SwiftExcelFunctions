import Foundation
import SwiftExcelCore

/// Financial category built-in functions matching Excel's financial function library.
///
/// Provides implementations of common time-value-of-money, depreciation, and
/// investment analysis functions. All functions follow Excel sign conventions where
/// cash outflows are negative and inflows are positive.
public enum BuiltinFinancialFunctions {

    /// All financial functions available for registration.
    public static let all: [ExcelFunction] = [
        pmt, ipmt, ppmt, npv, irr, fv, pv, rate, nper, sln, db,
    ]

    // MARK: - Helpers

    /// Extracts a `Double` from a `CellValue`, returning `nil` for non-numeric types.
    private static func toNumber(_ value: CellValue) -> Double? {
        switch value {
        case .number(let n): return n
        case .bool(let b): return b ? 1.0 : 0.0
        case .blank: return 0.0
        case .text(let s): return Double(s)
        default: return nil
        }
    }

    /// Extracts a required `Double` argument or throws a `#VALUE!` error.
    private static func requireNumber(_ value: CellValue) throws -> Double {
        guard let n = toNumber(value) else {
            throw FinancialError.excelError(.value)
        }
        return n
    }

    /// Returns the numeric value of an optional argument, or a default if absent.
    private static func optionalNumber(
        _ args: [CellValue], at index: Int, default defaultValue: Double
    ) throws -> Double {
        guard index < args.count else { return defaultValue }
        return try requireNumber(args[index])
    }

    private static func safeDivide(_ numerator: Double, _ denominator: Double) -> Double? {
        if denominator == 0 { return nil }
        return numerator / denominator
    }

    // MARK: - PMT

    /// `PMT(rate, nper, pv, [fv], [type])` — Periodic payment for a loan or annuity.
    ///
    /// - Parameters:
    ///   - rate: Interest rate per period.
    ///   - nper: Total number of payment periods.
    ///   - pv: Present value (principal). Positive = amount owed to you; negative = amount you owe.
    ///   - fv: Future value (default 0). The balance you want after the last payment.
    ///   - type: 0 = end of period (default), 1 = beginning of period.
    /// - Returns: The periodic payment amount.
    public static let pmt = ExcelFunction(
        name: "PMT", minArgs: 3, maxArgs: 5
    ) { args in
        let r = try requireNumber(args[0])
        let n = try requireNumber(args[1])
        let presentValue = try requireNumber(args[2])
        let futureValue = try optionalNumber(args, at: 3, default: 0.0)
        let type = try optionalNumber(args, at: 4, default: 0.0)

        let result = computePMT(rate: r, nper: n, pv: presentValue, fv: futureValue, type: type)
        return .number(result)
    }

    /// Core PMT calculation shared with IPMT and PPMT.
    private static func computePMT(
        rate: Double, nper: Double, pv: Double, fv: Double, type: Double
    ) -> Double {
        if rate == 0 {
            return -(pv + fv) / nper
        }
        let pvif = pow(1.0 + rate, nper)
        var payment = rate * (pv * pvif + fv) / (pvif - 1.0)
        if type != 0 {
            payment /= (1.0 + rate)
        }
        return -payment
    }

    // MARK: - IPMT

    /// `IPMT(rate, per, nper, pv, [fv], [type])` — Interest portion of a payment for a given period.
    ///
    /// - Parameters:
    ///   - rate: Interest rate per period.
    ///   - per: The period for which to compute the interest (1-based).
    ///   - nper: Total number of payment periods.
    ///   - pv: Present value.
    ///   - fv: Future value (default 0).
    ///   - type: 0 = end of period (default), 1 = beginning of period.
    /// - Returns: The interest portion of the payment for the specified period.
    public static let ipmt = ExcelFunction(
        name: "IPMT", minArgs: 4, maxArgs: 6
    ) { args in
        let r = try requireNumber(args[0])
        let per = try requireNumber(args[1])
        let n = try requireNumber(args[2])
        let presentValue = try requireNumber(args[3])
        let futureValue = try optionalNumber(args, at: 4, default: 0.0)
        let type = try optionalNumber(args, at: 5, default: 0.0)

        guard per >= 1, per <= n else {
            return .error(.num)
        }

        let result = computeIPMT(
            rate: r, per: per, nper: n, pv: presentValue, fv: futureValue, type: type
        )
        return .number(result)
    }

    /// Core IPMT calculation.
    private static func computeIPMT(
        rate: Double, per: Double, nper: Double, pv: Double, fv: Double, type: Double
    ) -> Double {
        let payment = computePMT(rate: rate, nper: nper, pv: pv, fv: fv, type: type)

        if rate == 0 {
            return 0.0
        }

        // Calculate remaining balance at the start of the period
        var balance = pv
        let intPer = Int(per)
        if type != 0 {
            // Beginning of period: for period 1 the interest is 0
            if intPer == 1 {
                return 0.0
            }
            for _ in 1..<intPer {
                let interest = balance * rate
                balance += payment * (1.0 + rate) + interest
            }
            return balance * rate / (1.0 + rate)
        } else {
            // End of period
            for _ in 1..<intPer {
                let interest = balance * rate
                balance += payment + interest
            }
            return balance * rate
        }
    }

    // MARK: - PPMT

    /// `PPMT(rate, per, nper, pv, [fv], [type])` — Principal portion of a payment for a given period.
    ///
    /// The principal portion equals `PMT - IPMT` for any given period.
    ///
    /// - Parameters:
    ///   - rate: Interest rate per period.
    ///   - per: The period for which to compute the principal (1-based).
    ///   - nper: Total number of payment periods.
    ///   - pv: Present value.
    ///   - fv: Future value (default 0).
    ///   - type: 0 = end of period (default), 1 = beginning of period.
    /// - Returns: The principal portion of the payment for the specified period.
    public static let ppmt = ExcelFunction(
        name: "PPMT", minArgs: 4, maxArgs: 6
    ) { args in
        let r = try requireNumber(args[0])
        let per = try requireNumber(args[1])
        let n = try requireNumber(args[2])
        let presentValue = try requireNumber(args[3])
        let futureValue = try optionalNumber(args, at: 4, default: 0.0)
        let type = try optionalNumber(args, at: 5, default: 0.0)

        guard per >= 1, per <= n else {
            return .error(.num)
        }

        let payment = computePMT(rate: r, nper: n, pv: presentValue, fv: futureValue, type: type)
        let interest = computeIPMT(
            rate: r, per: per, nper: n, pv: presentValue, fv: futureValue, type: type
        )
        return .number(payment - interest)
    }

    // MARK: - NPV

    /// `NPV(rate, value1, [value2], ...)` — Net present value of a series of cash flows.
    ///
    /// Cash flows are assumed to occur at the end of each period, with the first value
    /// discounted at period 1 (not period 0).
    ///
    /// - Parameters:
    ///   - rate: The discount rate per period.
    ///   - values: One or more cash flow values.
    /// - Returns: The net present value.
    public static let npv = ExcelFunction(
        name: "NPV", minArgs: 2, maxArgs: nil
    ) { args in
        let r = try requireNumber(args[0])
        var total = 0.0
        for i in 1..<args.count {
            let cf = try requireNumber(args[i])
            total += cf / pow(1.0 + r, Double(i))
        }
        return .number(total)
    }

    // MARK: - IRR

    /// `IRR(values, [guess])` — Internal rate of return for a series of cash flows.
    ///
    /// Uses the Newton-Raphson method to find the rate at which NPV equals zero.
    /// Values must contain at least one positive and one negative cash flow.
    ///
    /// - Parameters:
    ///   - values: An array of cash flows. The first value is at period 0.
    ///   - guess: Initial guess for the rate (default 0.1).
    /// - Returns: The internal rate of return, or `#NUM!` if the solver does not converge.
    public static let irr = ExcelFunction(
        name: "IRR", minArgs: 1, maxArgs: 2
    ) { args in
        // Extract the cash flows — they can come as individual numbers or an array
        var cashFlows: [Double] = []

        switch args[0] {
        case .number(let n):
            cashFlows.append(n)
            // If passed as individual args, remaining args (except guess) are part of cash flows
            // But Excel IRR takes (values_array, [guess]) — values is a single range
            // For our evaluation, we accept an array CellValue or a single range
        default:
            break
        }

        // For the test interface, we expect args[0] to contain all cash flows
        // Let's handle both: array case and multi-arg case
        cashFlows = try extractCashFlows(from: args[0])

        let guess = args.count > 1 ? (toNumber(args[1]) ?? 0.1) : 0.1

        // Validate: must have at least one positive and one negative
        let hasPositive = cashFlows.contains(where: { $0 > 0 })
        let hasNegative = cashFlows.contains(where: { $0 < 0 })
        guard hasPositive, hasNegative, cashFlows.count >= 2 else {
            return .error(.num)
        }

        var x = guess
        let maxIterations = 100
        let tolerance = 1e-7

        for _ in 0..<maxIterations {
            var npvValue = 0.0
            var dnpv = 0.0
            for (i, cf) in cashFlows.enumerated() {
                let t = Double(i)
                let denom = pow(1.0 + x, t)
                if denom == 0 { return .error(.num) }
                npvValue += cf / denom
                if i > 0 {
                    dnpv -= t * cf / pow(1.0 + x, t + 1.0)
                }
            }
            if abs(npvValue) < tolerance {
                return .number(x)
            }
            guard let step = safeDivide(npvValue, dnpv) else { return .error(.num) }
            let newX = x - step
            if abs(newX - x) < tolerance {
                return .number(newX)
            }
            x = newX
        }
        return .error(.num)
    }

    /// Extracts an array of `Double` values from a `CellValue`.
    ///
    /// Handles both single numeric values and ``.array`` values containing multiple cash flows.
    private static func extractCashFlows(from value: CellValue) throws -> [Double] {
        switch value {
        case .array(let values):
            return try values.map { v in
                guard let n = toNumber(v) else {
                    throw FinancialError.excelError(.value)
                }
                return n
            }
        default:
            guard let n = toNumber(value) else {
                throw FinancialError.excelError(.value)
            }
            return [n]
        }
    }

    // MARK: - FV

    /// `FV(rate, nper, pmt, [pv], [type])` — Future value of an investment.
    ///
    /// - Parameters:
    ///   - rate: Interest rate per period.
    ///   - nper: Total number of payment periods.
    ///   - pmt: Payment made each period (negative for outflows).
    ///   - pv: Present value (default 0).
    ///   - type: 0 = end of period (default), 1 = beginning of period.
    /// - Returns: The future value.
    public static let fv = ExcelFunction(
        name: "FV", minArgs: 3, maxArgs: 5
    ) { args in
        let r = try requireNumber(args[0])
        let n = try requireNumber(args[1])
        let payment = try requireNumber(args[2])
        let presentValue = try optionalNumber(args, at: 3, default: 0.0)
        let type = try optionalNumber(args, at: 4, default: 0.0)

        let result: Double
        if r == 0 {
            result = -presentValue - payment * n
        } else {
            let pvif = pow(1.0 + r, n)
            let typeFactor = type != 0 ? (1.0 + r) : 1.0
            result = -presentValue * pvif - payment * ((pvif - 1.0) / r) * typeFactor
        }
        return .number(result)
    }

    // MARK: - PV

    /// `PV(rate, nper, pmt, [fv], [type])` — Present value of an investment.
    ///
    /// - Parameters:
    ///   - rate: Interest rate per period.
    ///   - nper: Total number of payment periods.
    ///   - pmt: Payment made each period.
    ///   - fv: Future value (default 0).
    ///   - type: 0 = end of period (default), 1 = beginning of period.
    /// - Returns: The present value.
    public static let pv = ExcelFunction(
        name: "PV", minArgs: 3, maxArgs: 5
    ) { args in
        let r = try requireNumber(args[0])
        let n = try requireNumber(args[1])
        let payment = try requireNumber(args[2])
        let futureValue = try optionalNumber(args, at: 3, default: 0.0)
        let type = try optionalNumber(args, at: 4, default: 0.0)

        let result: Double
        if r == 0 {
            result = -futureValue - payment * n
        } else {
            let pvif = pow(1.0 + r, n)
            let typeFactor = type != 0 ? (1.0 + r) : 1.0
            result = (-futureValue - payment * ((pvif - 1.0) / r) * typeFactor) / pvif
        }
        return .number(result)
    }

    // MARK: - RATE

    /// `RATE(nper, pmt, pv, [fv], [type], [guess])` — Interest rate per period for an annuity.
    ///
    /// Uses the Newton-Raphson iterative method to solve for the rate.
    ///
    /// - Parameters:
    ///   - nper: Total number of payment periods.
    ///   - pmt: Payment made each period.
    ///   - pv: Present value.
    ///   - fv: Future value (default 0).
    ///   - type: 0 = end of period (default), 1 = beginning of period.
    ///   - guess: Initial guess for the rate (default 0.1).
    /// - Returns: The interest rate per period, or `#NUM!` if the solver does not converge.
    public static let rate = ExcelFunction(
        name: "RATE", minArgs: 3, maxArgs: 6
    ) { args in
        let n = try requireNumber(args[0])
        let payment = try requireNumber(args[1])
        let presentValue = try requireNumber(args[2])
        let futureValue = try optionalNumber(args, at: 3, default: 0.0)
        let type = try optionalNumber(args, at: 4, default: 0.0)
        let guess = try optionalNumber(args, at: 5, default: 0.1)

        var x = guess
        let maxIterations = 100
        let tolerance = 1e-7

        for _ in 0..<maxIterations {
            if x <= -1.0 { return .error(.num) }
            let pvif = pow(1.0 + x, n)
            let typeFactor = type != 0 ? (1.0 + x) : 1.0

            // f(x) = pv * pvif + pmt * ((pvif - 1) / x) * typeFactor + fv = 0
            let f: Double
            let df: Double

            if abs(x) < 1e-12 {
                // Near zero, use linear approximation
                f = presentValue + payment * n * typeFactor + futureValue
                df = presentValue * n + payment * n * (n - 1.0) / 2.0
            } else {
                f = presentValue * pvif
                    + payment * ((pvif - 1.0) / x) * typeFactor
                    + futureValue

                let dpvif = n * pow(1.0 + x, n - 1.0)
                let dAnnuity = (dpvif * x - (pvif - 1.0)) / (x * x)
                let dtypeFactor = type != 0 ? 1.0 : 0.0

                df = presentValue * dpvif
                    + payment * dAnnuity * typeFactor
                    + payment * ((pvif - 1.0) / x) * dtypeFactor
            }

            if abs(f) < tolerance {
                return .number(x)
            }
            guard let step = safeDivide(f, df) else { return .error(.num) }
            let newX = x - step
            if abs(newX - x) < tolerance {
                return .number(newX)
            }
            x = newX
        }
        return .error(.num)
    }

    // MARK: - NPER

    /// `NPER(rate, pmt, pv, [fv], [type])` — Number of periods for an annuity.
    ///
    /// - Parameters:
    ///   - rate: Interest rate per period.
    ///   - pmt: Payment made each period.
    ///   - pv: Present value.
    ///   - fv: Future value (default 0).
    ///   - type: 0 = end of period (default), 1 = beginning of period.
    /// - Returns: The number of periods.
    public static let nper = ExcelFunction(
        name: "NPER", minArgs: 3, maxArgs: 5
    ) { args in
        let r = try requireNumber(args[0])
        let payment = try requireNumber(args[1])
        let presentValue = try requireNumber(args[2])
        let futureValue = try optionalNumber(args, at: 3, default: 0.0)
        let type = try optionalNumber(args, at: 4, default: 0.0)

        let result: Double
        if r == 0 {
            guard payment != 0 else { return .error(.num) }
            result = -(presentValue + futureValue) / payment
        } else {
            let typeFactor = type != 0 ? (1.0 + r) : 1.0
            let z = payment * typeFactor / r
            let numerator = -futureValue + z
            let denominator = presentValue + z
            guard denominator != 0, numerator / denominator > 0 else {
                return .error(.num)
            }
            result = log(numerator / denominator) / log(1.0 + r)
        }
        return .number(result)
    }

    // MARK: - SLN

    /// `SLN(cost, salvage, life)` — Straight-line depreciation for one period.
    ///
    /// - Parameters:
    ///   - cost: Initial cost of the asset.
    ///   - salvage: Value at the end of the depreciation period.
    ///   - life: Number of periods over which the asset is depreciated.
    /// - Returns: The depreciation amount per period.
    public static let sln = ExcelFunction(
        name: "SLN", minArgs: 3, maxArgs: 3
    ) { args in
        let cost = try requireNumber(args[0])
        let salvage = try requireNumber(args[1])
        let life = try requireNumber(args[2])

        guard life != 0 else { return .error(.div0) }
        return .number((cost - salvage) / life)
    }

    // MARK: - DB

    /// `DB(cost, salvage, life, period, [month])` — Declining balance depreciation.
    ///
    /// Uses the fixed declining balance method. The depreciation rate is computed as
    /// `1 - (salvage/cost)^(1/life)`, rounded to three decimal places.
    ///
    /// - Parameters:
    ///   - cost: Initial cost of the asset.
    ///   - salvage: Value at the end of the depreciation period.
    ///   - life: Number of periods over which the asset is depreciated.
    ///   - period: The period for which to calculate depreciation (1-based).
    ///   - month: Number of months in the first year (default 12).
    /// - Returns: The depreciation amount for the specified period.
    public static let db = ExcelFunction(
        name: "DB", minArgs: 4, maxArgs: 5
    ) { args in
        let cost = try requireNumber(args[0])
        let salvage = try requireNumber(args[1])
        let life = try requireNumber(args[2])
        let period = try requireNumber(args[3])
        let month = try optionalNumber(args, at: 4, default: 12.0)

        guard cost > 0, life > 0, period >= 1 else {
            return .error(.num)
        }

        let intPeriod = Int(period)
        let intLife = Int(life)

        // Calculate rate, rounded to 3 decimal places
        // cost > 0 and life > 0 are guaranteed by the guard above
        let rawRate: Double
        if salvage == 0 {
            rawRate = 1.0
        } else {
            guard let ratio = safeDivide(salvage, cost),
                  let invLife = safeDivide(1.0, life) else { return .error(.num) }
            rawRate = 1.0 - pow(ratio, invLife)
        }
        let dbRate = (rawRate * 1000.0).rounded() / 1000.0

        var accumulated = 0.0

        // First year: partial year based on month parameter
        let firstYearDepreciation = cost * dbRate * month / 12.0

        if intPeriod == 1 {
            return .number(firstYearDepreciation)
        }

        accumulated = firstYearDepreciation

        // Middle years (period 2 through life)
        for yr in 2...intPeriod {
            if yr <= intLife {
                let dep = (cost - accumulated) * dbRate
                if yr == intPeriod {
                    return .number(dep)
                }
                accumulated += dep
            } else if yr == intLife + 1 {
                // Last fractional year: remaining balance times rate times remaining months
                let dep = (cost - accumulated) * dbRate * (12.0 - month) / 12.0
                return .number(dep)
            }
        }

        return .error(.num)
    }
}

// MARK: - Internal Error Type

/// Internal error type used to propagate Excel errors through `throw`.
enum FinancialError: Error {
    /// Wraps an `ExcelError` for propagation via Swift error handling.
    case excelError(ExcelError)
}
