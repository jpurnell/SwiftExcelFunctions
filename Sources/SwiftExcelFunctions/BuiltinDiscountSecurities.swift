import Foundation
import SwiftExcelCore
import BusinessMath

/// Discount securities, Treasury bills, and the odd ones out.
///
/// The seventeen `financial` rows that have a closed form. Every one is a rearrangement of
/// the same relationship — *price*, *redemption*, *rate* and *time* — and what separates them
/// is which of the four is the unknown and how time is counted.
///
/// ## Two families that look alike and are not
///
/// **Discount** securities quote a rate against the *redemption* value: `DISC`, `PRICEDISC`,
/// `YIELDDISC`. **Investment** securities quote against the *price paid*: `INTRATE`,
/// `RECEIVED`, `PRICEMAT`, `YIELDMAT`. Same arithmetic, different denominator, and using one
/// where the other belongs gives an answer that is wrong by a few basis points — the kind of
/// error that looks like rounding and is not.
///
/// ## Treasury bills count days their own way
///
/// `TBILLEQ`, `TBILLPRICE` and `TBILLYIELD` use **actual/360** with the maturity capped at a
/// year, and do not take a `basis` argument at all. That is the market convention rather than
/// a simplification, and it is why they are not expressible through the general functions
/// above them.
public enum BuiltinDiscountSecurities {

    /// Every function here, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        disc, priceDisc, yieldDisc, intRate, received, priceMat, yieldMat, accrintM,
        tbillEq, tbillPrice, tbillYield, dollarDe, dollarFr, fvSchedule, ispmt,
        amorLinc, amorDegrc
    ]

    // MARK: - Discount securities

    /// `DISC(settlement, maturity, pr, redemption, [basis])` — the discount rate.
    public static let disc = security("DISC", minArgs: 4) { time, price, redemption in
        guard redemption != 0, time != 0 else { return nil }
        return (redemption - price) / redemption / time
    }

    /// `PRICEDISC(settlement, maturity, discount, redemption, [basis])` — price from a rate.
    public static let priceDisc = security("PRICEDISC", minArgs: 4) { time, rate, redemption in
        redemption - rate * redemption * time
    }

    /// `YIELDDISC(settlement, maturity, pr, redemption, [basis])` — the annual yield.
    ///
    /// Against the **price paid**, where `DISC` measures against the redemption value. The
    /// two answer different questions about the same security and neither is a rounding of
    /// the other.
    public static let yieldDisc = security("YIELDDISC", minArgs: 4) { time, price, redemption in
        guard price != 0, time != 0 else { return nil }
        return (redemption - price) / price / time
    }

    /// `INTRATE(settlement, maturity, investment, redemption, [basis])` — the interest rate.
    public static let intRate = security("INTRATE", minArgs: 4) { time, investment, redemption in
        guard investment != 0, time != 0 else { return nil }
        return (redemption - investment) / investment / time
    }

    /// `RECEIVED(settlement, maturity, investment, discount, [basis])` — the maturity value.
    public static let received = security("RECEIVED", minArgs: 4) { time, investment, rate in
        let discount = 1 - rate * time
        guard discount != 0 else { return nil }
        return investment / discount
    }

    // MARK: - Interest at maturity

    /// `PRICEMAT(settlement, maturity, issue, rate, yld, [basis])` — price of a security
    /// that pays its interest at maturity.
    ///
    /// Three dates, not two: issue, settlement and maturity. The security accrues from
    /// *issue* and is bought at *settlement*, so the buyer pays for the accrual already
    /// earned — which is the term subtracted at the end and the thing that makes this
    /// different from `PRICEDISC`.
    public static let priceMat = ExcelFunction(
        name: "PRICEMAT", minArgs: 5, maxArgs: 6
    ) { args in
        atMaturity(args) { issueToSettlement, issueToMaturity, settlementToMaturity, rate, yld in
            let denominator = 1 + settlementToMaturity * yld
            guard denominator != 0 else { return nil }
            let redemption = 100 + issueToMaturity * rate * 100
            return redemption / denominator - issueToSettlement * rate * 100
        }
    }

    /// `YIELDMAT(settlement, maturity, issue, rate, pr, [basis])` — its annual yield.
    public static let yieldMat = ExcelFunction(
        name: "YIELDMAT", minArgs: 5, maxArgs: 6
    ) { args in
        atMaturity(args) { issueToSettlement, issueToMaturity, settlementToMaturity, rate, price in
            let accrued = issueToSettlement * rate
            let paid = price / 100 + accrued
            guard paid != 0, settlementToMaturity != 0 else { return nil }
            let redemption = 1 + issueToMaturity * rate
            return (redemption / paid - 1) / settlementToMaturity
        }
    }

    /// `ACCRINTM(issue, settlement, rate, par, [basis])` — interest accrued to settlement.
    ///
    /// The maturity-paying sibling of `ACCRINT`. Par defaults to 1,000, which is Excel's
    /// default and not a rounding of it.
    public static let accrintM = ExcelFunction(
        name: "ACCRINTM", minArgs: 3, maxArgs: 5
    ) { args in
        if let error = args.first(where: isError) { return error }
        guard let issue = date(args[0]), let settlement = date(args[1]),
              let rate = number(args[2]), let convention = basis(args, at: 4) else {
            return .error(.value)
        }
        let par = args.count > 3 ? (number(args[3]) ?? 1_000) : 1_000
        guard rate > 0, par > 0, issue < settlement else { return .error(.num) }
        let fraction: Double = convention.yearFraction(from: issue, to: settlement)
        return .number(par * rate * fraction)
    }

    // MARK: - Treasury bills

    /// `TBILLPRICE(settlement, maturity, discount)` — price per $100 face value.
    ///
    /// Actual/360 and no `basis` argument: the bill market counts days its own way, and
    /// Excel follows it.
    public static let tbillPrice = bill("TBILLPRICE") { days, rate in
        let discount = rate * days / 360
        guard discount < 1 else { return nil }
        return 100 * (1 - discount)
    }

    /// `TBILLYIELD(settlement, maturity, pr)` — the yield, against the price paid.
    public static let tbillYield = bill("TBILLYIELD") { days, price in
        guard price > 0, days > 0 else { return nil }
        return (100 - price) / price * (360 / days)
    }

    /// `TBILLEQ(settlement, maturity, discount)` — the bond-equivalent yield.
    ///
    /// The number that lets a bill be compared with a coupon bond, which is why it exists.
    /// Excel's published form is `365 × rate / (360 − rate × days)`, and it is *not* the same
    /// as the discount rate — a bill quoted at 9.14% is equivalent to about 9.42%.
    public static let tbillEq = bill("TBILLEQ") { days, rate in
        let denominator = 360 - rate * days
        guard denominator != 0 else { return nil }
        return 365 * rate / denominator
    }

    // MARK: - Dollar fractions

    /// `DOLLARDE(fractional_dollar, fraction)` — sixteenths and the like, as a decimal.
    ///
    /// `DOLLARDE(1.02, 16)` is 1.125: the `.02` is *two sixteenths*, not two hundredths. The
    /// fraction is truncated to a whole number, and one below 1 is `#NUM!`.
    public static let dollarDe = ExcelFunction(
        name: "DOLLARDE", minArgs: 2, maxArgs: 2
    ) { args in
        fractionalDollar(args) { value, fraction, digits in
            let whole = value < 0 ? value.rounded(.up) : value.rounded(.down)
            let part = (value - whole) * Foundation.pow(10, digits)
            return whole + part / fraction
        }
    }

    /// `DOLLARFR(decimal_dollar, fraction)` — a decimal as sixteenths and the like.
    public static let dollarFr = ExcelFunction(
        name: "DOLLARFR", minArgs: 2, maxArgs: 2
    ) { args in
        fractionalDollar(args) { value, fraction, digits in
            let whole = value < 0 ? value.rounded(.up) : value.rounded(.down)
            let part = (value - whole) * fraction
            return whole + part / Foundation.pow(10, digits)
        }
    }

    // MARK: - The rest

    /// `FVSCHEDULE(principal, schedule)` — a principal compounded through varying rates.
    ///
    /// A blank in the schedule is a zero rate — the period happened and paid nothing — which
    /// is Excel's reading and differs from skipping the period.
    public static let fvSchedule = ExcelFunction(
        name: "FVSCHEDULE", minArgs: 2, maxArgs: 2
    ) { args in
        if let error = args.first(where: isError) { return error }
        guard let principal = number(args[0]) else { return .error(.value) }
        var value = principal
        for rate in flatten([args[1]]) {
            if case .blank = rate { continue }
            guard let each = number(rate) else { return .error(.value) }
            value *= 1 + each
        }
        return finite(value)
    }

    /// `ISPMT(rate, per, nper, pv)` — interest paid in a period, with **level principal**.
    ///
    /// Not `IPMT`, and the difference is the whole of it: `IPMT` assumes a level *payment*
    /// and `ISPMT` a level *principal*, so the balances differ from the first period on.
    /// Excel's sign convention is kept — a loan's interest is negative.
    public static let ispmt = ExcelFunction(name: "ISPMT", minArgs: 4, maxArgs: 4) { args in
        if let error = args.first(where: isError) { return error }
        guard let rate = number(args[0]), let period = number(args[1]),
              let periods = number(args[2]), let present = number(args[3]) else {
            return .error(.value)
        }
        guard periods != 0 else { return .error(.div0) }
        return finite(present * rate * (period / periods - 1))
    }

    // MARK: - French depreciation

    /// `AMORLINC(cost, date_purchased, first_period, salvage, period, rate, [basis])`.
    ///
    /// The French accounting system's linear depreciation. An asset bought part-way through
    /// a period depreciates **pro rata** in that first period, which is the only thing
    /// separating this from ordinary straight-line — and the reason the purchase date and
    /// the period end are both arguments.
    public static let amorLinc = ExcelFunction(
        name: "AMORLINC", minArgs: 6, maxArgs: 7
    ) { args in
        amortised(args) { cost, rate, firstFraction, salvage, period in
            let full = cost * rate
            guard period > 0 else { return cost * rate * firstFraction }
            // Each later period takes a full instalment, until what is left reaches salvage.
            let taken = cost * rate * firstFraction + full * Double(period - 1)
            let remaining = cost - salvage - taken
            guard remaining > 0 else { return 0 }
            return Swift.min(full, remaining)
        }
    }

    /// `AMORDEGRC(…)` — the same, with France's declining-balance coefficient.
    ///
    /// The coefficient depends on the asset's life: 1.5 for three or four years, 2 for five
    /// or six, 2.5 beyond. Life is derived as `1 / rate`, which is how Excel reads it, and
    /// the last two periods are forced to 50% of what remains — both are in the specification
    /// rather than conventions chosen here.
    public static let amorDegrc = ExcelFunction(
        name: "AMORDEGRC", minArgs: 6, maxArgs: 7
    ) { args in
        amortised(args) { cost, rate, firstFraction, salvage, period in
            guard rate > 0 else { return 0 }
            let life = 1 / rate
            let coefficient: Double
            switch life {
            case ..<3: coefficient = 1
            case ..<5: coefficient = 1.5
            case ..<6: coefficient = 2
            default: coefficient = 2.5
            }
            let degressive = Swift.min(rate * coefficient, 1)

            var remaining = cost
            var instalment = cost * degressive * firstFraction
            for _ in 0..<period {
                remaining -= instalment
                instalment = remaining * degressive
            }
            let floorValue = Swift.max(salvage, 0)
            return Swift.max(0, Swift.min(instalment, remaining - floorValue))
        }
    }

    // MARK: - Plumbing

    private static func isError(_ value: CellValue) -> Bool {
        if case .error = value { return true }
        return false
    }

    private static func number(_ value: CellValue) -> Double? {
        switch value {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .blank: return 0
        case .text(let s): return Double(s)
        default: return nil
        }
    }

    private static func date(_ value: CellValue) -> Date? {
        guard let serial = number(value), serial >= 0 else { return nil }
        return BuiltinDateTimeFunctions.serialToDate(Int(serial))
    }

    /// Excel's basis code, mapped as `YEARFRAC` maps it.
    private static func basis(_ args: [CellValue], at index: Int) -> DayCountConvention? {
        guard index < args.count else { return .thirty360 }
        guard let code = number(args[index]).map({ Int($0) }) else { return nil }
        switch code {
        case 0: return .thirty360
        case 1: return .actualActual
        case 2: return .actual360
        case 3: return .actual365
        case 4: return .thirty360European
        default: return nil
        }
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

    /// `settlement, maturity, x, y, [basis]` — the shape five of these share.
    ///
    /// - Parameter body: given the year fraction and the two money arguments, the answer.
    private static func security(
        _ name: String, minArgs: Int,
        _ body: @escaping @Sendable (Double, Double, Double) -> Double?
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: minArgs, maxArgs: minArgs + 1) { args in
            evaluateSecurity(args, body)
        }
    }

    /// The body of a discount-security function, lifted out of the closure.
    ///
    /// Written as a function rather than inline because the type-checker could not infer the
    /// closure's overload with this much in it — and a closure the compiler cannot type is
    /// one a reader has to hold in their head too.
    private static func evaluateSecurity(
        _ args: [CellValue], _ body: (Double, Double, Double) -> Double?
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        guard let settlement = date(args[0]), let maturity = date(args[1]),
              let first = number(args[2]), let second = number(args[3]),
              let convention = basis(args, at: 4) else { return .error(.value) }
        guard settlement < maturity, first > 0, second > 0 else { return .error(.num) }

        // Annotated, as `YEARFRAC`'s own call site is: the method is generic over its
        // floating-point result and cannot be inferred from use here.
        let time: Double = convention.yearFraction(from: settlement, to: maturity)
        guard let result = body(time, first, second) else { return .error(.num) }
        return finite(result)
    }

    /// `settlement, maturity, x` with actual/360 days — the Treasury-bill shape.
    private static func bill(
        _ name: String, _ body: @escaping @Sendable (Double, Double) -> Double?
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 3, maxArgs: 3) { args in
            evaluateBill(args, body)
        }
    }

    /// The body of a Treasury-bill function, lifted out for the same reason.
    private static func evaluateBill(
        _ args: [CellValue], _ body: (Double, Double) -> Double?
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        guard let settlement = date(args[0]), let maturity = date(args[1]),
              let third = number(args[2]) else { return .error(.value) }
        guard settlement < maturity, third > 0 else { return .error(.num) }

        let days = (maturity.timeIntervalSince(settlement) / 86_400).rounded()
        // Excel refuses a bill more than a year out — beyond that it is not a bill, and the
        // actual/360 convention stops being the right one.
        guard days > 0, days <= 366 else { return .error(.num) }
        guard let result = body(days, third) else { return .error(.num) }
        return finite(result)
    }

    /// `PRICEMAT` and `YIELDMAT`, which share three dates and two rates.
    private static func atMaturity(
        _ args: [CellValue],
        _ body: (Double, Double, Double, Double, Double) -> Double?
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        guard let settlement = date(args[0]), let maturity = date(args[1]),
              let issue = date(args[2]), let rate = number(args[3]),
              let fifth = number(args[4]), let convention = basis(args, at: 5) else {
            return .error(.value)
        }
        guard settlement < maturity, issue < settlement, rate >= 0, fifth > 0 else {
            return .error(.num)
        }
        let issueToSettlement: Double = convention.yearFraction(from: issue, to: settlement)
        let issueToMaturity: Double = convention.yearFraction(from: issue, to: maturity)
        let settlementToMaturity: Double = convention.yearFraction(from: settlement, to: maturity)
        guard let result = body(issueToSettlement, issueToMaturity, settlementToMaturity,
                                rate, fifth) else { return .error(.num) }
        return finite(result)
    }

    /// `DOLLARDE` and `DOLLARFR`, which differ only in direction.
    private static func fractionalDollar(
        _ args: [CellValue], _ body: (Double, Double, Double) -> Double
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        guard let value = number(args[0]), let given = number(args[1]) else {
            return .error(.value)
        }
        let fraction = given.rounded(.towardZero)
        guard fraction >= 1 else { return .error(.num) }
        // How many decimal places the fractional part occupies: sixteenths need two, so
        // `1.02` reads as two sixteenths rather than as two tenths.
        let digits = Foundation.floor(Foundation.log10(fraction)) + 1
        return finite(body(value, fraction, digits))
    }

    /// The French depreciation pair, which share seven arguments and a first-period rule.
    private static func amortised(
        _ args: [CellValue], _ body: (Double, Double, Double, Double, Int) -> Double
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        guard let cost = number(args[0]), let purchased = date(args[1]),
              let firstPeriodEnd = date(args[2]), let salvage = number(args[3]),
              let periodValue = number(args[4]), let rate = number(args[5]),
              let convention = basis(args, at: 6) else { return .error(.value) }
        guard cost >= 0, rate > 0, purchased <= firstPeriodEnd else { return .error(.num) }

        let period = Int(periodValue.rounded(.towardZero))
        guard period >= 0 else { return .error(.num) }
        // The pro-rata share of the first period, which is the whole reason these two
        // functions exist rather than reusing `SLN` and `DB`.
        let firstFraction: Double = convention.yearFraction(
            from: purchased, to: firstPeriodEnd)
        return finite(body(cost, rate, firstFraction, salvage, period))
    }
}
