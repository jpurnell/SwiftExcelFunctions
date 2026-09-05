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
    /// | Basis | Convention | Available |
    /// |---|---|---|
    /// | 0 (default) | US 30/360 | yes |
    /// | 1 | actual/actual | **not yet** |
    /// | 2 | actual/360 | yes |
    /// | 3 | actual/365 | yes |
    /// | 4 | European 30/360 | **not yet** |
    ///
    /// The two missing ones answer `#NUM!` rather than being approximated by a
    /// neighbouring convention. A day count that is wrong by a few days is wrong
    /// in a way nobody notices until it has priced something, so refusing is the
    /// only honest option until BusinessMath gains them.
    ///
    /// ## What the corpus asks for
    ///
    /// Measured rather than assumed, because the answer decided whether the two
    /// missing conventions were urgent: **all 3,425 `YEARFRAC` calls across the
    /// corpus pass two arguments**, omitting the basis entirely. Every one of them
    /// therefore takes basis 0, which is present. The gap is real but reaches
    /// nothing — a fact worth recording next to the gap, so nobody spends a day on
    /// it thinking it unblocks a workbook.
    public static let yearfrac = ExcelFunction(name: "YEARFRAC", minArgs: 2, maxArgs: 3) { args in
        guard case .number(let startSerial) = args[0],
              case .number(let endSerial) = args[1] else { return .error(.value) }

        var basis = 0
        if args.count > 2, case .number(let value) = args[2] { basis = Int(value) }

        let convention: DayCountConvention
        switch basis {
        case 0: convention = .thirty360
        case 2: convention = .actual360
        case 3: convention = .actual365
        // Basis 1 is actual/actual and basis 4 the European 30/360. Neither is in
        // BusinessMath yet; both are on its work list.
        case 1, 4: return .error(.num)
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
        case .array(let values):
            return values.compactMap { if case .number(let n) = $0 { return n } else { return nil } }
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
