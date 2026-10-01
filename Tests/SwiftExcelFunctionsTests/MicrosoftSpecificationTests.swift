import Foundation
import Testing
import SwiftExcelCore
import SwiftXLSX
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
@Suite struct MicrosoftSpecificationTests {

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
        throw TestFailure("\(name) is not registered")
    }

    private func number(_ name: String, _ args: [CellValue]) throws -> Double {
        let result = try function(name).evaluate(args)
        guard case .number(let value) = result else {
            Issue.record("\(name) answered \(result), not a number")
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
    @Test func npvDiscountsTheFirstValueOnePeriod() throws {
        let value = try number("NPV", [.number(0.1), .number(-10000), .number(3000),
                                       .number(4200), .number(6800)])
        #expect(abs(value - 1188.4434123352212) <= 1e-9)
    }

    /// The same cash flows as one range, which is how a worksheet writes it.
    ///
    /// Microsoft's own examples use both forms — `=NPV(A2, A3, A4, A5, A6)` and
    /// `=NPV(A2, A4:A8)+A3` — so a reference argument is not an edge case, it is the
    /// ordinary case. The corpus oracle found 126 disagreements here.
    @Test func npvAcceptsARangeAsOneArgument() throws {
        let value = try number("NPV", [.number(0.1),
                                       column([-10000, 3000, 4200, 6800])])
        #expect(abs(value - 1188.4434123352212) <= 1e-9)
    }

    /// Microsoft's second example: `=NPV(0.08, A4:A8) + A3`, published as `$1,922.06`
    /// with `A3 = -40000` held outside because it falls at period 0.
    @Test func npvWithAnInitialOutlayOutsideTheFunction() throws {
        let value = try number("NPV", [.number(0.08),
                                       column([8000, 9200, 10000, 12000, 14500])])
        #expect(abs((value - 40000) - 1922.061554932363) <= 1e-9)
    }

    /// Microsoft's third: `=NPV(0.08, A4:A8, -9000) + A3`, published as `($3,749.47)`.
    /// A trailing scalar after a range extends the series by one more period.
    @Test func npvMixesARangeAndAScalar() throws {
        let value = try number("NPV", [.number(0.08),
                                       column([8000, 9200, 10000, 12000, 14500]),
                                       .number(-9000)])
        #expect(abs((value - 40000) - -3749.4650870155747) <= 1e-9)
    }

    /// Microsoft: "If an argument is an array or reference, only numbers in that
    /// array or reference are counted. Empty cells, logical values, text, or error
    /// values in the array or reference are ignored."
    ///
    /// Ignored, not zero — a blank in the middle of a column must not consume a
    /// period, or every cash flow after it is discounted one period too far.
    @Test func npvIgnoresNonNumbersInsideARange() throws {
        let clean = try number("NPV", [.number(0.1), column([100, 200, 300])])
        let withNoise = try number("NPV", [
            .number(0.1),
            .array(CellMatrix(column: [.number(100), .blank, .number(200),
                                       .text("n/a"), .number(300), .bool(true)])),
        ])
        #expect(abs(withNoise - clean) <= 1e-9, "a blank must not shift the periods after it")
    }

    /// The order of the arguments is the order of the cash flows, so reversing them
    /// must change the answer. Guards against an implementation that sums first.
    @Test func npvIsOrderDependent() throws {
        let forward = try number("NPV", [.number(0.1), column([100, 200, 300])])
        let backward = try number("NPV", [.number(0.1), column([300, 200, 100])])
        #expect(abs(forward - backward) > 1e-9)
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
    @Test func yearFracThirtyThreeSixtyOnCleanDates() throws {
        #expect(try abs(number("YEARFRAC", [.number(Self.jan1_2026),
                                               .number(Self.jul1_2026), .number(0)]) - 0.5) <= 1e-12)
    }

    /// Basis 3 counts real days over 365: 1 January to 1 July 2026 is 181 days.
    ///
    /// This interval crosses a daylight-saving boundary, which is the whole reason it
    /// is the one being asserted. BusinessMath once measured elapsed time through a
    /// calendar in the machine's local zone, so the answer was 181.0417 days — an
    /// extra hour, invisible in UTC and invisible in a zone with no DST, which is how
    /// it survived long enough to move every actual/360 and actual/365 accrual by two
    /// parts in ten thousand. Fixed in BusinessMath 2.14.0.
    ///
    /// Keep the date pair. A test that never crosses a boundary cannot see this
    /// defect come back.
    @Test func yearFracActual365CountsRealDays() throws {
        #expect(try abs(number("YEARFRAC", [.number(Self.jan1_2026),
                                               .number(Self.jul1_2026), .number(3)]) - (181.0 / 365.0)) <= 1e-12)
    }

    /// Basis 2 is the same day count over 360, and carried the same hour.
    @Test func yearFracActual360() throws {
        #expect(try abs(number("YEARFRAC", [.number(Self.jan1_2026),
                                               .number(Self.jul1_2026), .number(2)]) - (181.0 / 360.0)) <= 1e-12)
    }

    /// The same interval within one side of a DST change is exact, which is what
    /// isolates the cause. 1 January to 1 March 2026 is 59 days and never crosses.
    @Test func yearFracActual365IsExactWithinOneOffset() throws {
        let mar1_2026 = 46082.0   // 2026-03-01
        #expect(try abs(number("YEARFRAC", [.number(Self.jan1_2026),
                                               .number(mar1_2026), .number(3)]) - (59.0 / 365.0)) <= 1e-12)
    }

    /// **The NASD February rule.** The last day of February counts as a 30th, and
    /// the pull-back of an end date on the 31st tests the start day *before* that
    /// adjustment.
    ///
    /// 2020-02-29 to 2020-12-31 is 301/360. Adjusting February first and then
    /// testing the pull-back gives 300; applying neither gives 302. Excel's own
    /// cached value for this pair, in a corpus workbook, is 0.83611111111111114.
    ///
    /// Fixed in BusinessMath 2.15.0 — see `testTheFebruaryEndOfMonthRule`, which
    /// holds the same case with its provenance.
    @Test func yearFracFebruaryMonthEndIsThirty() throws {
        #expect(try abs(number("YEARFRAC", [.number(Self.feb29_2020),
                                               .number(Self.dec31_2020), .number(0)]) - (301.0 / 360.0)) <= 1e-12)
    }

    /// The common-year half of the same rule: 28 February is the month end too.
    ///
    /// **151 days, not 150** — and the difference is the whole point of the rule.
    /// February pulls the *start* day to a 30th, but Excel tests the end-date
    /// pull-back against the day as originally written. 28 is below 30, so 31 July
    /// stays a 31st:
    ///
    /// ```
    /// 30·(7−2) + (31 − 30) = 151
    /// ```
    ///
    /// Identical in structure to the leap-year case above, where 29 February to
    /// 31 December is 30·10 + (31−30) = 301 — and that one is pinned to Excel's own
    /// cached value in a corpus workbook. An expectation of 150 here would assume the
    /// end date *is* pulled back, contradicting the case that has the evidence.
    @Test func yearFracCommonYearFebruaryMonthEnd() throws {
        #expect(try abs(number("YEARFRAC", [.number(Self.feb28_2021),
                                               .number(Self.jul31_2021), .number(0)]) - (151.0 / 360.0)) <= 1e-12)
    }

    /// Basis 4, European 30/360: every month is thirty days, with no February rule
    /// and no end-of-month pull-back. 1 January to 1 July 2026 is six months.
    ///
    /// The only basis with no outstanding defect behind it.
    @Test func yearFracEuropeanThirtyThreeSixty() throws {
        #expect(try abs(number("YEARFRAC", [.number(Self.jan1_2026),
                                               .number(Self.jul1_2026), .number(4)]) - 0.5) <= 1e-12)
    }

    /// Basis 1 within a single calendar year divides by that year's length. 2026 is
    /// not a leap year, so 1 January to 1 July is 181/365.
    ///
    /// Carried the same daylight-saving hour as bases 2 and 3 — `actualActual` was
    /// added in BusinessMath 2.11.0 on top of the same elapsed-time measurement, and
    /// was fixed with them in 2.14.0.
    @Test func yearFracActualActualWithinOneYear() throws {
        #expect(try abs(number("YEARFRAC", [.number(Self.jan1_2026),
                                               .number(Self.jul1_2026), .number(1)]) - (181.0 / 365.0)) <= 1e-12)
    }

    /// A basis Excel does not define is `#NUM!`.
    @Test func yearFracRefusesAnUndefinedBasis() throws {
        #expect(try function("YEARFRAC").evaluate([
            .number(Self.jan1_2026), .number(Self.jul1_2026), .number(5),
        ]) == .error(.num))
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
            Issue.record("ragged table")
            return .error(.value)
        }
        return .array(matrix)
    }

    @Test func vlookupApproximateTakesTheNextSmallest() throws {
        let table = grid([[.number(10), .text("ten")],
                          [.number(20), .text("twenty")],
                          [.number(30), .text("thirty")]])
        #expect(try function("VLOOKUP").evaluate(
            [.number(25), table, .number(2), .bool(true)]) == .text("twenty"))
    }

    /// Below the first key there is no smaller value, so `#N/A`.
    @Test func vlookupApproximateBelowTheFirstKeyIsNotAvailable() throws {
        let table = grid([[.number(10), .text("ten")], [.number(20), .text("twenty")]])
        #expect(try function("VLOOKUP").evaluate(
            [.number(5), table, .number(2), .bool(true)]) == .error(.na))
    }

    @Test func vlookupExactRefusesANearMiss() throws {
        let table = grid([[.number(10), .text("ten")], [.number(20), .text("twenty")]])
        #expect(try function("VLOOKUP").evaluate(
            [.number(15), table, .number(2), .bool(false)]) == .error(.na))
    }

    /// Microsoft: "If col_index_num is greater than the number of columns in
    /// table_array, VLOOKUP returns the #REF! error value."
    @Test func vlookupPastTheTableIsARefError() throws {
        let table = grid([[.number(10), .text("ten")]])
        #expect(try function("VLOOKUP").evaluate(
            [.number(10), table, .number(3), .bool(false)]) == .error(.ref))
    }

    /// And "if col_index_num is less than 1, VLOOKUP returns #VALUE!".
    @Test func vlookupBelowTheFirstColumnIsAValueError() throws {
        let table = grid([[.number(10), .text("ten")]])
        #expect(try function("VLOOKUP").evaluate(
            [.number(10), table, .number(0), .bool(false)]) == .error(.value))
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

    @Test func xlookupFindsAnExactMatch() throws {
        #expect(try function("XLOOKUP").evaluate([
            .text("b"),
            row([.text("a"), .text("b"), .text("c")]),
            row([.number(1), .number(2), .number(3)]),
        ]) == .number(2))
    }

    /// **The default is exact**, the reverse of `VLOOKUP`. A near miss is `#N/A`
    /// rather than the next smallest, which is the single most consequential
    /// difference between them.
    @Test func xlookupDefaultsToExact() throws {
        #expect(try function("XLOOKUP").evaluate([
            .number(25),
            row([.number(10), .number(20), .number(30)]),
            row([.text("ten"), .text("twenty"), .text("thirty")]),
        ]) == .error(.na))
    }

    /// `if_not_found` replaces the `IFERROR` wrapper VLOOKUP needed.
    @Test func xlookupReturnsWhatYouAskForWhenNothingMatches() throws {
        #expect(try function("XLOOKUP").evaluate([
            .number(25),
            row([.number(10), .number(20)]),
            row([.text("ten"), .text("twenty")]),
            .text("none"),
        ]) == .text("none"))
    }

    /// `match_mode` −1 is exact or next smaller, 1 is exact or next larger.
    @Test func xlookupApproximateModes() throws {
        let keys = row([.number(10), .number(20), .number(30)])
        let results = row([.text("ten"), .text("twenty"), .text("thirty")])
        #expect(try function("XLOOKUP").evaluate(
            [.number(25), keys, results, .text("none"), .number(-1)]) == .text("twenty"))
        #expect(try function("XLOOKUP").evaluate(
            [.number(25), keys, results, .text("none"), .number(1)]) == .text("thirty"))
    }

    /// **The result may sit before the key.** `VLOOKUP` cannot do this at all: its
    /// offset counts rightwards from the key column, so a leftward answer needs
    /// `INDEX`/`MATCH`. Here the two ranges are independent.
    @Test func xlookupReturnsAColumnLeftOfTheKey() throws {
        #expect(try function("XLOOKUP").evaluate([
            .text("b"),
            row([.text("a"), .text("b")]),      // keys, notionally column B
            row([.number(1), .number(2)]),      // results, notionally column A
        ]) == .number(2))
    }

    /// `search_mode` −1 searches last to first, so a duplicated key answers with the
    /// later of the two.
    @Test func xlookupCanSearchBackwards() throws {
        let keys = row([.text("a"), .text("b"), .text("a")])
        let results = row([.number(1), .number(2), .number(3)])
        #expect(try function("XLOOKUP").evaluate(
            [.text("a"), keys, results, .text("none"), .number(0), .number(1)]) == .number(1))
        #expect(try function("XLOOKUP").evaluate(
            [.text("a"), keys, results, .text("none"), .number(0), .number(-1)]) == .number(3))
    }

    /// Mismatched ranges are `#VALUE!`: there is no answer to give.
    @Test func xlookupRefusesMismatchedRanges() throws {
        #expect(try function("XLOOKUP").evaluate([
            .text("a"),
            row([.text("a"), .text("b"), .text("c")]),
            row([.number(1), .number(2)]),
        ]) == .error(.value))
    }

    /// Wildcard matching is refused rather than silently treated as exact, which
    /// would find the wrong row and say nothing about it.
    @Test func xlookupRefusesWildcardMode() throws {
        #expect(try function("XLOOKUP").evaluate([
            .text("a*"),
            row([.text("abc")]), row([.number(1)]),
            .text("none"), .number(2),
        ]) == .error(.value))
    }

    /// An error in the lookup propagates — but not one in `if_not_found`, whose
    /// whole purpose is to be produced when the lookup fails.
    @Test func xlookupPropagatesButHonoursIfNotFound() throws {
        #expect(try function("XLOOKUP").evaluate([
            .error(.name), row([.text("a")]), row([.number(1)]),
        ]) == .error(.name))
        #expect(try function("XLOOKUP").evaluate([
            .text("z"), row([.text("a")]), row([.number(1)]), .error(.na),
        ]) == .error(.na), "an error is a legitimate thing to ask for on failure")
    }

    /// It resolves through `_xlfn.`, which is how an older `.xlsx` carries it.
    @Test func xlookupResolvesThroughTheModernPrefix() {
        #expect(FunctionRegistry.builtin.resolvedName("_xlfn.XLOOKUP") == "XLOOKUP")
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
    @Test func xirrReturnsAnActualRoot() throws {
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
        #expect(abs(residue - 0) <= 1e-6, "the returned rate must actually zero the discounted flows")
        #expect(rate > 0.09)
        #expect(rate < 0.11)
    }

    // MARK: - Text

    // Microsoft on the pair that trips everyone: FIND is case-sensitive and takes no
    // wildcards; SEARCH is case-insensitive and does. Both are 1-based, both return
    // #VALUE! when the text is not there, and both count characters rather than bytes.

    private func text(_ name: String, _ args: CellValue...) throws -> CellValue {
        try function(name).evaluate(args)
    }

    @Test func findIsOneBasedAndCaseSensitive() throws {
        #expect(try text("FIND", .text("M"), .text("Miriam McGovern")) == .number(1))
        #expect(try text("FIND", .text("m"), .text("Miriam McGovern")) == .number(6))
        #expect(try text("FIND", .text("M"), .text("Miriam McGovern"), .number(3)) == .number(8))
    }

    /// Microsoft: "If find_text does not appear in within_text, FIND returns the
    /// #VALUE! error value."
    @Test func findReturnsValueErrorWhenAbsent() throws {
        #expect(try text("FIND", .text("z"), .text("abc")) == .error(.value))
    }

    /// "If find_text is empty, FIND matches the first character in the search
    /// string" — so it returns start_num rather than failing.
    @Test func findWithEmptyNeedleReturnsTheStart() throws {
        #expect(try text("FIND", .text(""), .text("abc")) == .number(1))
        #expect(try text("FIND", .text(""), .text("abc"), .number(2)) == .number(2))
    }

    /// "If start_num is not greater than zero, or is greater than the length of
    /// within_text, FIND returns #VALUE!."
    @Test func findRejectsAnOutOfRangeStart() throws {
        #expect(try text("FIND", .text("a"), .text("abc"), .number(0)) == .error(.value))
        #expect(try text("FIND", .text("a"), .text("abc"), .number(4)) == .error(.value))
    }

    @Test func searchIsCaseInsensitive() throws {
        #expect(try text("SEARCH", .text("m"), .text("Miriam McGovern")) == .number(1))
        #expect(try text("SEARCH", .text("M"), .text("Miriam McGovern")) == .number(1))
    }

    /// SEARCH takes `?` for one character and `*` for any run of them.
    @Test func searchTakesWildcards() throws {
        #expect(try text("SEARCH", .text("b?d"), .text("abcde")) == .number(2))
        #expect(try text("SEARCH", .text("a*e"), .text("abcde")) == .number(1))
        #expect(try text("SEARCH", .text("x*z"), .text("abcde")) == .error(.value))
    }

    // Microsoft on SUBSTITUTE: "Substitutes new_text for old_text in a text string.
    // Use SUBSTITUTE when you want to replace specific text… If instance_num is
    // specified, only that instance is replaced."

    @Test func substituteReplacesEveryInstance() throws {
        #expect(try text("SUBSTITUTE", .text("Sales Data"), .text("Sales"),
                                .text("Cost")) == .text("Cost Data"))
        #expect(try text("SUBSTITUTE", .text("a-b-c"), .text("-"), .text("+")) == .text("a+b+c"))
    }

    @Test func substituteReplacesOnlyTheNamedInstance() throws {
        // Microsoft's own example: Quarter 1, 2011 -> Quarter 2, 2011
        #expect(try text("SUBSTITUTE", .text("Quarter 1, 2011"), .text("1"),
                                .text("2"), .number(1)) == .text("Quarter 2, 2011"))
        #expect(try text("SUBSTITUTE", .text("a-b-c"), .text("-"), .text("+"),
                                .number(2)) == .text("a-b+c"))
    }

    /// "SUBSTITUTE is case-sensitive" — unlike REPLACE, which works by position.
    @Test func substituteIsCaseSensitive() throws {
        #expect(try text("SUBSTITUTE", .text("aAa"), .text("a"), .text("z")) == .text("zAz"))
    }

    /// An instance number beyond the count changes nothing, rather than erroring.
    @Test func substituteWithATooLargeInstanceIsUnchanged() throws {
        #expect(try text("SUBSTITUTE", .text("a-b"), .text("-"), .text("+"),
                                .number(5)) == .text("a-b"))
    }

    /// Empty old_text leaves the string alone; Excel has nothing to find.
    @Test func substituteWithEmptyOldTextIsUnchanged() throws {
        #expect(try text("SUBSTITUTE", .text("abc"), .text(""), .text("z")) == .text("abc"))
    }

    @Test func properCapitalisesEachWord() throws {
        #expect(try text("PROPER", .text("this is a TITLE")) == .text("This Is A Title"))
        #expect(try text("PROPER", .text("2-cent's worth")) == .text("2-Cent'S Worth"), "Excel breaks on the apostrophe too")
    }

    /// CLEAN removes the non-printing characters 0–31.
    @Test func cleanRemovesControlCharacters() throws {
        #expect(try text("CLEAN", .text("a\u{07}b\u{07}c")) == .text("abc"))
        #expect(try text("CLEAN", .text("plain")) == .text("plain"))
    }

    /// NUMBERVALUE reads a number from text using explicit separators, so it does
    /// not depend on the machine's locale.
    @Test func numberValueUsesTheSeparatorsItIsGiven() throws {
        #expect(try text("NUMBERVALUE", .text("2.500,27"), .text(","), .text(".")) == .number(2500.27))
        #expect(try text("NUMBERVALUE", .text("3.5")) == .number(3.5))
    }

    /// "If empty, an empty string is used" — an empty argument is 0, not an error.
    @Test func numberValueOfEmptyIsZero() throws {
        #expect(try text("NUMBERVALUE", .text("")) == .number(0))
    }

    @Test func numberValueRefusesWhatIsNotANumber() throws {
        #expect(try text("NUMBERVALUE", .text("abc")) == .error(.value))
    }

    // MARK: - Dates and references

    /// `WORKDAY(start, days, [holidays])` — a date a number of working days away,
    /// counting Monday to Friday and skipping any holidays given.
    ///
    /// Microsoft's own example: 2008-10-01 plus 151 working days is 2009-04-30, and
    /// with the four holidays listed it becomes 2009-05-06.
    @Test func workdaySkipsWeekends() throws {
        // 2026-01-01 is a Thursday; one working day on is Friday the 2nd,
        // two is Monday the 5th.
        let jan1 = 46023.0
        #expect(try number("WORKDAY", [.number(jan1), .number(1)]).isEqual(to: (jan1 + 1)))
        #expect(try number("WORKDAY", [.number(jan1), .number(2)]).isEqual(to: (jan1 + 4)))
    }

    @Test func workdayCountsBackwards() throws {
        // 2026-01-05 is a Monday; one working day back is Friday the 2nd.
        let jan5 = 46027.0
        #expect(try number("WORKDAY", [.number(jan5), .number(-1)]).isEqual(to: (jan5 - 3)))
    }

    @Test func workdaySkipsHolidays() throws {
        let jan1 = 46023.0    // Thursday
        // With Friday the 2nd a holiday, one working day on is Monday the 5th.
        #expect(try number("WORKDAY", [.number(jan1), .number(1), .array(CellMatrix(column: [.number(jan1 + 1)]))]).isEqual(to: (jan1 + 4)))
    }

    /// Zero days stays put, even on a weekend — Excel does not snap to a workday.
    @Test func workdayWithZeroDaysStaysPut() throws {
        let jan3 = 46025.0   // Saturday
        #expect(try number("WORKDAY", [.number(jan3), .number(0)]).isEqual(to: jan3))
    }

    /// `DATEVALUE(text)` — the serial for a date written as text.
    @Test func dateValueReadsATextDate() throws {
        #expect(try number("DATEVALUE", [.text("2026-01-01")]).isEqual(to: 46023))
        #expect(try number("DATEVALUE", [.text("1/1/2026")]).isEqual(to: 46023))
    }

    @Test func dateValueRefusesWhatIsNotADate() throws {
        #expect(try function("DATEVALUE").evaluate([.text("not a date")]) == .error(.value))
    }

    /// `TIME(hour, minute, second)` — a fraction of a day, so noon is 0.5.
    @Test func timeIsAFractionOfADay() throws {
        #expect(try abs(number("TIME", [.number(12), .number(0), .number(0)]) - 0.5) <= 1e-12)
        #expect(try abs(number("TIME", [.number(6), .number(0), .number(0)]) - 0.25) <= 1e-12)
    }

    /// "If hour is greater than 23, it is divided by 24 and the remainder is
    /// treated as the hour value."
    @Test func timeWrapsPastMidnight() throws {
        #expect(try abs(number("TIME", [.number(27), .number(0), .number(0)]) - 0.125) <= 1e-12)
    }

    /// `ROWS` and `COLUMNS` count a range's shape — which the value now carries.
    @Test func rowsAndColumnsCountTheShape() throws {
        let block = grid([[.number(1), .number(2), .number(3)],
                          [.number(4), .number(5), .number(6)]])
        #expect(try number("ROWS", [block]).isEqual(to: 2))
        #expect(try number("COLUMNS", [block]).isEqual(to: 3))
        #expect(try number("ROWS", [.number(1)]).isEqual(to: 1), "a lone value is 1x1")
        #expect(try number("COLUMNS", [.number(1)]).isEqual(to: 1))
    }

    /// `HYPERLINK(location, [friendly_name])` displays the friendly name, or the
    /// location when there is none. The jump is a UI act; the value is text.
    @Test func hyperlinkShowsItsFriendlyName() throws {
        #expect(try function("HYPERLINK").evaluate(
            [.text("https://example.com"), .text("Example")]) == .text("Example"))
        #expect(try function("HYPERLINK").evaluate([.text("https://example.com")]) == .text("https://example.com"))
    }

    // MARK: - Foundation maths

    // Bridged rather than reimplemented: these are libm's, and a second
    // implementation of a sine would be a liability with no upside.

    @Test func trigonometryIsInRadians() throws {
        #expect(try abs(number("SIN", [.number(0)]) - 0) <= 1e-12)
        #expect(try abs(number("COS", [.number(0)]) - 1) <= 1e-12)
        let pi = try number("PI", [])
        #expect(try abs(number("SIN", [.number(pi / 2)]) - 1) <= 1e-12)
        #expect(try abs(number("COS", [.number(pi)]) - -1) <= 1e-12)
        #expect(try abs(number("TAN", [.number(0)]) - 0) <= 1e-12)
    }

    @Test func logBaseTen() throws {
        #expect(try abs(number("LOG10", [.number(1000)]) - 3) <= 1e-12)
        #expect(try abs(number("LOG10", [.number(1)]) - 0) <= 1e-12)
    }

    /// `TRUNC` cuts toward zero; `INT` rounds down. They differ on negatives, which
    /// is the only reason both exist.
    @Test func truncCutsTowardZero() throws {
        #expect(try number("TRUNC", [.number(8.9)]).isEqual(to: 8))
        #expect(try number("TRUNC", [.number(-8.9)]).isEqual(to: -8), "TRUNC toward zero")
        #expect(try number("INT", [.number(-8.9)]).isEqual(to: -9), "INT rounds down")
        #expect(try abs(number("TRUNC", [.number(3.14159), .number(2)]) - 3.14) <= 1e-12)
    }

    @Test func productMultipliesEverything() throws {
        #expect(try number("PRODUCT", [.number(2), .number(3), .number(4)]).isEqual(to: 24))
        #expect(try number("PRODUCT", [column([2, 3, 4])]).isEqual(to: 24))
        #expect(try number("PRODUCT", [.number(5)]).isEqual(to: 5))
    }

    /// Text and blanks inside a range are ignored, as with the other aggregates.
    @Test func productIgnoresNonNumbersInARange() throws {
        #expect(try number("PRODUCT", [ .array(CellMatrix(column: [.number(2), .blank, .text("x"), .number(3)])), ]).isEqual(to: 6))
    }

    @Test func greatestCommonDivisor() throws {
        #expect(try number("GCD", [.number(24), .number(36)]).isEqual(to: 12))
        #expect(try number("GCD", [.number(7), .number(13)]).isEqual(to: 1))
        #expect(try number("GCD", [.number(0), .number(5)]).isEqual(to: 5))
    }

    // MARK: - Regression and the normal distribution

    // Microsoft: "SLOPE(known_y's, known_x's)" — **y first**. BusinessMath's
    // `slope(_ x:_ y:)` takes them the other way round, which is the whole of what
    // this binding has to get right: reversed, it returns the slope of x on y, which
    // is a real number, plausibly sized, and wrong.

    @Test func slopeOfAPerfectLine() throws {
        // y = 2x + 1 through (1,3) (2,5) (3,7) (4,9): slope 2, intercept 1, exactly.
        let ys = column([3, 5, 7, 9])
        let xs = column([1, 2, 3, 4])
        #expect(try abs(number("SLOPE", [ys, xs]) - 2) <= 1e-12)
        #expect(try abs(number("INTERCEPT", [ys, xs]) - 1) <= 1e-12)
    }

    /// Microsoft's worked example, published as `0.305556`.
    @Test func slopeOnMicrosoftsExample() throws {
        let ys = column([2, 3, 9, 1, 8, 7, 5])
        let xs = column([6, 5, 11, 7, 5, 4, 4])
        #expect(try abs(number("SLOPE", [ys, xs]) - 0.3055555555555556) <= 1e-12)
        // Computed from the documented formula on the same data, not quoted.
        #expect(try abs(number("INTERCEPT", [ys, xs]) - 3.1666666666666665) <= 1e-12)
    }

    /// Reversing the arguments must change the answer, or the binding is not doing
    /// the one job it exists for.
    @Test func slopeIsNotSymmetric() throws {
        let ys = column([2, 3, 9, 1, 8, 7, 5])
        let xs = column([6, 5, 11, 7, 5, 4, 4])
        #expect(try abs(number("SLOPE", [ys, xs]) - number("SLOPE", [xs, ys])) > 1e-9)
    }

    @Test func slopeRefusesMismatchedOrEmptyRanges() throws {
        #expect(try function("SLOPE").evaluate([column([1, 2, 3]), column([1, 2])]) == .error(.na), "Excel gives #N/A for different-sized ranges")
    }

    /// `NORM.DIST(x, mean, standard_dev, cumulative)`. Microsoft's example:
    /// `NORM.DIST(42, 40, 1.5, TRUE)` is published as `0.908789`.
    @Test func normalDistributionCumulative() throws {
        #expect(try abs(number("NORM.DIST", [.number(42), .number(40), .number(1.5),
                                                .bool(true)]) - 0.9087887802741321) <= 1e-9)
    }

    /// With `cumulative` FALSE it is the density, which peaks at the mean.
    @Test func normalDistributionDensity() throws {
        let atMean = try number("NORM.DIST", [.number(40), .number(40), .number(1.5),
                                              .bool(false)])
        let away = try number("NORM.DIST", [.number(43), .number(40), .number(1.5),
                                            .bool(false)])
        #expect(atMean > away)
        // The density at the mean is 1/(σ√2π).
        #expect(abs(atMean - (1 / (1.5 * (2 * Double.pi).squareRoot()))) <= 1e-9)
    }

    /// A standard deviation of zero or less is `#NUM!`.
    @Test func normalDistributionRefusesANonPositiveDeviation() throws {
        #expect(try function("NORM.DIST").evaluate(
            [.number(1), .number(0), .number(0), .bool(true)]) == .error(.num))
    }

    /// `NORM.S.DIST(z, cumulative)` is the same with mean 0 and deviation 1.
    @Test func standardNormalDistribution() throws {
        #expect(try abs(number("NORM.S.DIST", [.number(0), .bool(true)]) - 0.5) <= 1e-12)
        #expect(try abs(number("NORM.S.DIST", [.number(1.333333), .bool(true)]) - 0.9087887256040951) <= 1e-9)
    }

    /// `NORM.INV` inverts `NORM.DIST`, so the pair must round-trip.
    @Test func normalInverseRoundTrips() throws {
        #expect(try abs(number("NORM.INV", [.number(0.5), .number(40), .number(1.5)]) - 40) <= 1e-9, "the median of a normal is its mean")
        let p = try number("NORM.DIST", [.number(42), .number(40), .number(1.5), .bool(true)])
        #expect(try abs(number("NORM.INV", [.number(p), .number(40), .number(1.5)]) - 42) <= 1e-6)
    }

    /// "If probability <= 0 or if probability >= 1, NORM.INV returns #NUM!."
    @Test func normalInverseRefusesProbabilitiesOutsideTheOpenInterval() throws {
        for p in [0.0, 1.0, -0.1, 1.1] {
            #expect(try function("NORM.INV").evaluate(
                [.number(p), .number(0), .number(1)]) == .error(.num), "p = \(p)")
        }
    }

    // MARK: - RANK

    // Microsoft: "Returns the rank of a number in a list of numbers… If order is 0
    // or omitted, Excel ranks number as if ref were a list sorted in descending
    // order." Ties take the *top* rank, and the ranks after a tie are skipped.

    @Test func rankDescendingByDefault() throws {
        let list = column([10, 20, 30])
        #expect(try number("RANK", [.number(30), list]).isEqual(to: 1))
        #expect(try number("RANK", [.number(20), list]).isEqual(to: 2))
        #expect(try number("RANK", [.number(10), list]).isEqual(to: 3))
    }

    @Test func rankAscendingWithANonZeroOrder() throws {
        let list = column([10, 20, 30])
        #expect(try number("RANK", [.number(10), list, .number(1)]).isEqual(to: 1))
        #expect(try number("RANK", [.number(30), list, .number(1)]).isEqual(to: 3))
    }

    /// "If two numbers have the same rank, the presence of that number affects the
    /// ranks of subsequent numbers" — two 30s are both rank 1, and 20 is rank 3.
    @Test func rankGivesTiesTheTopRankAndSkipsAfter() throws {
        let list = column([30, 30, 20, 10])
        #expect(try number("RANK", [.number(30), list]).isEqual(to: 1))
        #expect(try number("RANK", [.number(20), list]).isEqual(to: 3), "rank 2 is consumed")
        #expect(try number("RANK", [.number(10), list]).isEqual(to: 4))
    }

    /// A number that is not in the list is `#N/A`.
    @Test func rankOfSomethingAbsentIsNotAvailable() throws {
        #expect(try function("RANK").evaluate([.number(99), column([1, 2, 3])]) == .error(.na))
    }

    /// `RANK.EQ` is the modern spelling of exactly this behaviour.
    @Test func rankEqMatchesRank() throws {
        let list = column([30, 30, 20, 10])
        #expect(try number("RANK.EQ", [.number(20), list]).isEqual(to: number("RANK", [.number(20), list])))
    }

    // MARK: - GETPIVOTDATA

    // `GETPIVOTDATA(data_field, pivot_table, [field, item]…)` reads a value out of a
    // PivotTable report. It is **not** looked up in a pivot cache, which is what this
    // note used to say: a pivot's values are already rendered onto the worksheet and
    // cached there, so the function reads a table that is already present and
    // `xl/pivotCache/` is never opened.
    //
    // It still answers `#REF!` wherever it cannot resolve — a cell in no pivot, a data
    // field the table does not have, a table rendering no grand total — which is what
    // Excel answers when the PivotTable pointed at is not available.
    //
    // Deliberately not `#NAME?`. The function exists and its name is known; what is
    // missing is the data it reads, and those are different failures. A caller
    // debugging a sheet needs to know which.
    //
    // These go through the evaluator rather than calling the function directly: it needs
    // the reference its second argument names, and a bare `evaluate(_:)` hands it values
    // with no addresses in them.

    @Test func getPivotDataReportsAMissingPivotTable() throws {
        #expect(try pivotAnswer("GETPIVOTDATA(\"Sales\", $A$3)") == .error(.ref))
        #expect(try pivotAnswer("GETPIVOTDATA(\"Sales\", $A$3, \"Region\", \"North\")") == .error(.ref))
    }

    /// Evaluates against a provider that models no workbook, so it has no pivots to offer.
    private func pivotAnswer(_ formula: String) throws -> CellValue {
        struct Bare: CellValueProvider {
            func value(at ref: CellRef) -> CellValue? { nil }
            func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
            func lastPopulatedCell() -> CellRef? { nil }
            func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
            func values(in range: CellRange) -> [CellValue] { [] }
            func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
        }
        struct NoNames: NameResolver {
            func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
        }
        return try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                             cells: Bare(), names: NoNames())
    }

    /// It is registered, so a workbook full of it reads as a known function that
    /// cannot resolve rather than an unknown name.
    @Test func getPivotDataIsRegistered() {
        #expect(FunctionRegistry.builtin.resolvedName("GETPIVOTDATA") == "GETPIVOTDATA")
    }

    /// An error argument still propagates, so the first failure is the one reported.
    @Test func getPivotDataPropagatesAnError() throws {
        #expect(try pivotAnswer("GETPIVOTDATA(#NAME?, $A$3)") == .error(.name))
    }

    // MARK: - Legacy spellings

    /// Excel renamed the statistical functions and kept the old names working. A
    /// workbook saved before the rename still writes `NORMSINV`, and 34 corpus cells
    /// do — which would be `#NAME?` over a full stop.
    @Test func legacySpellingsResolve() {
        let registry = FunctionRegistry.builtin
        for (legacy, modern) in [("NORMSINV", "NORM.S.INV"), ("NORMSDIST", "NORM.S.DIST"),
                                 ("NORMDIST", "NORM.DIST"), ("NORMINV", "NORM.INV"),
                                 ("STDEV", "STDEV.S")] {
            #expect(registry.resolvedName(legacy) == FunctionRegistry.canonical(legacy), "\(legacy)")
            #expect(registry.resolvedName(modern) == FunctionRegistry.canonical(modern), "\(modern)")
        }
    }

    /// An alias exists only in the registry, not in any group's `all`, so it is
    /// looked up the way a formula would reach it.
    @Test func legacyAndModernAgree() throws {
        let registry = FunctionRegistry.builtin
        let legacy = try #require(registry.function(named: "NORMSINV"))
        let modern = try #require(registry.function(named: "NORM.S.INV"))
        let probability = CellValue.number(0.9087887802741321)
        #expect(try legacy.evaluate([probability]) == modern.evaluate([probability]))
    }

    // MARK: - TRUE() and FALSE()

    /// Excel accepts the booleans with parentheses, and a workbook writing
    /// `IF(ISTEXT(B2)=TRUE(), …)` is doing something ordinary.
    @Test func theBooleansAreCallable() throws {
        #expect(try function("TRUE").evaluate([]) == .bool(true))
        #expect(try function("FALSE").evaluate([]) == .bool(false))
    }

    // MARK: - Character codes

    /// `UNICODE` gives the whole code point, where `CODE` gives only the first byte
    /// of the legacy set. They agree on ASCII and part company above it.
    @Test func unicodeReadsTheCodePoint() throws {
        #expect(try number("UNICODE", [.text("A")]).isEqual(to: 65))
        #expect(try number("UNICODE", [.text("€")]).isEqual(to: 8364))
        #expect(try number("UNICODE", [.text("Abc")]).isEqual(to: 65), "the first character only")
    }

    @Test func unicodeOfNothingIsAValueError() throws {
        #expect(try function("UNICODE").evaluate([.text("")]) == .error(.value))
    }

    @Test func unicharRoundTripsWithUnicode() throws {
        #expect(try function("UNICHAR").evaluate([.number(65)]) == .text("A"))
        #expect(try function("UNICHAR").evaluate([.number(8364)]) == .text("€"))
        #expect(try number("UNICODE", [try function("UNICHAR").evaluate([.number(233)])]).isEqual(to: 233))
    }

    /// Zero, the surrogate block and anything past the range name no character.
    @Test func unicharRefusesWhatIsNotACharacter() throws {
        for value in [0.0, 55_296.0, 1_114_112.0] {
            #expect(try function("UNICHAR").evaluate([.number(value)]) == .error(.value), "\(value)")
        }
    }

    // MARK: - Base conversion

    // Excel's engineering conversions work in two's complement over a fixed window,
    // which is why DEC2HEX(-1) is all Fs rather than a signed literal.

    @Test func decimalToOtherBases() throws {
        #expect(try function("DEC2HEX").evaluate([.number(255)]) == .text("FF"))
        #expect(try function("DEC2BIN").evaluate([.number(9)]) == .text("1001"))
        #expect(try function("DEC2OCT").evaluate([.number(8)]) == .text("10"))
    }

    @Test func negativesWrapIntoTheWindow() throws {
        #expect(try function("DEC2HEX").evaluate([.number(-1)]) == .text("FFFFFFFFFF"), "ten hex digits of two's complement")
        #expect(try function("DEC2BIN").evaluate([.number(-1)]) == .text("1111111111"), "ten binary digits")
    }

    /// The `places` argument pads, and Microsoft: "If places is negative, DEC2HEX
    /// returns the #NUM! error value."
    @Test func placesPadsAndValidates() throws {
        #expect(try function("DEC2HEX").evaluate([.number(255), .number(4)]) == .text("00FF"))
        #expect(try function("DEC2HEX").evaluate([.number(255), .number(1)]) == .error(.num), "too few places for the value")
    }

    @Test func conversionsRoundTrip() throws {
        #expect(try number("HEX2DEC", [.text("FF")]).isEqual(to: 255))
        #expect(try number("BIN2DEC", [.text("1001")]).isEqual(to: 9))
        #expect(try number("OCT2DEC", [.text("10")]).isEqual(to: 8))
        #expect(try number("HEX2DEC", [.text("FFFFFFFFFF")]).isEqual(to: -1), "the top bit is the sign, matching DEC2HEX")
    }

    /// `BASE` is unsigned and has no wrapping, which is what separates it from the
    /// `DEC2*` family.
    @Test func baseIsUnsigned() throws {
        #expect(try function("BASE").evaluate([.number(255), .number(16)]) == .text("FF"))
        #expect(try function("BASE").evaluate([.number(7), .number(2)]) == .text("111"))
        #expect(try function("BASE").evaluate([.number(7), .number(2), .number(8)]) == .text("00000111"))
        #expect(try function("BASE").evaluate([.number(-1), .number(16)]) == .error(.num), "no two's complement here")
    }

    @Test func decimalInvertsBase() throws {
        #expect(try number("DECIMAL", [.text("FF"), .number(16)]).isEqual(to: 255))
        #expect(try number("DECIMAL", [.text("111"), .number(2)]).isEqual(to: 7))
        #expect(try function("DECIMAL").evaluate([.text("ZZ"), .number(16)]) == .error(.num))
    }

    // MARK: - CELL

    /// `CELL("contents"| "type", ref)` follows from the value.
    @Test func cellReadsContentsAndType() throws {
        // CELL needs the calling context to answer positional questions, so it is
        // reached through the evaluator rather than called directly.
        func cell(_ info: String, _ argument: FormulaAST) throws -> CellValue {
            try FormulaEvaluator.evaluate(
                .function("CELL", [.text(info), argument]),
                cells: NoCells(), names: NamedRangeCollection())
        }
        #expect(try cell("contents", .number(42)) == .number(42))
        #expect(try cell("type", .text("hello")) == .text("l"), "l for label")
        #expect(try cell("type", .number(1)) == .text("v"))
        #expect(try cell("type", .text("")) == .text("b"))
    }

    /// `"address"`, `"row"` and `"col"` read the reference as written, so they answer
    /// about where it points rather than about the value inside it.
    @Test func cellAnswersPositionalQuestions() throws {
        func cell(_ info: String) throws -> CellValue {
            try FormulaEvaluator.evaluate(
                .function("CELL", [.text(info), .cellRef(CellRef("D7"))]),
                cells: NoCells(), names: NamedRangeCollection())
        }
        #expect(try cell("row") == .number(7))
        #expect(try cell("col") == .number(4))
        #expect(try cell("address") == .text("$D$7"), "Excel reports it absolute")
    }

    /// The environment-dependent info types are refused rather than guessed.
    ///
    /// `"filename"` is what the corpus writes — 185 calls across nine workbooks — and
    /// it names where the file sits on disk, which no formula's value can depend on
    /// here. An empty string would be a plausible-looking lie.
    @Test func cellRefusesWhatItCannotKnow() throws {
        for info in ["filename", "format", "color", "width", "protect", "prefix"] {
            let result = try FormulaEvaluator.evaluate(
                .function("CELL", [.text(info), .number(1)]),
                cells: NoCells(), names: NamedRangeCollection())
            #expect(result == .error(.value), "\(info)")
        }
    }

    /// A provider holding nothing, for the functions that ask about position rather
    /// than about content.
    private struct NoCells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
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

    @Test func theLookupsPropagateAnErrorLookupValue() throws {
        let table = grid([[.number(1), .text("a")], [.number(2), .text("b")]])
        for name in ["VLOOKUP", "HLOOKUP"] {
            #expect(try function(name).evaluate([.error(.name), table, .number(2), .bool(false)]) == .error(.name), "\(name)")
        }
        #expect(try function("MATCH").evaluate([.error(.name), table, .number(0)]) == .error(.name))
    }

    @Test func theLookupsPropagateAnErrorTable() throws {
        for name in ["VLOOKUP", "HLOOKUP"] {
            #expect(try function(name).evaluate([.number(1), .error(.div0), .number(2), .bool(false)]) == .error(.div0), "\(name)")
        }
    }

    @Test func theLookupsPropagateAnErrorIndex() throws {
        let table = grid([[.number(1), .text("a")], [.number(2), .text("b")]])
        for name in ["VLOOKUP", "HLOOKUP"] {
            #expect(try function(name).evaluate([.number(1), table, .error(.value), .bool(false)]) == .error(.value), "\(name)")
        }
    }

    /// The first error wins, so the result names the failure nearest the start of
    /// the argument list rather than whichever the implementation happened to test.
    @Test func theFirstErrorArgumentIsTheOneReturned() throws {
        #expect(try function("VLOOKUP").evaluate([.error(.na), .error(.div0), .number(2)]) == .error(.na))
    }

    /// `INDEX` already did this, and must keep doing it.
    @Test func indexPropagatesAnError() throws {
        let table = grid([[.number(1), .text("a")]])
        #expect(try function("INDEX").evaluate([.error(.ref), .number(1)]) == .error(.ref))
        #expect(try function("INDEX").evaluate([table, .error(.ref)]) == .error(.ref))
    }

    // MARK: - EOMONTH

    // Microsoft: "Returns the serial number for the last day of the month that is
    // the indicated number of months before or after start_date."

    @Test func eomonthMovesForwardAndLands() throws {
        // 2020-01-31 + 1 month is 2020-02-29, a leap February.
        let jan31_2020 = 43861.0
        #expect(try abs(number("EOMONTH", [.number(jan31_2020), .number(1)]) - Self.feb29_2020) <= 0)
    }

    @Test func eomonthMovesBackward() throws {
        // 2020-12-31 back ten months is 2020-02-29.
        #expect(try abs(number("EOMONTH", [.number(Self.dec31_2020), .number(-10)]) - Self.feb29_2020) <= 0)
    }

    @Test func eomonthWithZeroIsTheEndOfTheSameMonth() throws {
        // 2020-02-29 is already the month end and stays put.
        #expect(try abs(number("EOMONTH", [.number(Self.feb29_2020), .number(0)]) - Self.feb29_2020) <= 0)
    }
}
