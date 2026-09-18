import Foundation
import SwiftExcelCore
import BusinessMath

/// Bonds whose first or last coupon period is not a whole one.
///
/// `ODDFPRICE`, `ODDFYIELD`, `ODDLPRICE`, `ODDLYIELD` — the last four `financial` rows.
///
/// ## Quasi-coupon periods
///
/// A regular bond's price discounts each coupon by whole periods. An odd bond has a stub at
/// one end, and Excel handles it by inventing **quasi-coupon periods**: the coupon dates the
/// bond *would* have had if the stub were regular, counted backwards from the first real
/// coupon or forwards from the last. The stub is then measured as a fraction of those.
///
/// That is the whole of what makes these four different from `PRICE` and `YIELD`, and it is
/// why they cannot be expressed through them.
///
/// ## Odd last is a sum; odd first is a discount chain
///
/// `ODDLPRICE` and `ODDLYIELD` have no regular periods left — settlement is inside the final
/// stub — so the price is one discounted redemption plus accrued interest, and the yield
/// inverts that in closed form. `ODDFPRICE` and `ODDFYIELD` have a stub *and* a run of
/// regular coupons after it, so each cash flow is discounted separately and the yield is
/// found by search rather than by rearrangement.
public enum BuiltinOddPeriodBonds {

    /// Every function here, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        oddLPrice, oddLYield, oddFPrice, oddFYield
    ]

    // MARK: - Odd last period

    /// `ODDLPRICE(settlement, maturity, last_interest, rate, yld, redemption, frequency, [basis])`.
    public static let oddLPrice = ExcelFunction(
        name: "ODDLPRICE", minArgs: 7, maxArgs: 8
    ) { args in
        oddLast(args) { odd, rate, yld, redemption, periodsPerYear in
            let perPeriod = rate * 100 / periodsPerYear
            let discount = 1 + odd.discount * yld / periodsPerYear
            guard discount != 0 else { return nil }
            // One payment left — redemption plus everything the odd period earned —
            // discounted across what remains of it, less the seller's accrued share.
            return (redemption + odd.coupon * perPeriod) / discount - odd.accrued * perPeriod
        }
    }

    /// `ODDLYIELD(settlement, maturity, last_interest, rate, pr, redemption, frequency, [basis])`.
    ///
    /// The inverse of ``oddLPrice`` and available in closed form, because a single remaining
    /// payment makes the price linear in the yield.
    public static let oddLYield = ExcelFunction(
        name: "ODDLYIELD", minArgs: 7, maxArgs: 8
    ) { args in
        oddLast(args) { odd, rate, price, redemption, periodsPerYear in
            let perPeriod = rate * 100 / periodsPerYear
            let paid = price + odd.accrued * perPeriod
            guard paid != 0, odd.discount != 0 else { return nil }
            return ((redemption + odd.coupon * perPeriod) / paid - 1)
                * periodsPerYear / odd.discount
        }
    }

    // MARK: - Odd first period

    /// `ODDFPRICE(settlement, maturity, issue, first_coupon, rate, yld, redemption, frequency, [basis])`.
    public static let oddFPrice = ExcelFunction(
        name: "ODDFPRICE", minArgs: 8, maxArgs: 9
    ) { args in
        oddFirst(args) { terms, yld in
            price(of: terms, at: yld)
        }
    }

    /// `ODDFYIELD(settlement, maturity, issue, first_coupon, rate, pr, redemption, frequency, [basis])`.
    ///
    /// Found by bisection rather than rearranged. A bond with a stub and a run of regular
    /// coupons has no closed-form yield — the price is a polynomial in the discount factor —
    /// and every implementation searches. Bisection rather than Newton because the bracket is
    /// known and a bracketed method cannot wander off a bond's flat regions.
    public static let oddFYield = ExcelFunction(
        name: "ODDFYIELD", minArgs: 8, maxArgs: 9
    ) { args in
        oddFirst(args) { terms, target in
            // Price falls monotonically in yield, so a sign change brackets the answer.
            var low = -0.99, high = 10.0
            guard let atLow = price(of: terms, at: low), let atHigh = price(of: terms, at: high),
                  (atLow - target) * (atHigh - target) <= 0 else { return nil }

            // 200 halvings takes the bracket far below any precision a price carries; the
            // tolerance exits long before that and the count is only a guarantee of ending.
            for _ in 0..<200 {
                let middle = (low + high) / 2
                guard let value = price(of: terms, at: middle) else { return nil }
                if Swift.abs(value - target) < 1e-10 { return middle }
                if (value - target) > 0 { low = middle } else { high = middle }
            }
            return (low + high) / 2
        }
    }

    // MARK: - The odd-first cash flows

    /// What an odd-first bond pays, and when, measured in coupon periods from settlement.
    private struct Terms {
        /// Each payment, with the number of periods from settlement to it.
        let flows: [(periods: Double, amount: Double)]
        /// Interest already earned by the seller.
        let accrued: Double
        let periodsPerYear: Double
    }

    /// The price of those flows at a yield, less accrued interest.
    private static func price(of terms: Terms, at yield: Double) -> Double? {
        let rate = 1 + yield / terms.periodsPerYear
        guard rate > 0 else { return nil }
        var total = 0.0
        for flow in terms.flows {
            total += flow.amount / Foundation.pow(rate, flow.periods)
        }
        guard total.isFinite else { return nil }
        return total - terms.accrued
    }

    // MARK: - Argument shapes

    /// What the odd last period comes to, in coupons.
    private struct OddLast {
        /// How much of a coupon the whole odd period earns.
        let coupon: Double
        /// The seller's share of it, up to settlement.
        let accrued: Double
        /// How far the single remaining payment is discounted, in periods.
        let discount: Double
    }

    /// `ODDLPRICE` and `ODDLYIELD`, which share eight arguments and a stub at the end.
    ///
    /// **The odd last period is measured in quasi-coupon periods, not as one fraction.**
    /// A last period running eight months on a semi-annual bond covers one whole quasi-period
    /// and a third of another, so it earns 1⅓ coupons — not the ⅔ of one that the
    /// settlement-to-maturity fraction suggests. Collapsing it to a single fraction priced
    /// Microsoft's example 1.15 points light, which is not a rounding.
    private static func oddLast(
        _ args: [CellValue],
        _ body: (OddLast, Double, Double, Double, Double) -> Double?
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        guard let settlement = date(args[0]), let maturity = date(args[1]),
              let lastInterest = date(args[2]), let rate = number(args[3]),
              let fifth = number(args[4]), let redemption = number(args[5]),
              let frequency = number(args[6]).map({ Int($0) }),
              [1, 2, 4].contains(frequency),
              let convention = basis(args, at: 7) else { return .error(.value) }
        guard lastInterest < settlement, settlement < maturity,
              rate >= 0, fifth > 0, redemption > 0 else { return .error(.num) }

        var coupon = 0.0, accrued = 0.0, discount = 0.0
        for period in quasiPeriods(endingAt: maturity, coveringFrom: lastInterest,
                                   frequency: frequency) {
            let length: Double = convention.yearFraction(from: period.start, to: period.end)
            guard length > 0 else { continue }

            // The odd period may start part-way into the earliest quasi-period.
            let from = Swift.max(period.start, lastInterest)
            let earns: Double = convention.yearFraction(from: from, to: period.end)
            coupon += earns / length

            if settlement > from {
                let elapsed: Double = convention.yearFraction(
                    from: from, to: Swift.min(settlement, period.end))
                accrued += elapsed / length
            }
            if settlement < period.end {
                let remaining: Double = convention.yearFraction(
                    from: Swift.max(settlement, period.start), to: period.end)
                discount += remaining / length
            }
        }

        let odd = OddLast(coupon: coupon, accrued: accrued, discount: discount)
        guard let result = body(odd, rate, fifth, redemption, Double(frequency)) else {
            return .error(.num)
        }
        return finite(result)
    }

    /// The quasi-coupon periods of an odd last period.
    ///
    /// Counted **backwards from maturity**, because that is where the schedule is anchored:
    /// the coupon dates the bond would have had run back from its redemption, and the odd
    /// period is however much of them the last real coupon left over.
    private static func quasiPeriods(
        endingAt maturity: Date, coveringFrom start: Date, frequency: Int
    ) -> [(start: Date, end: Date)] {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return [] }
        calendar.timeZone = utc

        let months = 12 / frequency
        var periods: [(start: Date, end: Date)] = []
        var end = maturity
        // Bounded: each step moves back at least a month, and the loop stops once the period
        // reaches past the odd period's start. The cap is a backstop, not a limit.
        while periods.count < 4_000 {
            guard let begin = calendar.date(byAdding: .month, value: -months, to: end) else {
                break
            }
            periods.append((begin, end))
            if begin <= start { break }
            end = begin
        }
        return periods.reversed()
    }

    /// `ODDFPRICE` and `ODDFYIELD`, which share nine arguments and a stub at the start.
    private static func oddFirst(
        _ args: [CellValue], _ body: (Terms, Double) -> Double?
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        guard let settlement = date(args[0]), let maturity = date(args[1]),
              let issue = date(args[2]), let firstCoupon = date(args[3]),
              let rate = number(args[4]), let sixth = number(args[5]),
              let redemption = number(args[6]),
              let frequency = number(args[7]).map({ Int($0) }),
              [1, 2, 4].contains(frequency),
              let convention = basis(args, at: 8) else { return .error(.value) }
        guard issue < settlement, settlement < maturity, firstCoupon <= maturity,
              rate >= 0, sixth > 0, redemption > 0 else { return .error(.num) }

        let periodsPerYear = Double(frequency)
        let coupon = rate * 100 / periodsPerYear

        // The stub: from issue to the first coupon, as a fraction of a coupon period. The
        // first payment is that fraction of a coupon rather than a whole one.
        let stub: Double = convention.yearFraction(from: issue, to: firstCoupon) * periodsPerYear
        let toFirst: Double = convention.yearFraction(from: settlement, to: firstCoupon)
            * periodsPerYear

        // Regular coupons after the first, walked by the coupon clock rather than counted
        // from a year fraction — the number of periods is an integer and deriving it from a
        // division would round the wrong way at a month end.
        let remaining = couponsAfter(firstCoupon, to: maturity, frequency: frequency)

        var flows: [(periods: Double, amount: Double)] = []
        if toFirst > 0 { flows.append((toFirst, stub * coupon)) }
        for index in 1...Swift.max(1, remaining) where index <= remaining {
            flows.append((toFirst + Double(index), coupon))
        }
        flows.append((toFirst + Double(remaining), redemption))

        // Accrued interest: the seller's share of the stub, if settlement is inside it.
        let elapsed: Double = settlement > issue
            ? convention.yearFraction(from: issue, to: settlement) * periodsPerYear
            : 0
        let accrued = Swift.min(elapsed, stub) * coupon

        let terms = Terms(flows: flows, accrued: accrued, periodsPerYear: periodsPerYear)
        guard let result = body(terms, sixth) else { return .error(.num) }
        return finite(result)
    }

    /// How many whole coupons fall after `first` and up to `maturity`.
    ///
    /// Counted by stepping the calendar rather than dividing a year fraction: the number of
    /// periods is an integer, and a division would round the wrong way whenever a coupon
    /// lands on a month end that the next month does not have.
    private static func couponsAfter(_ first: Date, to maturity: Date, frequency: Int) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return 0 }
        calendar.timeZone = utc

        let months = 12 / frequency
        var count = 0
        var cursor = first
        // Bounded: each step advances by at least a month, and a bond's term is finite. The
        // cap is a backstop for a maturity a century out, not an expected limit.
        while count < 4_000 {
            guard let next = calendar.date(byAdding: .month, value: months, to: cursor),
                  next <= maturity else { break }
            cursor = next
            count += 1
        }
        return count
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
}
