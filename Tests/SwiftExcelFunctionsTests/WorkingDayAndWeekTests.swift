import Foundation
import SwiftExcelCore
import XCTest
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
final class WorkingDayAndWeekTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let function = registry.function(named: name) else {
            XCTFail("\(name) is not registered"); return .error(.name)
        }
        return try function.evaluate(args)
    }

    private func number(_ name: String, _ args: CellValue...) throws -> Double {
        guard let function = registry.function(named: name) else {
            XCTFail("\(name) is not registered"); return .nan
        }
        guard case .number(let value) = try function.evaluate(args) else {
            XCTFail("\(name) did not answer with a number"); return .nan
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
    func testNetworkdaysMatchesThePublishedExample() throws {
        XCTAssertEqual(try number("NETWORKDAYS", october1_2012, march1_2013), 110)
        XCTAssertEqual(try number("NETWORKDAYS", october1_2012, march1_2013, thanksgiving2012), 109)
        XCTAssertEqual(
            try number("NETWORKDAYS", october1_2012, march1_2013,
                       .array(CellMatrix(row: [thanksgiving2012, december4_2012, january21_2013]))),
            107)
    }

    /// Both endpoints count, which is what makes this the function a timesheet uses.
    func testBothEndpointsCount() throws {
        XCTAssertEqual(try number("NETWORKDAYS", monday, monday), 1)
        XCTAssertEqual(try number("NETWORKDAYS", saturday, saturday), 0)
        // Monday to the Friday of the same week.
        XCTAssertEqual(try number("NETWORKDAYS", monday, .number(46283)), 5)
    }

    /// A reversed interval is a negative count rather than an error.
    func testAReversedIntervalCountsBackwards() throws {
        XCTAssertEqual(try number("NETWORKDAYS", march1_2013, october1_2012), -110)
    }

    // MARK: - NETWORKDAYS.INTL

    /// Every weekend code, over one month, against `numpy.busday_count`.
    ///
    /// September 2026 was chosen because it starts on a Tuesday: a month starting on a
    /// Monday would give several codes the same answer and hide a mapping that is off by
    /// a day.
    func testEveryWeekendCodeAgreesWithAnIndependentImplementation() throws {
        let expected: [Int: Double] = [
            1: 22, 2: 22, 3: 21, 4: 20, 5: 21, 6: 22, 7: 22,
            11: 26, 12: 26, 13: 25, 14: 25, 15: 26, 16: 26, 17: 26,
        ]
        for (code, days) in expected.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(
                try number("NETWORKDAYS.INTL", september1_2026, september30_2026, .number(Double(code))),
                days, "weekend code \(code)")
        }
    }

    /// Two arguments is `NETWORKDAYS` exactly, and the mask spells out code 1.
    func testTheDefaultAndTheWrittenOutMaskAgree() throws {
        XCTAssertEqual(try number("NETWORKDAYS.INTL", september1_2026, september30_2026), 22)
        XCTAssertEqual(
            try number("NETWORKDAYS.INTL", september1_2026, september30_2026, .text("0000011")), 22)
        // Monday first: this one rests on Monday and Tuesday, which is code 3.
        XCTAssertEqual(
            try number("NETWORKDAYS.INTL", september1_2026, september30_2026, .text("1100000")), 21)
    }

    /// What Excel refuses, and with which error — the two are not interchangeable.
    func testTheWeekendArgumentIsValidated() throws {
        // A code in no block.
        XCTAssertEqual(try call("NETWORKDAYS.INTL", september1_2026, september30_2026, .number(8)),
                       .error(.num))
        // A mask of the wrong length, or with something other than 0 and 1 in it.
        XCTAssertEqual(try call("NETWORKDAYS.INTL", september1_2026, september30_2026, .text("000001")),
                       .error(.value))
        XCTAssertEqual(try call("NETWORKDAYS.INTL", september1_2026, september30_2026, .text("000001x")),
                       .error(.value))
        // A week that never works. Answering zero would be defensible and is not what
        // Excel does — and it is the case that would otherwise walk WORKDAY.INTL to the
        // end of the calendar.
        XCTAssertEqual(try call("NETWORKDAYS.INTL", september1_2026, september30_2026, .text("1111111")),
                       .error(.value))
    }

    // MARK: - WORKDAY.INTL

    /// Against `numpy.busday_offset`, from a Monday so the roll rule cannot hide.
    func testWorkdayIntlStepsAsAnIndependentImplementationDoes() throws {
        XCTAssertEqual(try number("WORKDAY.INTL", monday, .number(1)), 46280)
        XCTAssertEqual(try number("WORKDAY.INTL", monday, .number(5)), 46286)
        XCTAssertEqual(try number("WORKDAY.INTL", monday, .number(10)), 46293)
        XCTAssertEqual(try number("WORKDAY.INTL", monday, .number(-1)), 46276)
    }

    /// The start is not counted and not snapped.
    ///
    /// Zero working days from a Saturday is that Saturday. Excel does not move a weekend
    /// start to the nearest working day, and an implementation that does is wrong twice a
    /// week in a way that looks right the other five times.
    func testAWeekendStartIsNotSnapped() throws {
        XCTAssertEqual(try number("WORKDAY.INTL", saturday, .number(0)), 46277)
        XCTAssertEqual(try number("WORKDAY.INTL", saturday, .number(1)), 46279)
        XCTAssertEqual(try number("WORKDAY.INTL", saturday, .number(-1)), 46276)
    }

    /// The weekend and holidays arguments do what they do in the counting function.
    func testWorkdayIntlHonoursTheWeekendAndTheHolidays() throws {
        // Code 11: Sunday is the only day off, so five days from Monday reaches Saturday.
        XCTAssertEqual(try number("WORKDAY.INTL", monday, .number(5), .number(11)), 46284)
        // The Wednesday in the way is a holiday, so the answer moves on by one day.
        XCTAssertEqual(
            try number("WORKDAY.INTL", monday, .number(5), .number(1), .number(46281)), 46287)
    }

    // MARK: - WEEKNUM and ISOWEEKNUM

    /// Microsoft's published example: 9 March 2012 is week 10, or week 11 from Monday.
    func testWeeknumMatchesThePublishedExample() throws {
        XCTAssertEqual(try number("WEEKNUM", .number(40977)), 10)
        XCTAssertEqual(try number("WEEKNUM", .number(40977), .number(2)), 11)
    }

    /// Week 1 is the week containing 1 January, however short it is.
    ///
    /// 1 January 2016 was a Friday, so under the default numbering that Friday and the
    /// Saturday after it are the whole of week 1 — and the ISO answer for the same day is
    /// week 53 of 2015. The two functions disagree by a year, which is the point of having
    /// both.
    func testWeekOneCanBeTwoDaysLong() throws {
        XCTAssertEqual(try number("WEEKNUM", .number(42370)), 1)        // 1 January 2016
        XCTAssertEqual(try number("WEEKNUM", .number(42372)), 2)        // Sunday 3 January
        XCTAssertEqual(try number("ISOWEEKNUM", .number(42370)), 53)
    }

    /// Against Python's `date.isocalendar()`, including both ways a year can overlap.
    func testIsoWeeksAgreeWithAnIndependentImplementation() throws {
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
            XCTAssertEqual(try number("ISOWEEKNUM", .number(row.serial)), row.week, row.date)
            // Type 21 is the same function under another name.
            XCTAssertEqual(try number("WEEKNUM", .number(row.serial), .number(21)), row.week, row.date)
        }
    }

    /// A return type in none of the three blocks is `#NUM!`.
    func testAnUnknownReturnTypeIsRefused() throws {
        XCTAssertEqual(try call("WEEKNUM", .number(46279), .number(4)), .error(.num))
        XCTAssertEqual(try call("WEEKNUM", .number(46279), .number(22)), .error(.num))
    }

    // MARK: - DATEDIF

    /// Microsoft's published examples, all four.
    func testDatedifMatchesThePublishedExamples() throws {
        // 1 January 2001 to 1 January 2003.
        XCTAssertEqual(try number("DATEDIF", .number(36892), .number(37622), .text("Y")), 2)
        // 1 June 2001 to 15 August 2002.
        XCTAssertEqual(try number("DATEDIF", .number(37043), .number(37483), .text("D")), 440)
        XCTAssertEqual(try number("DATEDIF", .number(37043), .number(37483), .text("YD")), 75)
        XCTAssertEqual(try number("DATEDIF", .number(37043), .number(37483), .text("MD")), 14)
    }

    /// A period is complete only when the day of the month has come round again.
    func testAPeriodIsCompleteOrItDoesNotCount() throws {
        // 31 January 2016 to 29 February 2016: the day never comes round, so no month.
        XCTAssertEqual(try number("DATEDIF", .number(42400), .number(42429), .text("M")), 0)
        // 31 January to 31 March is two.
        XCTAssertEqual(try number("DATEDIF", .number(42400), .number(42460), .text("M")), 2)
        XCTAssertEqual(try number("DATEDIF", .number(42400), .number(42460), .text("YM")), 2)
    }

    /// `"MD"` reproduces Excel's own wrong answer, deliberately.
    ///
    /// 31 January 2016 to 1 March 2016 is −1 in Excel: the borrow is February's 29 days
    /// against a gap of 30. Microsoft documents the unit as not recommended for exactly
    /// this reason. We match it rather than fix it — see the function's own note.
    func testTheBrokenUnitIsBrokenTheSameWay() throws {
        XCTAssertEqual(try number("DATEDIF", .number(42400), .number(42430), .text("MD")), -1)
    }

    /// A start after the end is refused in every unit.
    func testABackwardsIntervalIsRefused() throws {
        XCTAssertEqual(try call("DATEDIF", .number(37483), .number(37043), .text("D")), .error(.num))
        XCTAssertEqual(try call("DATEDIF", .number(37483), .number(37043), .text("MD")), .error(.num))
    }

    /// An unknown unit is `#NUM!`, and the known ones are case-insensitive.
    func testTheUnitIsReadLoosely() throws {
        XCTAssertEqual(try number("DATEDIF", .number(37043), .number(37483), .text("d")), 440)
        XCTAssertEqual(try call("DATEDIF", .number(37043), .number(37483), .text("W")), .error(.num))
    }

    // MARK: - TIMEVALUE

    /// Microsoft's published examples, and the two that are always wrong somewhere.
    func testTimevalueReadsTheClock() throws {
        XCTAssertEqual(try number("TIMEVALUE", .text("2:24 PM")), 0.6, accuracy: 1e-12)
        XCTAssertEqual(try number("TIMEVALUE", .text("22-Aug-2011 6:35 AM")),
                       0.2743055555555556, accuracy: 1e-12)
        // Midnight and noon: 12 AM is hour 0 and 12 PM is hour 12, which is the pair that
        // a naive `hour % 12` gets backwards in both directions.
        XCTAssertEqual(try number("TIMEVALUE", .text("12:00 AM")), 0, accuracy: 1e-12)
        XCTAssertEqual(try number("TIMEVALUE", .text("12:00 PM")), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try number("TIMEVALUE", .text("13:30")), 0.5625, accuracy: 1e-12)
        XCTAssertEqual(try number("TIMEVALUE", .text("13:30:45")),
                       (13 * 3600 + 30 * 60 + 45) / 86_400, accuracy: 1e-12)
    }

    /// Text that names no time is `#VALUE!` rather than a guess.
    func testTimevalueRefusesWhatItCannotRead() throws {
        XCTAssertEqual(try call("TIMEVALUE", .text("abc")), .error(.value))
        XCTAssertEqual(try call("TIMEVALUE", .text("25:00")), .error(.value))
        XCTAssertEqual(try call("TIMEVALUE", .text("13:60")), .error(.value))
        XCTAssertEqual(try call("TIMEVALUE", .text("13 PM")), .error(.value))
    }

    // MARK: - Registration

    /// Every name this tranche claims answers, under the spelling a workbook writes.
    ///
    /// `NETWORKDAYS.INTL` and `WORKDAY.INTL` are saved by older versions as
    /// `_xlfn.NETWORKDAYS.INTL`, and a lookup that does not resolve the prefix reports
    /// `#NAME?` for a purely clerical reason.
    func testTheNamesResolveIncludingTheModernPrefix() {
        for name in ["NETWORKDAYS", "NETWORKDAYS.INTL", "WORKDAY.INTL",
                     "WEEKNUM", "ISOWEEKNUM", "DATEDIF", "TIMEVALUE"] {
            XCTAssertNotNil(registry.function(named: name), name)
            XCTAssertNotNil(registry.function(named: "_xlfn.\(name)"), "_xlfn.\(name)")
        }
    }
}
