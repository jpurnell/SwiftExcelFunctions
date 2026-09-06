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
            BuiltinTextFunctions.all, BuiltinLogicFunctions.all,
            BuiltinAggregationFunctions.all, BuiltinArrayFunctions.all,
            BuiltinRiskSolverFunctions.all,
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

    /// Basis 4, European 30/360: every month is thirty days, with no February rule
    /// and no end-of-month pull-back. 1 January to 1 July 2026 is six months.
    ///
    /// The only basis with no outstanding defect behind it.
    func testYearFracEuropeanThirtyThreeSixty() throws {
        XCTAssertEqual(try number("YEARFRAC", [.number(Self.jan1_2026),
                                               .number(Self.jul1_2026), .number(4)]),
                       0.5, accuracy: 1e-12)
    }

    /// Basis 1 within a single calendar year divides by that year's length. 2026 is
    /// not a leap year, so 1 January to 1 July is 181/365.
    ///
    /// Carries the same daylight-saving hour as bases 2 and 3 — `actualActual` was
    /// added in BusinessMath 2.11.0 on top of the same elapsed-time measurement.
    func testYearFracActualActualWithinOneYear() throws {
        XCTExpectFailure("BusinessMath's actual/actual inherits the local-zone measurement")
        XCTAssertEqual(try number("YEARFRAC", [.number(Self.jan1_2026),
                                               .number(Self.jul1_2026), .number(1)]),
                       181.0 / 365.0, accuracy: 1e-12)
    }

    /// A basis Excel does not define is `#NUM!`.
    func testYearFracRefusesAnUndefinedBasis() throws {
        XCTAssertEqual(try function("YEARFRAC").evaluate([
            .number(Self.jan1_2026), .number(Self.jul1_2026), .number(5),
        ]), .error(.num))
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

    // MARK: - XLOOKUP

    // Microsoft: "The XLOOKUP function searches a range or an array, and then
    // returns the item corresponding to the first match it finds. If no match
    // exists, then XLOOKUP can return the closest (approximate) match."
    //
    // It supersedes VLOOKUP and HLOOKUP by separating the keys from the results:
    // two ranges rather than one table and an offset into it. The consequences are
    // what these tests pin.

    private func row(_ values: [CellValue]) -> CellValue {
        .array(CellMatrix(row: values))
    }

    func testXlookupFindsAnExactMatch() throws {
        XCTAssertEqual(try function("XLOOKUP").evaluate([
            .text("b"),
            row([.text("a"), .text("b"), .text("c")]),
            row([.number(1), .number(2), .number(3)]),
        ]), .number(2))
    }

    /// **The default is exact**, the reverse of `VLOOKUP`. A near miss is `#N/A`
    /// rather than the next smallest, which is the single most consequential
    /// difference between them.
    func testXlookupDefaultsToExact() throws {
        XCTAssertEqual(try function("XLOOKUP").evaluate([
            .number(25),
            row([.number(10), .number(20), .number(30)]),
            row([.text("ten"), .text("twenty"), .text("thirty")]),
        ]), .error(.na))
    }

    /// `if_not_found` replaces the `IFERROR` wrapper VLOOKUP needed.
    func testXlookupReturnsWhatYouAskForWhenNothingMatches() throws {
        XCTAssertEqual(try function("XLOOKUP").evaluate([
            .number(25),
            row([.number(10), .number(20)]),
            row([.text("ten"), .text("twenty")]),
            .text("none"),
        ]), .text("none"))
    }

    /// `match_mode` −1 is exact or next smaller, 1 is exact or next larger.
    func testXlookupApproximateModes() throws {
        let keys = row([.number(10), .number(20), .number(30)])
        let results = row([.text("ten"), .text("twenty"), .text("thirty")])
        XCTAssertEqual(try function("XLOOKUP").evaluate(
            [.number(25), keys, results, .text("none"), .number(-1)]), .text("twenty"))
        XCTAssertEqual(try function("XLOOKUP").evaluate(
            [.number(25), keys, results, .text("none"), .number(1)]), .text("thirty"))
    }

    /// **The result may sit before the key.** `VLOOKUP` cannot do this at all: its
    /// offset counts rightwards from the key column, so a leftward answer needs
    /// `INDEX`/`MATCH`. Here the two ranges are independent.
    func testXlookupReturnsAColumnLeftOfTheKey() throws {
        XCTAssertEqual(try function("XLOOKUP").evaluate([
            .text("b"),
            row([.text("a"), .text("b")]),      // keys, notionally column B
            row([.number(1), .number(2)]),      // results, notionally column A
        ]), .number(2))
    }

    /// `search_mode` −1 searches last to first, so a duplicated key answers with the
    /// later of the two.
    func testXlookupCanSearchBackwards() throws {
        let keys = row([.text("a"), .text("b"), .text("a")])
        let results = row([.number(1), .number(2), .number(3)])
        XCTAssertEqual(try function("XLOOKUP").evaluate(
            [.text("a"), keys, results, .text("none"), .number(0), .number(1)]), .number(1))
        XCTAssertEqual(try function("XLOOKUP").evaluate(
            [.text("a"), keys, results, .text("none"), .number(0), .number(-1)]), .number(3))
    }

    /// Mismatched ranges are `#VALUE!`: there is no answer to give.
    func testXlookupRefusesMismatchedRanges() throws {
        XCTAssertEqual(try function("XLOOKUP").evaluate([
            .text("a"),
            row([.text("a"), .text("b"), .text("c")]),
            row([.number(1), .number(2)]),
        ]), .error(.value))
    }

    /// Wildcard matching is refused rather than silently treated as exact, which
    /// would find the wrong row and say nothing about it.
    func testXlookupRefusesWildcardMode() throws {
        XCTAssertEqual(try function("XLOOKUP").evaluate([
            .text("a*"),
            row([.text("abc")]), row([.number(1)]),
            .text("none"), .number(2),
        ]), .error(.value))
    }

    /// An error in the lookup propagates — but not one in `if_not_found`, whose
    /// whole purpose is to be produced when the lookup fails.
    func testXlookupPropagatesButHonoursIfNotFound() throws {
        XCTAssertEqual(try function("XLOOKUP").evaluate([
            .error(.name), row([.text("a")]), row([.number(1)]),
        ]), .error(.name))
        XCTAssertEqual(try function("XLOOKUP").evaluate([
            .text("z"), row([.text("a")]), row([.number(1)]), .error(.na),
        ]), .error(.na), "an error is a legitimate thing to ask for on failure")
    }

    /// It resolves through `_xlfn.`, which is how an older `.xlsx` carries it.
    func testXlookupResolvesThroughTheModernPrefix() {
        XCTAssertNotNil(FunctionRegistry.builtin.function(named: "_xlfn.XLOOKUP"))
    }

    // MARK: - XIRR convergence

    /// `XIRR` finds the rate at which the discounted flows sum to zero, and ours
    /// finds it more precisely than Excel does.
    ///
    /// Taken from `Long Acre Team 2013 / Valuation!E17`. Excel caches
    /// 0.13088350892066958; `XNPV` at that rate is −0.00152, so it is not the root.
    /// This test asserts the property rather than a figure: whatever rate we return,
    /// discounting the flows at it must give back approximately nothing.
    ///
    /// Written as a property because the alternative — asserting Excel's number —
    /// would pin us to Excel's convergence residue and call it correctness.
    func testXirrReturnsAnActualRoot() throws {
        // Four flows a year apart: -1000 out, then 400, 400, 400 back.
        let serials: [Double] = [44197, 44562, 44927, 45292]  // 2021-01-01 .. 2024-01-01
        let flows: [Double] = [-1000, 400, 400, 400]
        let rate = try number("XIRR", [
            .array(CellMatrix(column: flows.map { .number($0) })),
            .array(CellMatrix(column: serials.map { .number($0) })),
        ])

        // Discount by hand at the returned rate; the sum must be ~0.
        var residue = 0.0
        for (serial, flow) in zip(serials, flows) {
            let years = (serial - serials[0]) / 365.0
            residue += flow / pow(1 + rate, years)
        }
        XCTAssertEqual(residue, 0, accuracy: 1e-6,
                       "the returned rate must actually zero the discounted flows")
        XCTAssertGreaterThan(rate, 0.09)
        XCTAssertLessThan(rate, 0.11)
    }

    // MARK: - Text

    // Microsoft on the pair that trips everyone: FIND is case-sensitive and takes no
    // wildcards; SEARCH is case-insensitive and does. Both are 1-based, both return
    // #VALUE! when the text is not there, and both count characters rather than bytes.

    private func text(_ name: String, _ args: CellValue...) throws -> CellValue {
        try function(name).evaluate(args)
    }

    func testFindIsOneBasedAndCaseSensitive() throws {
        XCTAssertEqual(try text("FIND", .text("M"), .text("Miriam McGovern")), .number(1))
        XCTAssertEqual(try text("FIND", .text("m"), .text("Miriam McGovern")), .number(6))
        XCTAssertEqual(try text("FIND", .text("M"), .text("Miriam McGovern"), .number(3)),
                       .number(8))
    }

    /// Microsoft: "If find_text does not appear in within_text, FIND returns the
    /// #VALUE! error value."
    func testFindReturnsValueErrorWhenAbsent() throws {
        XCTAssertEqual(try text("FIND", .text("z"), .text("abc")), .error(.value))
    }

    /// "If find_text is empty, FIND matches the first character in the search
    /// string" — so it returns start_num rather than failing.
    func testFindWithEmptyNeedleReturnsTheStart() throws {
        XCTAssertEqual(try text("FIND", .text(""), .text("abc")), .number(1))
        XCTAssertEqual(try text("FIND", .text(""), .text("abc"), .number(2)), .number(2))
    }

    /// "If start_num is not greater than zero, or is greater than the length of
    /// within_text, FIND returns #VALUE!."
    func testFindRejectsAnOutOfRangeStart() throws {
        XCTAssertEqual(try text("FIND", .text("a"), .text("abc"), .number(0)), .error(.value))
        XCTAssertEqual(try text("FIND", .text("a"), .text("abc"), .number(4)), .error(.value))
    }

    func testSearchIsCaseInsensitive() throws {
        XCTAssertEqual(try text("SEARCH", .text("m"), .text("Miriam McGovern")), .number(1))
        XCTAssertEqual(try text("SEARCH", .text("M"), .text("Miriam McGovern")), .number(1))
    }

    /// SEARCH takes `?` for one character and `*` for any run of them.
    func testSearchTakesWildcards() throws {
        XCTAssertEqual(try text("SEARCH", .text("b?d"), .text("abcde")), .number(2))
        XCTAssertEqual(try text("SEARCH", .text("a*e"), .text("abcde")), .number(1))
        XCTAssertEqual(try text("SEARCH", .text("x*z"), .text("abcde")), .error(.value))
    }

    // Microsoft on SUBSTITUTE: "Substitutes new_text for old_text in a text string.
    // Use SUBSTITUTE when you want to replace specific text… If instance_num is
    // specified, only that instance is replaced."

    func testSubstituteReplacesEveryInstance() throws {
        XCTAssertEqual(try text("SUBSTITUTE", .text("Sales Data"), .text("Sales"),
                                .text("Cost")), .text("Cost Data"))
        XCTAssertEqual(try text("SUBSTITUTE", .text("a-b-c"), .text("-"), .text("+")),
                       .text("a+b+c"))
    }

    func testSubstituteReplacesOnlyTheNamedInstance() throws {
        // Microsoft's own example: Quarter 1, 2011 -> Quarter 2, 2011
        XCTAssertEqual(try text("SUBSTITUTE", .text("Quarter 1, 2011"), .text("1"),
                                .text("2"), .number(1)), .text("Quarter 2, 2011"))
        XCTAssertEqual(try text("SUBSTITUTE", .text("a-b-c"), .text("-"), .text("+"),
                                .number(2)), .text("a-b+c"))
    }

    /// "SUBSTITUTE is case-sensitive" — unlike REPLACE, which works by position.
    func testSubstituteIsCaseSensitive() throws {
        XCTAssertEqual(try text("SUBSTITUTE", .text("aAa"), .text("a"), .text("z")),
                       .text("zAz"))
    }

    /// An instance number beyond the count changes nothing, rather than erroring.
    func testSubstituteWithATooLargeInstanceIsUnchanged() throws {
        XCTAssertEqual(try text("SUBSTITUTE", .text("a-b"), .text("-"), .text("+"),
                                .number(5)), .text("a-b"))
    }

    /// Empty old_text leaves the string alone; Excel has nothing to find.
    func testSubstituteWithEmptyOldTextIsUnchanged() throws {
        XCTAssertEqual(try text("SUBSTITUTE", .text("abc"), .text(""), .text("z")),
                       .text("abc"))
    }

    func testProperCapitalisesEachWord() throws {
        XCTAssertEqual(try text("PROPER", .text("this is a TITLE")),
                       .text("This Is A Title"))
        XCTAssertEqual(try text("PROPER", .text("2-cent's worth")),
                       .text("2-Cent'S Worth"), "Excel breaks on the apostrophe too")
    }

    /// CLEAN removes the non-printing characters 0–31.
    func testCleanRemovesControlCharacters() throws {
        XCTAssertEqual(try text("CLEAN", .text("a\u{07}b\u{07}c")), .text("abc"))
        XCTAssertEqual(try text("CLEAN", .text("plain")), .text("plain"))
    }

    /// NUMBERVALUE reads a number from text using explicit separators, so it does
    /// not depend on the machine's locale.
    func testNumberValueUsesTheSeparatorsItIsGiven() throws {
        XCTAssertEqual(try text("NUMBERVALUE", .text("2.500,27"), .text(","), .text(".")),
                       .number(2500.27))
        XCTAssertEqual(try text("NUMBERVALUE", .text("3.5")), .number(3.5))
    }

    /// "If empty, an empty string is used" — an empty argument is 0, not an error.
    func testNumberValueOfEmptyIsZero() throws {
        XCTAssertEqual(try text("NUMBERVALUE", .text("")), .number(0))
    }

    func testNumberValueRefusesWhatIsNotANumber() throws {
        XCTAssertEqual(try text("NUMBERVALUE", .text("abc")), .error(.value))
    }

    // MARK: - Dates and references

    /// `WORKDAY(start, days, [holidays])` — a date a number of working days away,
    /// counting Monday to Friday and skipping any holidays given.
    ///
    /// Microsoft's own example: 2008-10-01 plus 151 working days is 2009-04-30, and
    /// with the four holidays listed it becomes 2009-05-06.
    func testWorkdaySkipsWeekends() throws {
        // 2026-01-01 is a Thursday; one working day on is Friday the 2nd,
        // two is Monday the 5th.
        let jan1 = 46023.0
        XCTAssertEqual(try number("WORKDAY", [.number(jan1), .number(1)]), jan1 + 1)
        XCTAssertEqual(try number("WORKDAY", [.number(jan1), .number(2)]), jan1 + 4)
    }

    func testWorkdayCountsBackwards() throws {
        // 2026-01-05 is a Monday; one working day back is Friday the 2nd.
        let jan5 = 46027.0
        XCTAssertEqual(try number("WORKDAY", [.number(jan5), .number(-1)]), jan5 - 3)
    }

    func testWorkdaySkipsHolidays() throws {
        let jan1 = 46023.0    // Thursday
        // With Friday the 2nd a holiday, one working day on is Monday the 5th.
        XCTAssertEqual(
            try number("WORKDAY", [.number(jan1), .number(1),
                                   .array(CellMatrix(column: [.number(jan1 + 1)]))]),
            jan1 + 4)
    }

    /// Zero days stays put, even on a weekend — Excel does not snap to a workday.
    func testWorkdayWithZeroDaysStaysPut() throws {
        let jan3 = 46025.0   // Saturday
        XCTAssertEqual(try number("WORKDAY", [.number(jan3), .number(0)]), jan3)
    }

    /// `DATEVALUE(text)` — the serial for a date written as text.
    func testDateValueReadsATextDate() throws {
        XCTAssertEqual(try number("DATEVALUE", [.text("2026-01-01")]), 46023)
        XCTAssertEqual(try number("DATEVALUE", [.text("1/1/2026")]), 46023)
    }

    func testDateValueRefusesWhatIsNotADate() throws {
        XCTAssertEqual(try function("DATEVALUE").evaluate([.text("not a date")]),
                       .error(.value))
    }

    /// `TIME(hour, minute, second)` — a fraction of a day, so noon is 0.5.
    func testTimeIsAFractionOfADay() throws {
        XCTAssertEqual(try number("TIME", [.number(12), .number(0), .number(0)]),
                       0.5, accuracy: 1e-12)
        XCTAssertEqual(try number("TIME", [.number(6), .number(0), .number(0)]),
                       0.25, accuracy: 1e-12)
    }

    /// "If hour is greater than 23, it is divided by 24 and the remainder is
    /// treated as the hour value."
    func testTimeWrapsPastMidnight() throws {
        XCTAssertEqual(try number("TIME", [.number(27), .number(0), .number(0)]),
                       0.125, accuracy: 1e-12)
    }

    /// `ROWS` and `COLUMNS` count a range's shape — which the value now carries.
    func testRowsAndColumnsCountTheShape() throws {
        let block = grid([[.number(1), .number(2), .number(3)],
                          [.number(4), .number(5), .number(6)]])
        XCTAssertEqual(try number("ROWS", [block]), 2)
        XCTAssertEqual(try number("COLUMNS", [block]), 3)
        XCTAssertEqual(try number("ROWS", [.number(1)]), 1, "a lone value is 1x1")
        XCTAssertEqual(try number("COLUMNS", [.number(1)]), 1)
    }

    /// `HYPERLINK(location, [friendly_name])` displays the friendly name, or the
    /// location when there is none. The jump is a UI act; the value is text.
    func testHyperlinkShowsItsFriendlyName() throws {
        XCTAssertEqual(try function("HYPERLINK").evaluate(
            [.text("https://example.com"), .text("Example")]), .text("Example"))
        XCTAssertEqual(try function("HYPERLINK").evaluate([.text("https://example.com")]),
                       .text("https://example.com"))
    }

    // MARK: - Foundation maths

    // Bridged rather than reimplemented: these are libm's, and a second
    // implementation of a sine would be a liability with no upside.

    func testTrigonometryIsInRadians() throws {
        XCTAssertEqual(try number("SIN", [.number(0)]), 0, accuracy: 1e-12)
        XCTAssertEqual(try number("COS", [.number(0)]), 1, accuracy: 1e-12)
        let pi = try number("PI", [])
        XCTAssertEqual(try number("SIN", [.number(pi / 2)]), 1, accuracy: 1e-12)
        XCTAssertEqual(try number("COS", [.number(pi)]), -1, accuracy: 1e-12)
        XCTAssertEqual(try number("TAN", [.number(0)]), 0, accuracy: 1e-12)
    }

    func testLogBaseTen() throws {
        XCTAssertEqual(try number("LOG10", [.number(1000)]), 3, accuracy: 1e-12)
        XCTAssertEqual(try number("LOG10", [.number(1)]), 0, accuracy: 1e-12)
    }

    /// `TRUNC` cuts toward zero; `INT` rounds down. They differ on negatives, which
    /// is the only reason both exist.
    func testTruncCutsTowardZero() throws {
        XCTAssertEqual(try number("TRUNC", [.number(8.9)]), 8)
        XCTAssertEqual(try number("TRUNC", [.number(-8.9)]), -8, "TRUNC toward zero")
        XCTAssertEqual(try number("INT", [.number(-8.9)]), -9, "INT rounds down")
        XCTAssertEqual(try number("TRUNC", [.number(3.14159), .number(2)]), 3.14,
                       accuracy: 1e-12)
    }

    func testProductMultipliesEverything() throws {
        XCTAssertEqual(try number("PRODUCT", [.number(2), .number(3), .number(4)]), 24)
        XCTAssertEqual(try number("PRODUCT", [column([2, 3, 4])]), 24)
        XCTAssertEqual(try number("PRODUCT", [.number(5)]), 5)
    }

    /// Text and blanks inside a range are ignored, as with the other aggregates.
    func testProductIgnoresNonNumbersInARange() throws {
        XCTAssertEqual(try number("PRODUCT", [
            .array(CellMatrix(column: [.number(2), .blank, .text("x"), .number(3)])),
        ]), 6)
    }

    func testGreatestCommonDivisor() throws {
        XCTAssertEqual(try number("GCD", [.number(24), .number(36)]), 12)
        XCTAssertEqual(try number("GCD", [.number(7), .number(13)]), 1)
        XCTAssertEqual(try number("GCD", [.number(0), .number(5)]), 5)
    }

    // MARK: - Regression and the normal distribution

    // Microsoft: "SLOPE(known_y's, known_x's)" — **y first**. BusinessMath's
    // `slope(_ x:_ y:)` takes them the other way round, which is the whole of what
    // this binding has to get right: reversed, it returns the slope of x on y, which
    // is a real number, plausibly sized, and wrong.

    func testSlopeOfAPerfectLine() throws {
        // y = 2x + 1 through (1,3) (2,5) (3,7) (4,9): slope 2, intercept 1, exactly.
        let ys = column([3, 5, 7, 9])
        let xs = column([1, 2, 3, 4])
        XCTAssertEqual(try number("SLOPE", [ys, xs]), 2, accuracy: 1e-12)
        XCTAssertEqual(try number("INTERCEPT", [ys, xs]), 1, accuracy: 1e-12)
    }

    /// Microsoft's worked example, published as `0.305556`.
    func testSlopeOnMicrosoftsExample() throws {
        let ys = column([2, 3, 9, 1, 8, 7, 5])
        let xs = column([6, 5, 11, 7, 5, 4, 4])
        XCTAssertEqual(try number("SLOPE", [ys, xs]), 0.3055555555555556, accuracy: 1e-12)
        // Computed from the documented formula on the same data, not quoted.
        XCTAssertEqual(try number("INTERCEPT", [ys, xs]), 3.1666666666666665, accuracy: 1e-12)
    }

    /// Reversing the arguments must change the answer, or the binding is not doing
    /// the one job it exists for.
    func testSlopeIsNotSymmetric() throws {
        let ys = column([2, 3, 9, 1, 8, 7, 5])
        let xs = column([6, 5, 11, 7, 5, 4, 4])
        XCTAssertNotEqual(try number("SLOPE", [ys, xs]),
                          try number("SLOPE", [xs, ys]), accuracy: 1e-9)
    }

    func testSlopeRefusesMismatchedOrEmptyRanges() throws {
        XCTAssertEqual(try function("SLOPE").evaluate([column([1, 2, 3]), column([1, 2])]),
                       .error(.na), "Excel gives #N/A for different-sized ranges")
    }

    /// `NORM.DIST(x, mean, standard_dev, cumulative)`. Microsoft's example:
    /// `NORM.DIST(42, 40, 1.5, TRUE)` is published as `0.908789`.
    func testNormalDistributionCumulative() throws {
        XCTAssertEqual(try number("NORM.DIST", [.number(42), .number(40), .number(1.5),
                                                .bool(true)]),
                       0.9087887802741321, accuracy: 1e-9)
    }

    /// With `cumulative` FALSE it is the density, which peaks at the mean.
    func testNormalDistributionDensity() throws {
        let atMean = try number("NORM.DIST", [.number(40), .number(40), .number(1.5),
                                              .bool(false)])
        let away = try number("NORM.DIST", [.number(43), .number(40), .number(1.5),
                                            .bool(false)])
        XCTAssertGreaterThan(atMean, away)
        // The density at the mean is 1/(σ√2π).
        XCTAssertEqual(atMean, 1 / (1.5 * (2 * Double.pi).squareRoot()), accuracy: 1e-9)
    }

    /// A standard deviation of zero or less is `#NUM!`.
    func testNormalDistributionRefusesANonPositiveDeviation() throws {
        XCTAssertEqual(try function("NORM.DIST").evaluate(
            [.number(1), .number(0), .number(0), .bool(true)]), .error(.num))
    }

    /// `NORM.S.DIST(z, cumulative)` is the same with mean 0 and deviation 1.
    func testStandardNormalDistribution() throws {
        XCTAssertEqual(try number("NORM.S.DIST", [.number(0), .bool(true)]),
                       0.5, accuracy: 1e-12)
        XCTAssertEqual(try number("NORM.S.DIST", [.number(1.333333), .bool(true)]),
                       0.9087887256040951, accuracy: 1e-9)
    }

    /// `NORM.INV` inverts `NORM.DIST`, so the pair must round-trip.
    func testNormalInverseRoundTrips() throws {
        XCTAssertEqual(try number("NORM.INV", [.number(0.5), .number(40), .number(1.5)]),
                       40, accuracy: 1e-9, "the median of a normal is its mean")
        let p = try number("NORM.DIST", [.number(42), .number(40), .number(1.5), .bool(true)])
        XCTAssertEqual(try number("NORM.INV", [.number(p), .number(40), .number(1.5)]),
                       42, accuracy: 1e-6)
    }

    /// "If probability <= 0 or if probability >= 1, NORM.INV returns #NUM!."
    func testNormalInverseRefusesProbabilitiesOutsideTheOpenInterval() throws {
        for p in [0.0, 1.0, -0.1, 1.1] {
            XCTAssertEqual(try function("NORM.INV").evaluate(
                [.number(p), .number(0), .number(1)]), .error(.num), "p = \(p)")
        }
    }

    // MARK: - RANK

    // Microsoft: "Returns the rank of a number in a list of numbers… If order is 0
    // or omitted, Excel ranks number as if ref were a list sorted in descending
    // order." Ties take the *top* rank, and the ranks after a tie are skipped.

    func testRankDescendingByDefault() throws {
        let list = column([10, 20, 30])
        XCTAssertEqual(try number("RANK", [.number(30), list]), 1)
        XCTAssertEqual(try number("RANK", [.number(20), list]), 2)
        XCTAssertEqual(try number("RANK", [.number(10), list]), 3)
    }

    func testRankAscendingWithANonZeroOrder() throws {
        let list = column([10, 20, 30])
        XCTAssertEqual(try number("RANK", [.number(10), list, .number(1)]), 1)
        XCTAssertEqual(try number("RANK", [.number(30), list, .number(1)]), 3)
    }

    /// "If two numbers have the same rank, the presence of that number affects the
    /// ranks of subsequent numbers" — two 30s are both rank 1, and 20 is rank 3.
    func testRankGivesTiesTheTopRankAndSkipsAfter() throws {
        let list = column([30, 30, 20, 10])
        XCTAssertEqual(try number("RANK", [.number(30), list]), 1)
        XCTAssertEqual(try number("RANK", [.number(20), list]), 3, "rank 2 is consumed")
        XCTAssertEqual(try number("RANK", [.number(10), list]), 4)
    }

    /// A number that is not in the list is `#N/A`.
    func testRankOfSomethingAbsentIsNotAvailable() throws {
        XCTAssertEqual(try function("RANK").evaluate([.number(99), column([1, 2, 3])]),
                       .error(.na))
    }

    /// `RANK.EQ` is the modern spelling of exactly this behaviour.
    func testRankEqMatchesRank() throws {
        let list = column([30, 30, 20, 10])
        XCTAssertEqual(try number("RANK.EQ", [.number(20), list]),
                       try number("RANK", [.number(20), list]))
    }

    // MARK: - GETPIVOTDATA

    // `GETPIVOTDATA(data_field, pivot_table, [field, item]…)` reads a value out of a
    // PivotTable report. The number is not computed from the arguments — it is looked
    // up in a pivot cache, which lives in `xl/pivotCache/` and which this family does
    // not read. Pivot caches are out of scope.
    //
    // So it answers `#REF!`, which is what Excel itself answers when the PivotTable
    // being pointed at is not available. That is the honest report of our situation
    // rather than a stand-in: the pivot table really is not here.
    //
    // Deliberately not `#NAME?`. The function exists and its name is known; what is
    // missing is the data it reads, and those are different failures. A caller
    // debugging a sheet needs to know which.

    func testGetPivotDataReportsAMissingPivotTable() throws {
        XCTAssertEqual(try function("GETPIVOTDATA").evaluate(
            [.text("Sales"), .text("$A$3")]), .error(.ref))
        XCTAssertEqual(try function("GETPIVOTDATA").evaluate(
            [.text("Sales"), .text("$A$3"), .text("Region"), .text("North")]),
            .error(.ref))
    }

    /// It is registered, so a workbook full of it reads as a known function that
    /// cannot resolve rather than an unknown name.
    func testGetPivotDataIsRegistered() {
        XCTAssertNotNil(FunctionRegistry.builtin.function(named: "GETPIVOTDATA"))
    }

    /// An error argument still propagates, so the first failure is the one reported.
    func testGetPivotDataPropagatesAnError() throws {
        XCTAssertEqual(try function("GETPIVOTDATA").evaluate(
            [.error(.name), .text("$A$3")]), .error(.name))
    }

    // MARK: - Error propagation

    // Excel propagates an error through a function rather than absorbing it: if an
    // argument is `#NAME?`, the result is `#NAME?`. Only the functions built to trap
    // errors — `IFERROR`, `ISERROR`, `IFNA` — see one and carry on. That is what
    // makes an error traceable to where it started instead of turning into a
    // different error somewhere downstream.
    //
    // Found in the corpus: `HLOOKUP(AA40, Efficiency!$E$3:$DA$6, $D$2)` where `AA40`
    // is itself cached `#NAME?` — one of 337 such cells on that sheet. Excel caches
    // `#NAME?`; we answered `#N/A`, which says "looked and did not find" about a
    // lookup that never happened.

    func testTheLookupsPropagateAnErrorLookupValue() throws {
        let table = grid([[.number(1), .text("a")], [.number(2), .text("b")]])
        for name in ["VLOOKUP", "HLOOKUP"] {
            XCTAssertEqual(
                try function(name).evaluate([.error(.name), table, .number(2), .bool(false)]),
                .error(.name), name)
        }
        XCTAssertEqual(try function("MATCH").evaluate([.error(.name), table, .number(0)]),
                       .error(.name))
    }

    func testTheLookupsPropagateAnErrorTable() throws {
        for name in ["VLOOKUP", "HLOOKUP"] {
            XCTAssertEqual(
                try function(name).evaluate([.number(1), .error(.div0), .number(2), .bool(false)]),
                .error(.div0), name)
        }
    }

    func testTheLookupsPropagateAnErrorIndex() throws {
        let table = grid([[.number(1), .text("a")], [.number(2), .text("b")]])
        for name in ["VLOOKUP", "HLOOKUP"] {
            XCTAssertEqual(
                try function(name).evaluate([.number(1), table, .error(.value), .bool(false)]),
                .error(.value), name)
        }
    }

    /// The first error wins, so the result names the failure nearest the start of
    /// the argument list rather than whichever the implementation happened to test.
    func testTheFirstErrorArgumentIsTheOneReturned() throws {
        XCTAssertEqual(
            try function("VLOOKUP").evaluate([.error(.na), .error(.div0), .number(2)]),
            .error(.na))
    }

    /// `INDEX` already did this, and must keep doing it.
    func testIndexPropagatesAnError() throws {
        let table = grid([[.number(1), .text("a")]])
        XCTAssertEqual(try function("INDEX").evaluate([.error(.ref), .number(1)]), .error(.ref))
        XCTAssertEqual(try function("INDEX").evaluate([table, .error(.ref)]), .error(.ref))
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
