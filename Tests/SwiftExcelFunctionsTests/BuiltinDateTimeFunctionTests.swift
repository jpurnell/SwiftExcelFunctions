import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

@Suite struct BuiltinDateTimeFunctionTests {

    // MARK: - WEEKDAY's return types, measured in round thirteen

    /// `return_type` 11 through 17 start the week on a named day.
    ///
    /// **The corpus found this and could only half-answer it.** `Digital Sales Budget 2.0.xlsx`
    /// holds 9,166 cells reading `WEEKDAY(AEn, week_end_day)`, and `week_end_day` resolves
    /// through `Definitions!$E$61` to **17** — a return type this package refused with `#NUM!`,
    /// implementing only 1, 2 and 3. Every one of those cells was a refusal of an ordinary
    /// argument.
    ///
    /// The corpus exercises 17 and nothing else, so round thirteen asked all seven rather than
    /// reasoning from documentation to the other six. Serial 41640 is 1 January 2014, a
    /// Wednesday, and Excel answered:
    ///
    /// | `return_type` | week starts | Wednesday is |
    /// |---|---|---|
    /// | 11 | Monday | 3 |
    /// | 12 | Tuesday | 2 |
    /// | 13 | Wednesday | 1 |
    /// | 14 | Thursday | 7 |
    /// | 15 | Friday | 6 |
    /// | 16 | Saturday | 5 |
    /// | 17 | Sunday | 4 |
    @Test func theWeekCanStartOnAnyNamedDay() throws {
        // 41640 is Wednesday, 1 January 2014.
        #expect(try eval("WEEKDAY", .number(41640), .number(11)).isNumber(3))
        #expect(try eval("WEEKDAY", .number(41640), .number(12)).isNumber(2))
        #expect(try eval("WEEKDAY", .number(41640), .number(13)).isNumber(1))
        #expect(try eval("WEEKDAY", .number(41640), .number(14)).isNumber(7))
        #expect(try eval("WEEKDAY", .number(41640), .number(15)).isNumber(6))
        #expect(try eval("WEEKDAY", .number(41640), .number(16)).isNumber(5))
        #expect(try eval("WEEKDAY", .number(41640), .number(17)).isNumber(4))
    }

    /// A second and third date, so no convention rests on one day's coincidence.
    @Test func theNamedStartDaysHoldAcrossTheWeekend() throws {
        // 41643 is Saturday, 41644 is Sunday.
        #expect(try eval("WEEKDAY", .number(41643), .number(17)).isNumber(7, within: 0))
        #expect(try eval("WEEKDAY", .number(41644), .number(17)).isNumber(1, within: 0))
        #expect(try eval("WEEKDAY", .number(41644), .number(16)).isNumber(2, within: 0))
    }

    /// 11 and 17 are the old 2 and 1 under new names, which is worth pinning.
    @Test func theNewTypesAgreeWithTheOldOnesTheyRestate() throws {
        for serial in [41640.0, 41643, 41644, 1, 0] {
            #expect(try eval("WEEKDAY", .number(serial), .number(11)) == eval("WEEKDAY", .number(serial), .number(2)), "11 starts the week on Monday, as 2 does — serial \(serial)")
            #expect(try eval("WEEKDAY", .number(serial), .number(17)) == eval("WEEKDAY", .number(serial), .number(1)), "17 starts it on Sunday, as 1 does — serial \(serial)")
        }
    }

    /// The numbers either side of the set are refused.
    ///
    /// Measured: 0, 4, 10, 18 and −1 are all `#NUM!`, and this package already agreed. Kept
    /// as the control that makes the seven above meaningful — widening the set must not
    /// widen it further than Excel does.
    @Test func aReturnTypeOutsideTheSetIsRefused() throws {
        for type in [0.0, 4, 5, 10, 18, -1] {
            #expect(try eval("WEEKDAY", .number(41640), .number(type)) == .error(.num), "return_type \(type)")
        }
    }

    // MARK: - The serial floor and ceiling, measured in round eleven

    /// Serial 0 is January 0, 1900 — a date that does not exist, and every date function
    /// takes it.
    ///
    /// **Measured, not reasoned.** Round eleven of the conformance workbook put all six
    /// functions to Excel at serial 0 and read the answers back; the corpus had already
    /// found the first of them, in 1,664 cells of `Digital Sales Budget 2.0.xlsx` reading
    /// `MONTH(AFn)` over a cached `0`, with a control in the same column answering January
    /// 2014 over serial 41640.
    ///
    /// The other five were *not* inferred from `MONTH`. That inference is the one this
    /// project has been wrong about seven times — most recently `GAMMA.DIST` and
    /// `WEIBULL.DIST`, which face an identical boundary and answer it differently. Each was
    /// asked. As it happens all six agree, and now that is a fact rather than a hope.
    @Test func everyDateFunctionAcceptsSerialZero() throws {
        #expect(try eval("YEAR", .number(0)).isNumber(1900))
        #expect(try eval("MONTH", .number(0)).isNumber(1))
        #expect(try eval("DAY", .number(0)).isNumber(0))
        #expect(try eval("WEEKDAY", .number(0)).isNumber(7))
        #expect(try eval("WEEKDAY", .number(0), .number(2)).isNumber(6))
        #expect(try eval("EOMONTH", .number(0), .number(0)).isNumber(31))
        #expect(try eval("EDATE", .number(0), .number(0)).isNumber(0))
        #expect(try eval("EDATE", .number(0), .number(1)).isNumber(31))
    }

    /// A fraction of that day is still that day.
    @Test func aFractionalSerialIsTruncatedRatherThanRefused() throws {
        #expect(try eval("MONTH", .number(0.5)).isNumber(1))
        #expect(try eval("DAY", .number(0.5)).isNumber(0))
        #expect(try eval("YEAR", .number(0.99)).isNumber(1900))
    }

    /// Below zero there is no date, and Excel says so.
    ///
    /// The half of the boundary this package already had right, kept as the control that
    /// makes the change above meaningful: moving the floor must not remove the floor.
    @Test func aNegativeSerialIsStillRefused() throws {
        for name in ["YEAR", "MONTH", "DAY", "WEEKDAY"] {
            #expect(try eval(name, .number(-1)) == .error(.num), "\(name)(-1)")
        }
        #expect(try eval("EOMONTH", .number(-1), .number(0)) == .error(.num))
        #expect(try eval("EDATE", .number(-1), .number(0)) == .error(.num))
    }

    /// 9999-12-31 is the last date Excel will name, and one past it is `#NUM!`.
    ///
    /// **This package had no ceiling at all.** `YEAR(2958466)` answered 10000 and
    /// `EOMONTH(2958465, 1)` answered 2958496 — a serial for a date Excel refuses to name.
    /// Found in the same round as the floor, going the other way: the guard was wrong at
    /// both ends, and only one end had a corpus behind it.
    @Test func theSerialCeilingIsTheLastDateExcelWillName() throws {
        // The last valid day, as controls.
        #expect(try eval("YEAR", .number(2958465)).isNumber(9999))
        #expect(try eval("MONTH", .number(2958465)).isNumber(12))
        #expect(try eval("DAY", .number(2958465)).isNumber(31))

        #expect(try eval("YEAR", .number(2958466)) == .error(.num), "one day past the end")
        #expect(try eval("EOMONTH", .number(2958465), .number(1)) == .error(.num), "a month past the end is a date Excel will not name")
    }

    // MARK: - Helpers

    private func function(named name: String) -> ExcelFunction {
        guard let fn = BuiltinDateTimeFunctions.all.first(where: { $0.name == name }) else {
            fatalError("Function \(name) not found in BuiltinDateTimeFunctions.all")
        }
        return fn
    }

    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        try function(named: name).evaluate(args)
    }



    // MARK: - Registration count

    /// The group's inventory, asserted by name rather than only by count.
    ///
    /// A count alone says a function was added but not which, and it fails the
    /// same way whether something arrived or something was lost.
    @Test func allContainsEveryFunctionInTheGroup() {
        #expect(Set(BuiltinDateTimeFunctions.all.map(\.name)) == Set(("TODAY, NOW, YEAR, MONTH, DAY, DATE, WEEKDAY, EOMONTH, EDATE, DAYS, "
                 + "HOUR, MINUTE, SECOND, WORKDAY, DATEVALUE, TIME")
                .split(separator: ", ").map(String.init)))
    }

    // MARK: - DATE

    @Test func dateJan1_1900() throws {
        // Serial 1 = Jan 1, 1900
        let result = try eval("DATE", .number(1900), .number(1), .number(1))
        #expect(result.isNumber(1))
    }

    @Test func dateJan2_1900() throws {
        let result = try eval("DATE", .number(1900), .number(1), .number(2))
        #expect(result.isNumber(2))
    }

    @Test func dateFeb28_1900() throws {
        // Feb 28, 1900 = serial 59
        let result = try eval("DATE", .number(1900), .number(2), .number(28))
        #expect(result.isNumber(59))
    }

    @Test func dateFeb29_1900_PhantomDay() throws {
        // Excel's bug: Feb 29, 1900 = serial 60 (this day doesn't actually exist)
        let result = try eval("DATE", .number(1900), .number(2), .number(29))
        #expect(result.isNumber(60))
    }

    @Test func dateMar1_1900() throws {
        // Mar 1, 1900 = serial 61
        let result = try eval("DATE", .number(1900), .number(3), .number(1))
        #expect(result.isNumber(61))
    }

    @Test func dateJan1_2024() throws {
        // Known value: Jan 1, 2024 = serial 45292
        let result = try eval("DATE", .number(2024), .number(1), .number(1))
        #expect(result.isNumber(45292))
    }

    @Test func dateDec31_1999() throws {
        // Dec 31, 1999 = serial 36525 (common reference point)
        let result = try eval("DATE", .number(1999), .number(12), .number(31))
        #expect(result.isNumber(36525))
    }

    @Test func dateShortYear() throws {
        // Year 0-1899 are treated as 1900-3799
        // DATE(24, 1, 1) = DATE(1924, 1, 1) = serial 8767
        let result = try eval("DATE", .number(24), .number(1), .number(1))
        #expect(result.isNumber(8767))
    }

    // MARK: - YEAR

    @Test func yearSerial1() throws {
        let result = try eval("YEAR", .number(1))
        #expect(result.isNumber(1900))
    }

    @Test func yearSerial45292() throws {
        // Jan 1, 2024
        let result = try eval("YEAR", .number(45292))
        #expect(result.isNumber(2024))
    }

    @Test func yearSerial60() throws {
        // The phantom Feb 29, 1900
        let result = try eval("YEAR", .number(60))
        #expect(result.isNumber(1900))
    }

    @Test func yearErrorPropagation() throws {
        let result = try eval("YEAR", .error(.ref))
        #expect(result == .error(.ref))
    }

    // MARK: - MONTH

    @Test func monthJanuary() throws {
        let result = try eval("MONTH", .number(1))
        #expect(result.isNumber(1)) // Jan
    }

    @Test func monthSerial60() throws {
        // Phantom Feb 29, 1900
        let result = try eval("MONTH", .number(60))
        #expect(result.isNumber(2))
    }

    @Test func monthSerial61() throws {
        // Mar 1, 1900
        let result = try eval("MONTH", .number(61))
        #expect(result.isNumber(3))
    }

    @Test func monthDecember() throws {
        // Dec 31, 1999 = serial 36525
        let result = try eval("MONTH", .number(36525))
        #expect(result.isNumber(12))
    }

    // MARK: - DAY

    @Test func daySerial1() throws {
        // Jan 1
        let result = try eval("DAY", .number(1))
        #expect(result.isNumber(1))
    }

    @Test func daySerial59() throws {
        // Feb 28, 1900
        let result = try eval("DAY", .number(59))
        #expect(result.isNumber(28))
    }

    @Test func daySerial60() throws {
        // Phantom Feb 29, 1900
        let result = try eval("DAY", .number(60))
        #expect(result.isNumber(29))
    }

    @Test func daySerial61() throws {
        // Mar 1, 1900
        let result = try eval("DAY", .number(61))
        #expect(result.isNumber(1))
    }

    // MARK: - TODAY

    @Test func todayReturnsReasonableSerial() throws {
        let result = try eval("TODAY")
        guard case .number(let serial) = result else {
            Issue.record("Expected .number, got \(result)")
            return
        }
        // Today should be well past 2020 (serial > 43831 for Jan 1, 2020)
        #expect(serial > 43831)
        // And should be a whole number (no time component)
        #expect(serial == serial.rounded(.towardZero))
    }

    // MARK: - NOW

    @Test func nowReturnsSerialWithFraction() throws {
        let result = try eval("NOW")
        guard case .number(let serial) = result else {
            Issue.record("Expected .number, got \(result)")
            return
        }
        // NOW should be >= TODAY's value
        #expect(serial > 43831)
    }

    // MARK: - Roundtrip: DATE -> YEAR/MONTH/DAY

    @Test func roundtripDate() throws {
        // DATE(2024, 6, 15) -> serial -> YEAR/MONTH/DAY
        let serial = try eval("DATE", .number(2024), .number(6), .number(15))
        let y = try eval("YEAR", serial)
        let m = try eval("MONTH", serial)
        let d = try eval("DAY", serial)
        #expect(y.isNumber(2024))
        #expect(m.isNumber(6))
        #expect(d.isNumber(15))
    }

    @Test func roundtripDateLeapYear() throws {
        // Feb 29, 2024 (real leap year)
        let serial = try eval("DATE", .number(2024), .number(2), .number(29))
        let y = try eval("YEAR", serial)
        let m = try eval("MONTH", serial)
        let d = try eval("DAY", serial)
        #expect(y.isNumber(2024))
        #expect(m.isNumber(2))
        #expect(d.isNumber(29))
    }

    // MARK: - Metadata

    @Test func todayMetadata() {
        let fn = function(named: "TODAY")
        #expect(fn.minArgs == 0)
        #expect(fn.maxArgs == 0)
    }

    @Test func nowMetadata() {
        let fn = function(named: "NOW")
        #expect(fn.minArgs == 0)
        #expect(fn.maxArgs == 0)
    }

    @Test func yearMetadata() {
        let fn = function(named: "YEAR")
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == 1)
    }

    @Test func dateMetadata() {
        let fn = function(named: "DATE")
        #expect(fn.minArgs == 3)
        #expect(fn.maxArgs == 3)
    }
}
