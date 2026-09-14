import Foundation
import SwiftExcelCore
import XCTest
@testable import SwiftExcelFunctions

/// `TEXT` with a date or time format code.
///
/// ## Where the expected values come from
///
/// The weekday cases are **measured against Excel**, not derived: the oracle found 127 cells
/// across 46 real workbooks where `TEXT(serial, "ddd")` returned the serial as a number, and
/// recorded what Excel had cached for each. Those pairs are the test.
///
/// That matters because a weekday is exactly the sort of value that can be wrong by one and
/// look entirely plausible — every answer is a real day of the week.
final class TextDateFormatTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    private func text(_ serial: Double, _ format: String) throws -> String {
        let function = try XCTUnwrap(registry.function(named: "TEXT"))
        let result = try function.evaluate([.number(serial), .text(format)])
        guard case .text(let value) = result else {
            XCTFail("TEXT(\(serial), \(format)) returned \(result)"); return ""
        }
        return value
    }

    // MARK: - Measured against Excel

    /// Serial-to-weekday pairs taken from Excel's own cached values.
    func testWeekdayAbbreviationsMatchExcel() throws {
        let measured: [(Double, String)] = [
            (41572, "Fri"), (41573, "Sat"), (41574, "Sun"), (41575, "Mon"),
            (41576, "Tue"), (41577, "Wed"), (41578, "Thu"), (41579, "Fri"),
            (41580, "Sat"), (41581, "Sun"), (41582, "Mon"), (41583, "Tue"),
        ]
        for (serial, expected) in measured {
            XCTAssertEqual(try text(serial, "ddd"), expected, "serial \(serial)")
        }
    }

    /// The weekday comes from the serial, as `WEEKDAY` computes it.
    ///
    /// Two routes to one answer must not disagree — the reason `IMPOWER` was rewritten. A
    /// `Calendar` would also be wrong across Excel's phantom 29 February 1900, because the
    /// bug lives in the serial numbering rather than in any real calendar.
    func testTheWeekdayAgreesWithTheWeekdayFunction() throws {
        let weekday = try XCTUnwrap(registry.function(named: "WEEKDAY"))
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        for serial in stride(from: 40000.0, through: 40020.0, by: 1) {
            let result = try weekday.evaluate([.number(serial)])
            guard case .number(let index) = result else { return XCTFail("WEEKDAY gave \(result)") }
            XCTAssertEqual(try text(serial, "dddd"), names[Int(index) - 1], "serial \(serial)")
        }
    }

    // MARK: - The rest of the family

    func testTheDateComponents() throws {
        // Serial 41583 is Tuesday 5 November 2013.
        XCTAssertEqual(try text(41583, "dddd"), "Tuesday")
        XCTAssertEqual(try text(41583, "yyyy"), "2013")
        XCTAssertEqual(try text(41583, "yy"), "13")
        XCTAssertEqual(try text(41583, "mmm"), "Nov")
        XCTAssertEqual(try text(41583, "mmmm"), "November")
        XCTAssertEqual(try text(41583, "mmmmm"), "N")
        XCTAssertEqual(try text(41583, "d"), "5")
        XCTAssertEqual(try text(41583, "dd"), "05")
        XCTAssertEqual(try text(41583, "mm/dd/yyyy"), "11/05/2013")
        XCTAssertEqual(try text(41583, "d mmm yyyy"), "5 Nov 2013")
    }

    func testTheTimeComponents() throws {
        // .53125 of a day is 12:45:00.
        XCTAssertEqual(try text(41583.53125, "h:mm"), "12:45")
        XCTAssertEqual(try text(41583.53125, "hh:mm:ss"), "12:45:00")
        XCTAssertEqual(try text(41583.53125, "h:mm AM/PM"), "12:45 PM")
        // Midnight's hour is 12 on a twelve-hour clock, not 0 — the one case where the
        // twelve-hour conversion is not a remainder.
        XCTAssertEqual(try text(41583.03125, "h:mm AM/PM"), "12:45 AM")
        XCTAssertEqual(try text(41583.03125, "h:mm"), "0:45", "the 24-hour clock does use 0")
    }

    /// `m` is minutes after an hour code and months otherwise — the same two characters.
    ///
    /// Reading them the same way is wrong in one case and never looks wrong: both produce a
    /// small number where a small number belongs.
    func testMMeansMinutesOnlyBesideAnHourOrSecond() throws {
        // 5 November, 12:45 — month 11, minute 45, and both spelled `mm`.
        XCTAssertEqual(try text(41583.53125, "mm"), "11", "alone, mm is the month")
        XCTAssertEqual(try text(41583.53125, "h:mm"), "12:45", "after h, mm is minutes")
        XCTAssertEqual(try text(41583.53125, "mm:ss"), "45:00", "before s, mm is minutes")
        XCTAssertEqual(try text(41583.53125, "mm/dd"), "11/05", "before d, mm is the month")
    }

    // MARK: - Number formats are untouched

    func testNumberFormatsStillWork() throws {
        XCTAssertEqual(try text(3.14159, "0.00"), "3.14")
        XCTAssertEqual(try text(1234567, "#,##0"), "1,234,567")
        XCTAssertEqual(try text(0.25, "0%"), "25%")
    }

    /// A format with no date letters is a number format, whatever else is in it.
    func testTheTwoFamiliesAreToldApartByTheirLetters() {
        XCTAssertTrue(ExcelDateFormat.isDateFormat("ddd"))
        XCTAssertTrue(ExcelDateFormat.isDateFormat("mm/dd/yyyy"))
        XCTAssertTrue(ExcelDateFormat.isDateFormat("h:mm:ss"))
        XCTAssertFalse(ExcelDateFormat.isDateFormat("0.00"))
        XCTAssertFalse(ExcelDateFormat.isDateFormat("#,##0"))
        XCTAssertFalse(ExcelDateFormat.isDateFormat("0%"))
    }
}
