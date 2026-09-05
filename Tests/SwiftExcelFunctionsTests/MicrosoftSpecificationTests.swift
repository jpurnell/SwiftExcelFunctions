import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// Behaviour taken from Microsoft's published function reference, not from ours.
///
/// The corpus oracle in `ExcelOracleTests` is the broader check — it tests the
/// cases real models happen to contain, on files nobody wrote for us. This is the
/// narrower one, and it exists for two reasons the oracle cannot serve.
///
/// **It is readable.** The oracle answers "how often do we agree", which is a
/// number you either trust or do not. These say what the rule *is*, in a form
/// someone can check against Microsoft's page without running anything. Work that
/// cannot be inspected is work that has to be taken on faith.
///
/// **It runs everywhere.** The oracle needs private workbooks and is opt-in. These
/// run in the gate, on a clean checkout, on a machine that has never seen a
/// spreadsheet.
///
/// ## Where the expected values come from
///
/// Every figure here is either quoted from Microsoft's own worked example or
/// computed from the documented formula and shown alongside it. None is derived
/// from what this package currently returns — that would test only that we are
/// consistent with ourselves, which is exactly the mistake that let a day-count
/// bug ship: two implementations reasoning from one definition agree with each
/// other and are both wrong.
final class MicrosoftSpecificationTests: XCTestCase {

    // MARK: - Helpers

    private func function(_ name: String) throws -> ExcelFunction {
        let groups: [[ExcelFunction]] = [
            BuiltinFinancialFunctions.all, BuiltinBindingFunctions.all,
            BuiltinNavigationFunctions.all, BuiltinDateTimeFunctions.all,
            BuiltinMathFunctions.all, BuiltinStatsFunctions.all,
        ]
        for group in groups {
            if let found = group.first(where: { $0.name == name }) { return found }
        }
        throw XCTSkip("\(name) is not registered")
    }

    private func number(_ name: String, _ args: [CellValue]) throws -> Double {
        let result = try function(name).evaluate(args)
        guard case .number(let value) = result else {
            XCTFail("\(name) answered \(result), not a number")
            return .nan
        }
        return value
    }

    private func column(_ values: [Double]) -> CellValue {
        .array(CellMatrix(column: values.map { .number($0) }))
    }

    // MARK: - NPV

    // Microsoft: "Calculates the net present value of an investment by using a
    // discount rate and a series of future payments (negative values) and income
    // (positive values)." The documented formula is
    //
    //     NPV = Σ  valuesᵢ / (1 + rate)ⁱ      for i = 1…n
    //
    // — so value1 is discounted one period, not held at present value. "The NPV
    // investment begins one period before the date of the value1 cash flow."

    /// Microsoft's first worked example: `=NPV(0.1, -10000, 3000, 4200, 6800)`,
    /// published as `$1,188.44`.
    func testNpvDiscountsTheFirstValueOnePeriod() throws {
        let value = try number("NPV", [.number(0.1), .number(-10000), .number(3000),
                                       .number(4200), .number(6800)])
        XCTAssertEqual(value, 1188.4434123352212, accuracy: 1e-9)
    }

    /// The same cash flows as one range, which is how a worksheet writes it.
    ///
    /// Microsoft's own examples use both forms — `=NPV(A2, A3, A4, A5, A6)` and
    /// `=NPV(A2, A4:A8)+A3` — so a reference argument is not an edge case, it is the
    /// ordinary case. The corpus oracle found 126 disagreements here.
    func testNpvAcceptsARangeAsOneArgument() throws {
        let value = try number("NPV", [.number(0.1),
                                       column([-10000, 3000, 4200, 6800])])
        XCTAssertEqual(value, 1188.4434123352212, accuracy: 1e-9)
    }

    /// Microsoft's second example: `=NPV(0.08, A4:A8) + A3`, published as `$1,922.06`
    /// with `A3 = -40000` held outside because it falls at period 0.
    func testNpvWithAnInitialOutlayOutsideTheFunction() throws {
        let value = try number("NPV", [.number(0.08),
                                       column([8000, 9200, 10000, 12000, 14500])])
        XCTAssertEqual(value - 40000, 1922.061554932363, accuracy: 1e-9)
    }

    /// Microsoft's third: `=NPV(0.08, A4:A8, -9000) + A3`, published as `($3,749.47)`.
    /// A trailing scalar after a range extends the series by one more period.
    func testNpvMixesARangeAndAScalar() throws {
        let value = try number("NPV", [.number(0.08),
                                       column([8000, 9200, 10000, 12000, 14500]),
                                       .number(-9000)])
        XCTAssertEqual(value - 40000, -3749.4650870155747, accuracy: 1e-9)
    }

    /// Microsoft: "If an argument is an array or reference, only numbers in that
    /// array or reference are counted. Empty cells, logical values, text, or error
    /// values in the array or reference are ignored."
    ///
    /// Ignored, not zero — a blank in the middle of a column must not consume a
    /// period, or every cash flow after it is discounted one period too far.
    func testNpvIgnoresNonNumbersInsideARange() throws {
        let clean = try number("NPV", [.number(0.1), column([100, 200, 300])])
        let withNoise = try number("NPV", [
            .number(0.1),
            .array(CellMatrix(column: [.number(100), .blank, .number(200),
                                       .text("n/a"), .number(300), .bool(true)])),
        ])
        XCTAssertEqual(withNoise, clean, accuracy: 1e-9,
                       "a blank must not shift the periods after it")
    }

    /// The order of the arguments is the order of the cash flows, so reversing them
    /// must change the answer. Guards against an implementation that sums first.
    func testNpvIsOrderDependent() throws {
        let forward = try number("NPV", [.number(0.1), column([100, 200, 300])])
        let backward = try number("NPV", [.number(0.1), column([300, 200, 100])])
        XCTAssertNotEqual(forward, backward, accuracy: 1e-9)
    }

    // MARK: - YEARFRAC and the day counts

    // Microsoft's basis argument:
    //
    //   0 or omitted  US (NASD) 30/360
    //   1             actual/actual
    //   2             actual/360
    //   3             actual/365
    //   4             European 30/360
    //
    // Serials below are Excel's, counted from the 1899-12-30 epoch. Each is stated
    // with its date so the test can be read without a converter.

    private static let jan1_2026 = 46023.0   // 2026-01-01
    private static let jul1_2026 = 46204.0   // 2026-07-01
    private static let feb29_2020 = 43890.0  // 2020-02-29, a leap-year month end
    private static let feb28_2021 = 44255.0  // 2021-02-28, a common-year month end
    private static let dec31_2020 = 44196.0  // 2020-12-31
    private static let jul31_2021 = 44408.0  // 2021-07-31

    /// Six thirty-day months over 360 is exactly half a year, on any 30/360 basis.
    func testYearFracThirtyThreeSixtyOnCleanDates() throws {
        XCTAssertEqual(try number("YEARFRAC", [.number(Self.jan1_2026),
                                               .number(Self.jul1_2026), .number(0)]),
                       0.5, accuracy: 1e-12)
    }

    /// Basis 3 counts real days over 365: 1 January to 1 July 2026 is 181 days.
    ///
    /// **Known upstream defect.** We answer 181.0417/365. The extra 1/24 of a day is
    /// an hour, and it is daylight saving: the two dates are exact UTC midnights and
    /// the interval between them is exactly 181.0 days, but BusinessMath's
    /// actual/365 measures elapsed time through a calendar in the machine's local
    /// zone, so an interval crossing a DST boundary gains or loses an hour.
    ///
    /// It is invisible in UTC and invisible in a zone with no DST, which is why it
    /// has survived — and it moves every actual/360 and actual/365 accrual by about
    /// two parts in ten thousand. Reported to the BusinessMath session.
    func testYearFracActual365CountsRealDays() throws {
        XCTExpectFailure("BusinessMath actual/365 measures elapsed time in the local zone")
        XCTAssertEqual(try number("YEARFRAC", [.number(Self.jan1_2026),
                                               .number(Self.jul1_2026), .number(3)]),
                       181.0 / 365.0, accuracy: 1e-12)
    }

    /// Basis 2 is the same day count over 360, and carries the same hour.
    func testYearFracActual360() throws {
        XCTExpectFailure("BusinessMath actual/360 measures elapsed time in the local zone")
        XCTAssertEqual(try number("YEARFRAC", [.number(Self.jan1_2026),
                                               .number(Self.jul1_2026), .number(2)]),
                       181.0 / 360.0, accuracy: 1e-12)
    }

    /// The same interval within one side of a DST change is exact, which is what
    /// isolates the cause. 1 January to 1 March 2026 is 59 days and never crosses.
    func testYearFracActual365IsExactWithinOneOffset() throws {
        let mar1_2026 = 46082.0   // 2026-03-01
        XCTAssertEqual(try number("YEARFRAC", [.number(Self.jan1_2026),
                                               .number(mar1_2026), .number(3)]),
                       59.0 / 365.0, accuracy: 1e-12)
    }

    /// **The NASD February rule.** The last day of February counts as a 30th, and
    /// the pull-back of an end date on the 31st tests the start day *before* that
    /// adjustment.
    ///
    /// 2020-02-29 to 2020-12-31 is 301/360. Adjusting February first and then
    /// testing the pull-back gives 300; applying neither gives 302. Excel's own
    /// cached value for this pair, in a corpus workbook, is 0.83611111111111114.
    ///
    /// Expected to fail until BusinessMath ships the rule — see
    /// `testTheFebruaryEndOfMonthRule`, which holds the same case with its
    /// provenance.
    func testYearFracFebruaryMonthEndIsThirty() throws {
        XCTExpectFailure("BusinessMath 2.9.0 lacks the NASD February rule")
        XCTAssertEqual(try number("YEARFRAC", [.number(Self.feb29_2020),
                                               .number(Self.dec31_2020), .number(0)]),
                       301.0 / 360.0, accuracy: 1e-12)
    }

    /// The common-year half of the same rule: 28 February is the month end too.
    /// 2021-02-28 to 2021-07-31 is 30·5 + (30−30) = 150 days.
    func testYearFracCommonYearFebruaryMonthEnd() throws {
        XCTExpectFailure("BusinessMath 2.9.0 lacks the NASD February rule")
        XCTAssertEqual(try number("YEARFRAC", [.number(Self.feb28_2021),
                                               .number(Self.jul31_2021), .number(0)]),
                       150.0 / 360.0, accuracy: 1e-12)
    }

    /// Bases 1 and 4 are refused rather than approximated by a neighbour.
    ///
    /// Flips to an unexpected pass when BusinessMath ships `actualActual` and
    /// `thirty360European`, which is the notification we want.
    func testYearFracRefusesWhatItCannotComputeYet() throws {
        for basis in [1.0, 4.0] {
            let result = try function("YEARFRAC").evaluate([
                .number(Self.jan1_2026), .number(Self.jul1_2026), .number(basis),
            ])
            XCTAssertEqual(result, .error(.num), "basis \(basis)")
        }
        XCTAssertEqual(try function("YEARFRAC").evaluate([
            .number(Self.jan1_2026), .number(Self.jul1_2026), .number(5),
        ]), .error(.num), "an undefined basis is #NUM!")
    }

    // MARK: - Lookups

    // Microsoft on VLOOKUP's `range_lookup`: "If TRUE or omitted, an exact or
    // approximate match is returned. If an exact match is not found, the next
    // largest value that is less than lookup_value is returned" — and the first
    // column must be sorted ascending. "If FALSE, VLOOKUP will find only an exact
    // match", and returns #N/A otherwise.

    private func grid(_ rows: [[CellValue]]) -> CellValue {
        let width = rows.first?.count ?? 0
        guard let matrix = CellMatrix(elements: rows.flatMap { $0 },
                                      rows: rows.count, columns: width) else {
            XCTFail("ragged table")
            return .error(.value)
        }
        return .array(matrix)
    }

    func testVlookupApproximateTakesTheNextSmallest() throws {
        let table = grid([[.number(10), .text("ten")],
                          [.number(20), .text("twenty")],
                          [.number(30), .text("thirty")]])
        XCTAssertEqual(try function("VLOOKUP").evaluate(
            [.number(25), table, .number(2), .bool(true)]), .text("twenty"))
    }

    /// Below the first key there is no smaller value, so `#N/A`.
    func testVlookupApproximateBelowTheFirstKeyIsNotAvailable() throws {
        let table = grid([[.number(10), .text("ten")], [.number(20), .text("twenty")]])
        XCTAssertEqual(try function("VLOOKUP").evaluate(
            [.number(5), table, .number(2), .bool(true)]), .error(.na))
    }

    func testVlookupExactRefusesANearMiss() throws {
        let table = grid([[.number(10), .text("ten")], [.number(20), .text("twenty")]])
        XCTAssertEqual(try function("VLOOKUP").evaluate(
            [.number(15), table, .number(2), .bool(false)]), .error(.na))
    }

    /// Microsoft: "If col_index_num is greater than the number of columns in
    /// table_array, VLOOKUP returns the #REF! error value."
    func testVlookupPastTheTableIsARefError() throws {
        let table = grid([[.number(10), .text("ten")]])
        XCTAssertEqual(try function("VLOOKUP").evaluate(
            [.number(10), table, .number(3), .bool(false)]), .error(.ref))
    }

    /// And "if col_index_num is less than 1, VLOOKUP returns #VALUE!".
    func testVlookupBelowTheFirstColumnIsAValueError() throws {
        let table = grid([[.number(10), .text("ten")]])
        XCTAssertEqual(try function("VLOOKUP").evaluate(
            [.number(10), table, .number(0), .bool(false)]), .error(.value))
    }

    // MARK: - EOMONTH

    // Microsoft: "Returns the serial number for the last day of the month that is
    // the indicated number of months before or after start_date."

    func testEomonthMovesForwardAndLands() throws {
        // 2020-01-31 + 1 month is 2020-02-29, a leap February.
        let jan31_2020 = 43861.0
        XCTAssertEqual(try number("EOMONTH", [.number(jan31_2020), .number(1)]),
                       Self.feb29_2020, accuracy: 0)
    }

    func testEomonthMovesBackward() throws {
        // 2020-12-31 back ten months is 2020-02-29.
        XCTAssertEqual(try number("EOMONTH", [.number(Self.dec31_2020), .number(-10)]),
                       Self.feb29_2020, accuracy: 0)
    }

    func testEomonthWithZeroIsTheEndOfTheSameMonth() throws {
        // 2020-02-29 is already the month end and stays put.
        XCTAssertEqual(try number("EOMONTH", [.number(Self.feb29_2020), .number(0)]),
                       Self.feb29_2020, accuracy: 0)
    }
}
