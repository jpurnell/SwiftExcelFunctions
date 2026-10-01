import Foundation
import SwiftExcelCore
import Foundation
import Testing
@testable import SwiftExcelFunctions

/// The seven date functions that were in the unreviewed bucket.
///
/// **Where the expected values come from**, which matters more here than usual because a
/// working-day count is the kind of answer nobody checks by hand:
///
/// - Microsoft's own published examples, quoted and marked, for `NETWORKDAYS`, `DATEDIF`,
///   `WEEKNUM` and `TIMEVALUE`.
/// - `numpy.busday_count` and `busday_offset` for the `.INTL` pair, which no published
///   example covers at that spread of weekend codes. An independent implementation of the
///   same rule, in another language, written by people who had never seen this one.
/// - Python's `date.isocalendar()` for the ISO weeks.
///
/// None is taken from what this package returns, which is the whole point: two
/// implementations reasoning from one person's reading of a definition agree with each
/// other and are both wrong.
@Suite struct WorkingDayAndWeekTests {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let function = registry.function(named: name) else {
            Issue.record("\(name) is not registered"); return .error(.name)
        }
        return try function.evaluate(args)
    }

    private func number(_ name: String, _ args: CellValue...) throws -> Double {
        guard let function = registry.function(named: name) else {
            Issue.record("\(name) is not registered"); return .nan
        }
        guard case .number(let value) = try function.evaluate(args) else {
            Issue.record("\(name) did not answer with a number"); return .nan
        }
        return value
    }

    // Serials used throughout, named so a failure says which date it was about.
    private let october1_2012 = CellValue.number(41183)
    private let march1_2013 = CellValue.number(41334)
    private let thanksgiving2012 = CellValue.number(41235)
    private let december4_2012 = CellValue.number(41247)
    private let january21_2013 = CellValue.number(41295)
    private let september1_2026 = CellValue.number(46266)
    private let september30_2026 = CellValue.number(46295)
    private let saturday = CellValue.number(46277)      // 12 September 2026
    private let monday = CellValue.number(46279)        // 14 September 2026

    // MARK: - NETWORKDAYS

    /// Microsoft's published example, all three lines of it.
    @Test func networkdaysMatchesThePublishedExample() throws {
        #expect(try number("NETWORKDAYS", october1_2012, march1_2013).isEqual(to: 110))
        #expect(try number("NETWORKDAYS", october1_2012, march1_2013, thanksgiving2012).isEqual(to: 109))
        #expect(try number("NETWORKDAYS", october1_2012, march1_2013, .array(CellMatrix(row: [thanksgiving2012, december4_2012, january21_2013]))).isEqual(to: 107))
    }

    /// Both endpoints count, which is what makes this the function a timesheet uses.
    @Test func bothEndpointsCount() throws {
        #expect(try number("NETWORKDAYS", monday, monday).isEqual(to: 1))
        #expect(try number("NETWORKDAYS", saturday, saturday) == 0)
        // Monday to the Friday of the same week.
        #expect(try number("NETWORKDAYS", monday, .number(46283)).isEqual(to: 5))
    }

    /// A reversed interval is a negative count rather than an error.
    @Test func aReversedIntervalCountsBackwards() throws {
        #expect(try number("NETWORKDAYS", march1_2013, october1_2012).isEqual(to: -110))
    }

    // MARK: - NETWORKDAYS.INTL

    /// Every weekend code, over one month, against `numpy.busday_count`.
    ///
    /// September 2026 was chosen because it starts on a Tuesday: a month starting on a
    /// Monday would give several codes the same answer and hide a mapping that is off by
    /// a day.
    @Test func everyWeekendCodeAgreesWithAnIndependentImplementation() throws {
        let expected: [Int: Double] = [
            1: 22, 2: 22, 3: 21, 4: 20, 5: 21, 6: 22, 7: 22,
            11: 26, 12: 26, 13: 25, 14: 25, 15: 26, 16: 26, 17: 26,
        ]
        for (code, days) in expected.sorted(by: { $0.key < $1.key }) {
            #expect(try number("NETWORKDAYS.INTL", september1_2026, september30_2026, .number(Double(code))).isEqual(to: days), "weekend code \(code)")
        }
    }

    /// Two arguments is `NETWORKDAYS` exactly, and the mask spells out code 1.
    @Test func theDefaultAndTheWrittenOutMaskAgree() throws {
        #expect(try number("NETWORKDAYS.INTL", september1_2026, september30_2026).isEqual(to: 22))
        #expect(try number("NETWORKDAYS.INTL", september1_2026, september30_2026, .text("0000011")).isEqual(to: 22))
        // Monday first: this one rests on Monday and Tuesday, which is code 3.
        #expect(try number("NETWORKDAYS.INTL", september1_2026, september30_2026, .text("1100000")).isEqual(to: 21))
    }

    /// What Excel refuses, and with which error — the two are not interchangeable.
    @Test func theWeekendArgumentIsValidated() throws {
        // A code in no block.
        #expect(try call("NETWORKDAYS.INTL", september1_2026, september30_2026, .number(8)) == .error(.num))
        // A mask of the wrong length, or with something other than 0 and 1 in it.
        #expect(try call("NETWORKDAYS.INTL", september1_2026, september30_2026, .text("000001")) == .error(.value))
        #expect(try call("NETWORKDAYS.INTL", september1_2026, september30_2026, .text("000001x")) == .error(.value))
        // A week that never works. Answering zero would be defensible and is not what
        // Excel does — and it is the case that would otherwise walk WORKDAY.INTL to the
        // end of the calendar.
        #expect(try call("NETWORKDAYS.INTL", september1_2026, september30_2026, .text("1111111")) == .error(.value))
    }

    // MARK: - WORKDAY.INTL

    /// Against `numpy.busday_offset`, from a Monday so the roll rule cannot hide.
    @Test func workdayIntlStepsAsAnIndependentImplementationDoes() throws {
        #expect(try number("WORKDAY.INTL", monday, .number(1)).isEqual(to: 46280))
        #expect(try number("WORKDAY.INTL", monday, .number(5)).isEqual(to: 46286))
        #expect(try number("WORKDAY.INTL", monday, .number(10)).isEqual(to: 46293))
        #expect(try number("WORKDAY.INTL", monday, .number(-1)).isEqual(to: 46276))
    }

    /// The start is not counted and not snapped.
    ///
    /// Zero working days from a Saturday is that Saturday. Excel does not move a weekend
    /// start to the nearest working day, and an implementation that does is wrong twice a
    /// week in a way that looks right the other five times.
    @Test func aWeekendStartIsNotSnapped() throws {
        #expect(try number("WORKDAY.INTL", saturday, .number(0)).isEqual(to: 46277))
        #expect(try number("WORKDAY.INTL", saturday, .number(1)).isEqual(to: 46279))
        #expect(try number("WORKDAY.INTL", saturday, .number(-1)).isEqual(to: 46276))
    }

    /// The weekend and holidays arguments do what they do in the counting function.
    @Test func workdayIntlHonoursTheWeekendAndTheHolidays() throws {
        // Code 11: Sunday is the only day off, so five days from Monday reaches Saturday.
        #expect(try number("WORKDAY.INTL", monday, .number(5), .number(11)).isEqual(to: 46284))
        // The Wednesday in the way is a holiday, so the answer moves on by one day.
        #expect(try number("WORKDAY.INTL", monday, .number(5), .number(1), .number(46281)).isEqual(to: 46287))
    }

    // MARK: - WEEKNUM and ISOWEEKNUM

    /// Microsoft's published example: 9 March 2012 is week 10, or week 11 from Monday.
    @Test func weeknumMatchesThePublishedExample() throws {
        #expect(try number("WEEKNUM", .number(40977)).isEqual(to: 10))
        #expect(try number("WEEKNUM", .number(40977), .number(2)).isEqual(to: 11))
    }

    /// Week 1 is the week containing 1 January, however short it is.
    ///
    /// 1 January 2016 was a Friday, so under the default numbering that Friday and the
    /// Saturday after it are the whole of week 1 — and the ISO answer for the same day is
    /// week 53 of 2015. The two functions disagree by a year, which is the point of having
    /// both.
    @Test func weekOneCanBeTwoDaysLong() throws {
        #expect(try number("WEEKNUM", .number(42370)).isEqual(to: 1))        // 1 January 2016
        #expect(try number("WEEKNUM", .number(42372)).isEqual(to: 2))        // Sunday 3 January
        #expect(try number("ISOWEEKNUM", .number(42370)).isEqual(to: 53))
    }

    /// Against Python's `date.isocalendar()`, including both ways a year can overlap.
    @Test func isoWeeksAgreeWithAnIndependentImplementation() throws {
        let expected: [(serial: Double, week: Double, date: String)] = [
            (38718, 52, "2006-01-01"),   // a Sunday, so the last week of 2005
            (40909, 52, "2012-01-01"),
            (40910, 1, "2012-01-02"),
            (41274, 1, "2012-12-31"),    // a Monday, so the first week of 2013
            (41334, 9, "2013-03-01"),
            (42370, 53, "2016-01-01"),
            (44197, 53, "2021-01-01"),
            (46279, 38, "2026-09-14"),
        ]
        for row in expected {
            #expect(try number("ISOWEEKNUM", .number(row.serial)).isEqual(to: row.week), "\(row.date)")
            // Type 21 is the same function under another name.
            #expect(try number("WEEKNUM", .number(row.serial), .number(21)).isEqual(to: row.week), "\(row.date)")
        }
    }

    /// A return type in none of the three blocks is `#NUM!`.
    @Test func anUnknownReturnTypeIsRefused() throws {
        #expect(try call("WEEKNUM", .number(46279), .number(4)) == .error(.num))
        #expect(try call("WEEKNUM", .number(46279), .number(22)) == .error(.num))
    }

    // MARK: - DATEDIF

    /// Microsoft's published examples, all four.
    @Test func datedifMatchesThePublishedExamples() throws {
        // 1 January 2001 to 1 January 2003.
        #expect(try number("DATEDIF", .number(36892), .number(37622), .text("Y")).isEqual(to: 2))
        // 1 June 2001 to 15 August 2002.
        #expect(try number("DATEDIF", .number(37043), .number(37483), .text("D")).isEqual(to: 440))
        #expect(try number("DATEDIF", .number(37043), .number(37483), .text("YD")).isEqual(to: 75))
        #expect(try number("DATEDIF", .number(37043), .number(37483), .text("MD")).isEqual(to: 14))
    }

    /// A period is complete only when the day of the month has come round again.
    @Test func aPeriodIsCompleteOrItDoesNotCount() throws {
        // 31 January 2016 to 29 February 2016: the day never comes round, so no month.
        #expect(try number("DATEDIF", .number(42400), .number(42429), .text("M")) == 0)
        // 31 January to 31 March is two.
        #expect(try number("DATEDIF", .number(42400), .number(42460), .text("M")).isEqual(to: 2))
        #expect(try number("DATEDIF", .number(42400), .number(42460), .text("YM")).isEqual(to: 2))
    }

    /// `"MD"` reproduces Excel's own wrong answer, deliberately.
    ///
    /// 31 January 2016 to 1 March 2016 is −1 in Excel: the borrow is February's 29 days
    /// against a gap of 30. Microsoft documents the unit as not recommended for exactly
    /// this reason. We match it rather than fix it — see the function's own note.
    @Test func theBrokenUnitIsBrokenTheSameWay() throws {
        #expect(try number("DATEDIF", .number(42400), .number(42430), .text("MD")).isEqual(to: -1))
    }

    /// A start after the end is refused in every unit.
    @Test func aBackwardsIntervalIsRefused() throws {
        #expect(try call("DATEDIF", .number(37483), .number(37043), .text("D")) == .error(.num))
        #expect(try call("DATEDIF", .number(37483), .number(37043), .text("MD")) == .error(.num))
    }

    /// An unknown unit is `#NUM!`, and the known ones are case-insensitive.
    @Test func theUnitIsReadLoosely() throws {
        #expect(try number("DATEDIF", .number(37043), .number(37483), .text("d")).isEqual(to: 440))
        #expect(try call("DATEDIF", .number(37043), .number(37483), .text("W")) == .error(.num))
    }

    // MARK: - TIMEVALUE

    /// Microsoft's published examples, and the two that are always wrong somewhere.
    @Test func timevalueReadsTheClock() throws {
        #expect(try abs(number("TIMEVALUE", .text("2:24 PM")) - 0.6) <= 1e-12)
        #expect(try abs(number("TIMEVALUE", .text("22-Aug-2011 6:35 AM")) - 0.2743055555555556) <= 1e-12)
        // Midnight and noon: 12 AM is hour 0 and 12 PM is hour 12, which is the pair that
        // a naive `hour % 12` gets backwards in both directions.
        #expect(try abs(number("TIMEVALUE", .text("12:00 AM")) - 0) <= 1e-12)
        #expect(try abs(number("TIMEVALUE", .text("12:00 PM")) - 0.5) <= 1e-12)
        #expect(try abs(number("TIMEVALUE", .text("13:30")) - 0.5625) <= 1e-12)
        #expect(try abs(number("TIMEVALUE", .text("13:30:45")) - ((13 * 3600 + 30 * 60 + 45) / 86_400)) <= 1e-12)
    }

    /// Text that names no time is `#VALUE!` rather than a guess.
    @Test func timevalueRefusesWhatItCannotRead() throws {
        #expect(try call("TIMEVALUE", .text("abc")) == .error(.value))
        #expect(try call("TIMEVALUE", .text("25:00")) == .error(.value))
        #expect(try call("TIMEVALUE", .text("13:60")) == .error(.value))
        #expect(try call("TIMEVALUE", .text("13 PM")) == .error(.value))
    }

    // MARK: - Registration

    /// Every name this tranche claims answers, under the spelling a workbook writes.
    ///
    /// `NETWORKDAYS.INTL` and `WORKDAY.INTL` are saved by older versions as
    /// `_xlfn.NETWORKDAYS.INTL`, and a lookup that does not resolve the prefix reports
    /// `#NAME?` for a purely clerical reason.
    @Test func theNamesResolveIncludingTheModernPrefix() {
        for name in ["NETWORKDAYS", "NETWORKDAYS.INTL", "WORKDAY.INTL",
                     "WEEKNUM", "ISOWEEKNUM", "DATEDIF", "TIMEVALUE"] {
            #expect(registry.resolvedName(name) == FunctionRegistry.canonical(name), "\(name)")
            #expect(registry.resolvedName("_xlfn.\(name)") == FunctionRegistry.canonical("_xlfn.\(name)"), "_xlfn.\(name)")
        }
    }
}
