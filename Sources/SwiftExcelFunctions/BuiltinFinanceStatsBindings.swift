import Foundation
import BusinessMath
import SwiftExcelCore

/// Excel names bound to BusinessMath's mathematics.
///
/// Nothing here computes anything. Every function converts Excel's arguments into
/// the shape BusinessMath expects, calls it, and converts back — because a second
/// covariance or a second day count in the same dependency chain could disagree
/// with the first, and that disagreement would be invisible until something was
/// priced with it.
///
/// So the tests for these check the *binding*: Excel's argument order, its
/// conventions, its edge behaviour. Whether the arithmetic is right is
/// BusinessMath's question and BusinessMath's tests.
public enum BuiltinBindingFunctions {

    /// All bound functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        yearfrac, covariancePopulation, covarianceSample, covar, normSInverse, xirrFunction,
    ]

    // MARK: - Day counts

    /// `YEARFRAC(start, end, [basis])` — the fraction of a year between two dates.
    ///
    /// Bound to `DayCountConvention.yearFraction`. Excel's basis argument selects
    /// a convention, and the three BusinessMath has cover three of the five:
    ///
    /// | Basis | Convention | State |
    /// |---|---|---|
    /// | 0 (default) | US 30/360 | a day out for a February month end |
    /// | 1 | actual/actual | an hour out across a daylight-saving boundary |
    /// | 2 | actual/360 | an hour out across a daylight-saving boundary |
    /// | 3 | actual/365 | an hour out across a daylight-saving boundary |
    /// | 4 | European 30/360 | correct |
    ///
    /// All five compute. The two caveats are upstream defects in BusinessMath's
    /// `DayCountConvention`, described below and reported; neither is worked around
    /// here, because a second implementation of a day count is the thing this split
    /// exists to prevent.
    ///
    /// ## The actual/* conventions gain an hour across daylight saving
    ///
    /// Bases 1, 2 and 3 measure elapsed time through a calendar in the machine's
    /// local zone rather than counting civil days, so an interval crossing a
    /// daylight-saving boundary picks up the offset. 1 January to 1 July 2026 comes
    /// back as 181.0417 days when the two dates are exact UTC midnights exactly
    /// 181.0 days apart.
    ///
    /// Invisible in UTC and invisible in a zone without daylight saving, which is
    /// how it survived. Worth about two parts in ten thousand on an accrual.
    ///
    /// ## Basis 0 is a day out for a February month end
    ///
    /// `DayCountConvention.thirty360` in BusinessMath 2.9.0 does not apply the NASD
    /// February rule, so a start date on the last day of February counts one day too
    /// many. `YEARFRAC(2020-02-29, 2020-12-31)` answers 302/360 where Excel answers
    /// 301/360.
    ///
    /// Two parts to the rule, and the second is the one that is easy to get
    /// backwards: the last day of February counts as a 30th, and the pull-back of an
    /// end date on the 31st tests the start day *before* that adjustment. Adjusting
    /// first gives 300 days; not adjusting at all gives 302; only the documented
    /// ordering gives Excel's 301.
    ///
    /// Not worked around here. The convention belongs to BusinessMath, which is
    /// where a second implementation could disagree with the first, and it is fixed
    /// there awaiting a release. `testTheFebruaryEndOfMonthRule` holds Excel's own
    /// value for a corpus cell and reports an unexpected pass when the pin moves.
    ///
    /// In the measured corpus this reaches **five cells** — 49 calls take a February
    /// month end as their start date, but 48 sit behind an `IF(YEAR(a)=YEAR(b), …)`
    /// guard and only five show a cached value proving the call ran.
    ///

    /// ## What the corpus asks for
    ///
    /// Measured rather than assumed, because the answer decided whether the two
    /// missing conventions were urgent: **all 3,425 `YEARFRAC` calls across the
    /// corpus pass two arguments**, omitting the basis entirely. Every one of them
    /// therefore takes basis 0, which is present. The gap is real but reaches
    /// nothing — a fact worth recording next to the gap, so nobody spends a day on
    /// it thinking it unblocks a workbook.
    ///
    /// The same measurement is why the February defect above matters more than the
    /// two missing conventions do: everything the corpus asks for goes through
    /// basis 0.
    public static let yearfrac = ExcelFunction(name: "YEARFRAC", minArgs: 2, maxArgs: 3) { args in
        guard case .number(let startSerial) = args[0],
              case .number(let endSerial) = args[1] else { return .error(.value) }

        var basis = 0
        if args.count > 2, case .number(let value) = args[2] { basis = Int(value) }

        let convention: DayCountConvention
        switch basis {
        case 0: convention = .thirty360
        // BusinessMath 2.11.0 gave the plain name to the spreadsheet's rule and
        // `isdaActualActual` to the standard, which is the right way round: someone
        // arriving from a spreadsheet should not have to know there are two.
        case 1: convention = .actualActual
        case 2: convention = .actual360
        case 3: convention = .actual365
        case 4: convention = .thirty360European
        default: return .error(.num)
        }

        guard let start = BuiltinDateTimeFunctions.serialToDate(Int(startSerial)),
              let end = BuiltinDateTimeFunctions.serialToDate(Int(endSerial)) else {
            return .error(.value)
        }
        let fraction: Double = convention.yearFraction(from: start, to: end)
        return .number(fraction)
    }

    // MARK: - Covariance

    /// `COVARIANCE.P(x, y)` — population covariance, dividing by *n*.
    public static let covariancePopulation = ExcelFunction(
        name: "COVARIANCE.P", minArgs: 2, maxArgs: 2
    ) { args in
        paired(args) { .number(covarianceP($0, $1)) }
    }

    /// `COVARIANCE.S(x, y)` — sample covariance, dividing by *n − 1*.
    public static let covarianceSample = ExcelFunction(
        name: "COVARIANCE.S", minArgs: 2, maxArgs: 2
    ) { args in
        paired(args) { .number(covarianceS($0, $1)) }
    }

    /// `COVAR(x, y)` — the legacy name, and the **population** form.
    ///
    /// Worth stating because the pairing is not obvious: Excel's older `COVAR`
    /// matches `COVARIANCE.P`, not `COVARIANCE.S`. Binding it to the sample form
    /// would be off by a factor of n/(n−1) and would look plausible.
    public static let covar = ExcelFunction(name: "COVAR", minArgs: 2, maxArgs: 2) { args in
        paired(args) { .number(covarianceP($0, $1)) }
    }

    /// Two equal-length numeric vectors, or `#N/A`.
    ///
    /// BusinessMath returns zero for mismatched lengths, which is a legitimate
    /// covariance and therefore the wrong thing to show a caller who has paired
    /// the wrong ranges. Excel says `#N/A`, and so does this.
    private static func paired(
        _ args: [CellValue],
        _ body: ([Double], [Double]) -> CellValue
    ) -> CellValue {
        let x = numbers(in: args[0])
        let y = numbers(in: args[1])
        guard !x.isEmpty, x.count == y.count else { return .error(.na) }
        return body(x, y)
    }

    /// The numbers in a value, skipping anything that is not one.
    private static func numbers(in value: CellValue) -> [Double] {
        switch value {
        case .array(let matrix):
            return matrix.elements.compactMap { if case .number(let n) = $0 { return n } else { return nil } }
        case .number(let n):
            return [n]
        default:
            return []
        }
    }

    // MARK: - Normal deviate

    /// `NORM.S.INV(probability)` — the standard normal quantile.
    ///
    /// Bound to `normSInv`. A probability of exactly 0 or 1 has no finite answer,
    /// so both ends are refused rather than returning an infinity that would
    /// propagate silently.
    public static let normSInverse = ExcelFunction(
        name: "NORM.S.INV", minArgs: 1, maxArgs: 1
    ) { args in
        guard case .number(let probability) = args[0] else { return .error(.value) }
        guard probability > 0, probability < 1 else { return .error(.num) }
        return .number(normSInv(probability: probability))
    }

    // MARK: - Dated cash flows

    /// `XIRR(values, dates, [guess])` — the internal rate of return on cash flows
    /// that are not evenly spaced.
    ///
    /// Bound to BusinessMath's `xirr`. The binding is the date conversion: Excel
    /// carries dates as serials and BusinessMath speaks in `Date`, so every entry
    /// crosses through the same internal serial conversion the date functions use,
    /// and therefore through the one place Excel's phantom 29 February 1900 is
    /// handled.
    ///
    /// Excel's argument order is values first, dates second — the reverse of
    /// BusinessMath's, which is exactly the kind of thing a binding exists to get
    /// right once.
    ///
    /// Every failure BusinessMath can raise becomes `#NUM!`, which is what Excel
    /// gives: mismatched counts, fewer than two flows, and cash flows that never
    /// change sign. That last one is not an edge case but the definition — a
    /// series that only ever pays out has no rate of return.
    public static let xirrFunction = ExcelFunction(name: "XIRR", minArgs: 2, maxArgs: 3) { args in
        let cashFlows = numbers(in: args[0])
        let serials = numbers(in: args[1])
        guard !cashFlows.isEmpty, cashFlows.count == serials.count else { return .error(.num) }

        var dates: [Date] = []
        dates.reserveCapacity(serials.count)
        for serial in serials {
            guard let date = BuiltinDateTimeFunctions.serialToDate(Int(serial)) else {
                return .error(.value)
            }
            dates.append(date)
        }

        var guess: Double?
        if args.count > 2, case .number(let value) = args[2] { guess = value }

        do {
            let rate: Double = try xirr(dates: dates, cashFlows: cashFlows, guess: guess)
            return .number(rate)
        } catch {
            return .error(.num)
        }
    }
}
