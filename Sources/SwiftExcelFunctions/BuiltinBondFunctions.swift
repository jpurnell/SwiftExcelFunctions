import Foundation
import BusinessMath
import SwiftExcelCore

/// Excel's bond functions, bound to BusinessMath's coupon grid.
///
/// Eleven functions, and between them exactly one idea: where does settlement sit
/// in the coupon schedule? Excel's own reference defines `PRICE`, `YIELD`,
/// `DURATION`, `MDURATION` and `ACCRINT` in terms of four quantities — `A`, `DSC`,
/// `E` and `N` — and then exposes those four quantities directly as `COUPDAYBS`,
/// `COUPDAYSNC`, `COUPDAYS` and `COUPNUM`. `BusinessMath.CouponPeriod` is that
/// grid, and every function here reads off it.
///
/// Nothing in this file computes a day count, walks a coupon schedule, or
/// discounts a cash flow. A second coupon grid in the same dependency chain could
/// disagree with the first, and the disagreement would surface as a price that was
/// wrong by a day's accrual — which is small enough to look like a rounding
/// difference and large enough to matter.
///
/// ## What was already upstream
///
/// All eleven were recorded in the coverage matrix as needing work. All eleven
/// were already answerable: `CouponPeriod` carries the six clock values as stored
/// properties, and `ExcelBondFunctions` implements `PRICE`, `YIELD`, `DURATION`
/// and `MDURATION` against Microsoft's published formulas by name. The work here
/// was argument marshalling and error mapping, not mathematics — the fifth time in
/// this project that "not implemented" turned out to mean "not implemented where I
/// looked."
public enum BuiltinBondFunctions {

    /// All bond functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        coupdaybs, coupdays, coupdaysnc, coupncd, coupnum, couppcd,
        price, yieldFunction, duration, mduration, accrint,
    ]

    // MARK: - Argument marshalling

    /// Parsed arguments, or the error to answer with.
    ///
    /// Not `Result`, because `ExcelError` is a value a cell can hold rather than a
    /// Swift error and does not conform to `Error` — which is the right way round.
    /// An Excel error is not an exception; it is an answer.
    private enum Parsed<Value> {
        case ok(Value)
        case bad(ExcelError)
    }

    /// A number, or `#VALUE!`.
    ///
    /// Blank counts as zero, which is Excel's coercion and not a convenience: an
    /// omitted optional argument arrives as `.blank`, and the callers below
    /// distinguish "absent" by index rather than by value.
    private static func number(_ value: CellValue) -> Double? {
        switch value {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        case .blank: return 0
        case .text(let s): return Double(s)
        default: return nil
        }
    }

    /// A date serial as a `Date`, going through the one conversion that knows about
    /// Excel's phantom 29 February 1900.
    private static func date(_ value: CellValue) -> Date? {
        guard let serial = number(value), serial >= 0 else { return nil }
        return BuiltinDateTimeFunctions.serialToDate(Int(serial))
    }

    /// Excel's frequency code. Annual, semi-annual and quarterly, and nothing else.
    ///
    /// `CouponPeriod` accepts monthly too, but Excel does not, and a `#NUM!` here is
    /// closer to the specification than an answer no spreadsheet would produce.
    private static func frequency(_ value: CellValue) -> PaymentFrequency? {
        switch number(value).map({ Int($0) }) {
        case 1: return .annual
        case 2: return .semiAnnual
        case 4: return .quarterly
        default: return nil
        }
    }

    /// Excel's basis code, mapped exactly as `YEARFRAC` maps it.
    private static func basis(_ args: [CellValue], at index: Int) -> DayCountConvention?? {
        guard index < args.count else { return .some(.thirty360) }
        guard let code = number(args[index]).map({ Int($0) }) else { return .none }
        switch code {
        case 0: return .some(.thirty360)
        case 1: return .some(.actualActual)
        case 2: return .some(.actual360)
        case 3: return .some(.actual365)
        case 4: return .some(.thirty360European)
        default: return .some(nil)
        }
    }

    /// Settlement, maturity, frequency and basis — the four arguments every clock
    /// function takes, in the order Excel takes them.
    ///
    /// Parses them; it does not build the grid. Every caller has the same four
    /// arguments in the same positions, so the parse belongs in one place: eleven
    /// copies of it would be eleven chances to map basis 4 to the wrong convention.
    private static func clockArguments(
        _ args: [CellValue]
    ) -> Parsed<(Date, Date, PaymentFrequency, DayCountConvention)> {
        guard let settlement = date(args[0]), let maturity = date(args[1]) else {
            return .bad(.value)
        }
        guard let freq = frequency(args[2]) else { return .bad(.num) }
        guard let outer = basis(args, at: 3) else { return .bad(.value) }
        guard let convention = outer else { return .bad(.num) }
        return .ok((settlement, maturity, freq, convention))
    }

    /// A clock function: four arguments in, one number off the located period.
    private static func clock(
        _ name: String, _ read: @Sendable @escaping (CouponPeriod<Double>) -> Double
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 3, maxArgs: 4) { args in
            switch clockArguments(args) {
            case .bad(let error): return .error(error)
            case .ok(let (settlement, maturity, freq, convention)):
                do {
                    let located = try CouponPeriod<Double>(
                        settlement: settlement, maturity: maturity,
                        frequency: freq, basis: convention)
                    return .number(read(located))
                } catch {
                    // `CouponPeriod` throws on settlement at or after maturity, and on
                    // a frequency that does not divide the year into whole months. The
                    // second cannot happen — 1, 2 and 4 all divide 12, and `frequency`
                    // admits nothing else. Both are `#NUM!` in Excel.
                    return .error(.num)
                }
            }
        }
    }

    // MARK: - The coupon clock

    /// `COUPDAYBS(settlement, maturity, frequency, [basis])` — days from the
    /// previous coupon to settlement.
    ///
    /// Excel's `A`: what the buyer owes the seller, measured in days. On a 30/360
    /// basis this is a nominal count and will not match a calendar subtraction.
    public static let coupdaybs = clock("COUPDAYBS") { $0.daysAccrued }

    /// `COUPDAYS(settlement, maturity, frequency, [basis])` — days in the coupon
    /// period containing settlement.
    ///
    /// Excel's `E`, and the one of the three that surprises people: under any basis
    /// with a fixed year length it is 360/frequency — a nominal 180 days for a
    /// semi-annual bond — however many days the calendar actually holds. Only the
    /// actual/actual conventions measure the period as long as it really is.
    public static let coupdays = clock("COUPDAYS") { $0.daysInPeriod }

    /// `COUPDAYSNC(settlement, maturity, frequency, [basis])` — days from
    /// settlement to the next coupon.
    ///
    /// Excel's `DSC`. `COUPDAYBS + COUPDAYSNC = COUPDAYS` on every basis.
    public static let coupdaysnc = clock("COUPDAYSNC") { $0.daysToNextCoupon }

    /// `COUPNUM(settlement, maturity, frequency, [basis])` — coupons still payable.
    ///
    /// Excel's `N`, counted between settlement and maturity inclusive of the
    /// redemption coupon.
    public static let coupnum = clock("COUPNUM") { Double($0.couponsRemaining) }

    /// `COUPPCD(settlement, maturity, frequency, [basis])` — the coupon date at or
    /// before settlement, as a date serial.
    public static let couppcd = clock("COUPPCD") {
        BuiltinDateTimeFunctions.dateToSerial($0.previousCouponDate)
    }

    /// `COUPNCD(settlement, maturity, frequency, [basis])` — the first coupon date
    /// after settlement, as a date serial.
    public static let coupncd = clock("COUPNCD") {
        BuiltinDateTimeFunctions.dateToSerial($0.nextCouponDate)
    }

    // MARK: - Price, yield and duration

    /// The four arguments `PRICE`, `YIELD`, `DURATION` and `MDURATION` share, plus
    /// the one that differs — a yield for three of them, a price for the other.
    ///
    /// All four take `(settlement, maturity, rate, x, [redemption,] frequency,
    /// [basis])`, and the only structural difference is that the price and yield
    /// pair carry a redemption where the duration pair does not. Parsing them apart
    /// once means the basis index is stated once.
    private static func bondArguments(
        _ args: [CellValue], hasRedemption: Bool
    ) -> Parsed<(Date, Date, Double, Double, Double, PaymentFrequency, DayCountConvention)> {
        let frequencyIndex = hasRedemption ? 5 : 4
        let basisIndex = frequencyIndex + 1

        guard let settlement = date(args[0]), let maturity = date(args[1]),
              let rate = number(args[2]), let subject = number(args[3]) else {
            return .bad(.value)
        }
        var redemption = 100.0
        if hasRedemption {
            guard let value = number(args[4]) else { return .bad(.value) }
            redemption = value
        }
        guard args.count > frequencyIndex, let freq = frequency(args[frequencyIndex]) else {
            return .bad(.num)
        }
        guard let outer = basis(args, at: basisIndex) else { return .bad(.value) }
        guard let convention = outer else { return .bad(.num) }
        guard settlement < maturity else { return .bad(.num) }

        return .ok((settlement, maturity, rate, subject, redemption, freq, convention))
    }

    /// `PRICE(settlement, maturity, rate, yld, redemption, frequency, [basis])` —
    /// the clean price per 100 of face value.
    ///
    /// Clean: the accrued interest is subtracted, because the buyer pays it
    /// separately. `PRICE` and `ACCRINT` therefore add up to what changes hands,
    /// and neither of them on its own is the settlement amount.
    public static let price = ExcelFunction(name: "PRICE", minArgs: 6, maxArgs: 7) { args in
        switch bondArguments(args, hasRedemption: true) {
        case .bad(let error): return .error(error)
        case .ok(let (settlement, maturity, rate, yield, redemption, freq, convention)):
            do {
                return .number(try bondPrice(
                    settlement: settlement, maturity: maturity, rate: rate, yield: yield,
                    redemption: redemption, frequency: freq, basis: convention))
            } catch {
                return .error(.num)
            }
        }
    }

    /// `YIELD(settlement, maturity, rate, pr, redemption, frequency, [basis])` —
    /// the yield implied by a price.
    ///
    /// The inverse of ``price``, found by bisection upstream. Named `yieldFunction`
    /// here because `yield` is a Swift keyword.
    public static let yieldFunction = ExcelFunction(name: "YIELD", minArgs: 6, maxArgs: 7) { args in
        switch bondArguments(args, hasRedemption: true) {
        case .bad(let error): return .error(error)
        case .ok(let (settlement, maturity, rate, priceValue, redemption, freq, convention)):
            do {
                return .number(try bondYield(
                    settlement: settlement, maturity: maturity, rate: rate, price: priceValue,
                    redemption: redemption, frequency: freq, basis: convention))
            } catch {
                return .error(.num)
            }
        }
    }

    /// `DURATION(settlement, maturity, coupon, yld, frequency, [basis])` — Macaulay
    /// duration, in years.
    ///
    /// The cash-flow-weighted average time to payment. No redemption argument: it
    /// is 100 by definition here, which is why this signature is one shorter than
    /// `PRICE`'s and why the frequency sits at a different index.
    public static let duration = ExcelFunction(name: "DURATION", minArgs: 5, maxArgs: 6) { args in
        switch bondArguments(args, hasRedemption: false) {
        case .bad(let error): return .error(error)
        case .ok(let (settlement, maturity, rate, yield, _, freq, convention)):
            do {
                return .number(try bondDuration(
                    settlement: settlement, maturity: maturity, rate: rate, yield: yield,
                    frequency: freq, basis: convention))
            } catch {
                return .error(.num)
            }
        }
    }

    /// `MDURATION(settlement, maturity, coupon, yld, frequency, [basis])` — modified
    /// duration, in years.
    ///
    /// `DURATION / (1 + yld/frequency)`, which is the price's sensitivity to yield
    /// rather than a time. Microsoft states the relation, and it is the identity the
    /// binding tests check.
    public static let mduration = ExcelFunction(name: "MDURATION", minArgs: 5, maxArgs: 6) { args in
        switch bondArguments(args, hasRedemption: false) {
        case .bad(let error): return .error(error)
        case .ok(let (settlement, maturity, rate, yield, _, freq, convention)):
            do {
                return .number(try bondModifiedDuration(
                    settlement: settlement, maturity: maturity, rate: rate, yield: yield,
                    frequency: freq, basis: convention))
            } catch {
                return .error(.num)
            }
        }
    }

    // MARK: - Accrued interest

    /// `ACCRINT(issue, first_interest, settlement, rate, par, frequency, [basis],
    /// [calc_method])` — interest accrued on a bond that pays periodic interest.
    ///
    /// Three dates rather than two, and the middle one is the surprise: the first
    /// interest date fixes the *phase* of the coupon grid, which issue and
    /// settlement between them do not. A bond issued mid-period accrues from issue
    /// but on the grid the first coupon establishes.
    ///
    /// `par` defaults to 1,000 — Excel's default, and worth stating because a blank
    /// coerces to zero everywhere else in this file, which here would silently
    /// answer zero.
    ///
    /// ## `calc_method` is accepted and ignored
    ///
    /// Excel's eighth argument chooses, when settlement precedes the first interest
    /// date, whether to accrue from issue (`TRUE`, the default) or from the last
    /// coupon (`FALSE`). BusinessMath accrues from issue, which is the default and
    /// the overwhelmingly common case. Passing `FALSE` currently gets the `TRUE`
    /// answer rather than an error — a known and deliberate gap, recorded here
    /// rather than hidden, and one that needs an upstream parameter to close.
    public static let accrint = ExcelFunction(name: "ACCRINT", minArgs: 6, maxArgs: 8) { args in
        guard let issue = date(args[0]), let firstInterest = date(args[1]),
              let settlement = date(args[2]), let rate = number(args[3]) else {
            return .error(.value)
        }
        // A blank par is an omitted par, and Excel's omitted par is 1,000.
        let par: Double
        switch args[4] {
        case .blank: par = 1000
        case let value:
            guard let parsed = number(value) else { return .error(.value) }
            par = parsed == 0 ? 1000 : parsed
        }
        guard let freq = frequency(args[5]) else { return .error(.num) }
        guard let outer = basis(args, at: 6) else { return .error(.value) }
        guard let convention = outer else { return .error(.num) }

        do {
            return .number(try accruedInterest(
                issue: issue, firstInterest: firstInterest, settlement: settlement,
                rate: rate, par: par, frequency: freq, basis: convention))
        } catch {
            return .error(.num)
        }
    }
}
