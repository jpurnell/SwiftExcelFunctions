import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The date functions real models use that this package did not have.
///
/// `WEEKDAY` is called 5,477 times across 79 workbooks and `EOMONTH` 1,723 —
/// the latter on 22 sheets, because a settlement or period-end date is how a
/// financial model steps through time.
///
/// Excel counts days from 1900-01-01 with serial 1, and believes 1900 was a leap
/// year. Serial 60 is a Feb 29th that never happened. Every function here inherits
/// that from the conversion already in this file, which is right: matching Excel
/// matters more than matching the calendar.
@Suite struct DateTimeAdditionTests {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: [CellValue]) throws -> CellValue {
        let function = try #require(registry.function(named: name), "\(name) is not registered")
        return try function.evaluate(args)
    }

    private func number(_ name: String, _ args: [CellValue]) throws -> Double {
        guard case .number(let value) = try call(name, args) else {
            throw TestFailure("\(name) did not return a number")
        }
        return value
    }

    /// 2026-09-04 is serial 46269 and a Friday.
    ///
    /// Confirmed against this package's own `DATE`, not asserted from memory —
    /// the first draft of this file used 46265 and failed eight tests before the
    /// implementation was ever in question.
    private let friday = CellValue.number(46269)

    // MARK: - WEEKDAY

    /// Excel's default numbering starts the week on Sunday at 1, so Friday is 6.
    @Test func weekdayDefaultsToSundayAsOne() throws {
        #expect(try number("WEEKDAY", [friday]).isEqual(to: 6))
    }

    /// Type 2 starts the week on Monday at 1, making Friday 5. The type argument
    /// is why this cannot be a one-liner over a calendar's own numbering.
    @Test func weekdayHonoursItsTypeArgument() throws {
        #expect(try number("WEEKDAY", [friday, .number(1)]).isEqual(to: 6), "Sunday = 1")
        #expect(try number("WEEKDAY", [friday, .number(2)]).isEqual(to: 5), "Monday = 1")
        #expect(try number("WEEKDAY", [friday, .number(3)]).isEqual(to: 4), "Monday = 0")
    }

    // MARK: - EOMONTH and EDATE

    /// The last day of the month, `months` away. September 2026 ends on the 30th.
    @Test func eomonthFindsTheLastDayOfTheMonth() throws {
        let serial = try number("EOMONTH", [friday, .number(0)])
        let (year, month, day) = BuiltinDateTimeFunctions.serialToComponents(Int(serial))
        #expect([year, month, day] as [Int] == [2026, 9, 30])
    }

    /// A negative offset walks backwards, and February is where an off-by-one shows.
    @Test func eomonthWalksBackwardsAndHandlesFebruary() throws {
        let serial = try number("EOMONTH", [friday, .number(-7)])
        let (year, month, day) = BuiltinDateTimeFunctions.serialToComponents(Int(serial))
        #expect([year, month, day] as [Int] == [2026, 2, 28], "2026 is not a leap year")
    }

    /// `EDATE` keeps the day of the month rather than moving to its end.
    @Test func edateKeepsTheDayOfMonth() throws {
        let serial = try number("EDATE", [friday, .number(1)])
        let (year, month, day) = BuiltinDateTimeFunctions.serialToComponents(Int(serial))
        #expect([year, month, day] as [Int] == [2026, 10, 4])
    }

    /// Where the day does not exist in the target month, Excel clamps to its end.
    @Test func edateClampsWhenTheDayDoesNotExist() throws {
        // 2026-01-31 + 1 month has no 31st of February.
        let january31 = CellValue.number(46053)
        let serial = try number("EDATE", [january31, .number(1)])
        let (_, month, day) = BuiltinDateTimeFunctions.serialToComponents(Int(serial))
        #expect([month, day] as [Int] == [2, 28])
    }

    // MARK: - DAYS

    @Test func daysIsTheDifferenceBetweenTwoSerials() throws {
        #expect(try number("DAYS", [.number(46269), .number(46264)]).isEqual(to: 5))
        #expect(try number("DAYS", [.number(46264), .number(46269)]).isEqual(to: -5), "order matters")
    }

    // MARK: - Time parts

    /// A serial's fractional part is the time of day: 0.5 is noon.
    @Test func timePartsReadTheFractionOfADay() throws {
        let noon = CellValue.number(46269.5)
        #expect(try number("HOUR", [noon]).isEqual(to: 12))
        #expect(try number("MINUTE", [noon]) == 0)
        #expect(try number("SECOND", [noon]) == 0)
    }

    @Test func timePartsResolveMinutesAndSeconds() throws {
        // 06:30:30 is 6.5083333... hours into the day.
        let morning = CellValue.number(46269 + (6 * 3600 + 30 * 60 + 30) / 86_400.0)
        #expect(try number("HOUR", [morning]).isEqual(to: 6))
        #expect(try number("MINUTE", [morning]).isEqual(to: 30))
        #expect(try number("SECOND", [morning]).isEqual(to: 30))
    }
}
