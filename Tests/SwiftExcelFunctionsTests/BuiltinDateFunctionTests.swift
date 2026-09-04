import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

final class BuiltinDateFunctionTests: XCTestCase {

    // MARK: - Helpers

    private func function(named name: String) -> ExcelFunction {
        guard let fn = BuiltinDateFunctions.all.first(where: { $0.name == name }) else {
            fatalError("Function \(name) not found in BuiltinDateFunctions.all")
        }
        return fn
    }

    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        try function(named: name).evaluate(args)
    }

    private func assertNumber(
        _ result: CellValue,
        _ expected: Double,
        accuracy: Double = 1e-10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .number(let value) = result else {
            XCTFail("Expected .number(\(expected)), got \(result)", file: file, line: line)
            return
        }
        XCTAssertEqual(value, expected, accuracy: accuracy, file: file, line: line)
    }

    private func assertError(
        _ result: CellValue,
        _ expectedError: ExcelError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .error(let err) = result else {
            XCTFail("Expected .error(\(expectedError)), got \(result)", file: file, line: line)
            return
        }
        XCTAssertEqual(err, expectedError, file: file, line: line)
    }

    // MARK: - Registration count

    func testAllContainsSixFunctions() {
        XCTAssertEqual(BuiltinDateFunctions.all.count, 6)
    }

    // MARK: - DATE

    func testDATEJan1_1900() throws {
        // Serial 1 = Jan 1, 1900
        let result = try eval("DATE", .number(1900), .number(1), .number(1))
        assertNumber(result, 1)
    }

    func testDATEJan2_1900() throws {
        let result = try eval("DATE", .number(1900), .number(1), .number(2))
        assertNumber(result, 2)
    }

    func testDATEFeb28_1900() throws {
        // Feb 28, 1900 = serial 59
        let result = try eval("DATE", .number(1900), .number(2), .number(28))
        assertNumber(result, 59)
    }

    func testDATEFeb29_1900_PhantomDay() throws {
        // Excel's bug: Feb 29, 1900 = serial 60 (this day doesn't actually exist)
        let result = try eval("DATE", .number(1900), .number(2), .number(29))
        assertNumber(result, 60)
    }

    func testDATEMar1_1900() throws {
        // Mar 1, 1900 = serial 61
        let result = try eval("DATE", .number(1900), .number(3), .number(1))
        assertNumber(result, 61)
    }

    func testDATEJan1_2024() throws {
        // Known value: Jan 1, 2024 = serial 45292
        let result = try eval("DATE", .number(2024), .number(1), .number(1))
        assertNumber(result, 45292)
    }

    func testDATEDec31_1999() throws {
        // Dec 31, 1999 = serial 36525 (common reference point)
        let result = try eval("DATE", .number(1999), .number(12), .number(31))
        assertNumber(result, 36525)
    }

    func testDATEShortYear() throws {
        // Year 0-1899 are treated as 1900-3799
        // DATE(24, 1, 1) = DATE(1924, 1, 1) = serial 8767
        let result = try eval("DATE", .number(24), .number(1), .number(1))
        assertNumber(result, 8767)
    }

    // MARK: - YEAR

    func testYEARSerial1() throws {
        let result = try eval("YEAR", .number(1))
        assertNumber(result, 1900)
    }

    func testYEARSerial45292() throws {
        // Jan 1, 2024
        let result = try eval("YEAR", .number(45292))
        assertNumber(result, 2024)
    }

    func testYEARSerial60() throws {
        // The phantom Feb 29, 1900
        let result = try eval("YEAR", .number(60))
        assertNumber(result, 1900)
    }

    func testYEARErrorPropagation() throws {
        let result = try eval("YEAR", .error(.ref))
        assertError(result, .ref)
    }

    // MARK: - MONTH

    func testMONTHJanuary() throws {
        let result = try eval("MONTH", .number(1))
        assertNumber(result, 1) // Jan
    }

    func testMONTHSerial60() throws {
        // Phantom Feb 29, 1900
        let result = try eval("MONTH", .number(60))
        assertNumber(result, 2)
    }

    func testMONTHSerial61() throws {
        // Mar 1, 1900
        let result = try eval("MONTH", .number(61))
        assertNumber(result, 3)
    }

    func testMONTHDecember() throws {
        // Dec 31, 1999 = serial 36525
        let result = try eval("MONTH", .number(36525))
        assertNumber(result, 12)
    }

    // MARK: - DAY

    func testDAYSerial1() throws {
        // Jan 1
        let result = try eval("DAY", .number(1))
        assertNumber(result, 1)
    }

    func testDAYSerial59() throws {
        // Feb 28, 1900
        let result = try eval("DAY", .number(59))
        assertNumber(result, 28)
    }

    func testDAYSerial60() throws {
        // Phantom Feb 29, 1900
        let result = try eval("DAY", .number(60))
        assertNumber(result, 29)
    }

    func testDAYSerial61() throws {
        // Mar 1, 1900
        let result = try eval("DAY", .number(61))
        assertNumber(result, 1)
    }

    // MARK: - TODAY

    func testTODAYReturnsReasonableSerial() throws {
        let result = try eval("TODAY")
        guard case .number(let serial) = result else {
            XCTFail("Expected .number, got \(result)")
            return
        }
        // Today should be well past 2020 (serial > 43831 for Jan 1, 2020)
        XCTAssertGreaterThan(serial, 43831)
        // And should be a whole number (no time component)
        XCTAssertEqual(serial, serial.rounded(.towardZero))
    }

    // MARK: - NOW

    func testNOWReturnsSerialWithFraction() throws {
        let result = try eval("NOW")
        guard case .number(let serial) = result else {
            XCTFail("Expected .number, got \(result)")
            return
        }
        // NOW should be >= TODAY's value
        XCTAssertGreaterThan(serial, 43831)
    }

    // MARK: - Roundtrip: DATE -> YEAR/MONTH/DAY

    func testRoundtripDate() throws {
        // DATE(2024, 6, 15) -> serial -> YEAR/MONTH/DAY
        let serial = try eval("DATE", .number(2024), .number(6), .number(15))
        let y = try eval("YEAR", serial)
        let m = try eval("MONTH", serial)
        let d = try eval("DAY", serial)
        assertNumber(y, 2024)
        assertNumber(m, 6)
        assertNumber(d, 15)
    }

    func testRoundtripDateLeapYear() throws {
        // Feb 29, 2024 (real leap year)
        let serial = try eval("DATE", .number(2024), .number(2), .number(29))
        let y = try eval("YEAR", serial)
        let m = try eval("MONTH", serial)
        let d = try eval("DAY", serial)
        assertNumber(y, 2024)
        assertNumber(m, 2)
        assertNumber(d, 29)
    }

    // MARK: - Metadata

    func testTODAYMetadata() {
        let fn = function(named: "TODAY")
        XCTAssertEqual(fn.minArgs, 0)
        XCTAssertEqual(fn.maxArgs, 0)
    }

    func testNOWMetadata() {
        let fn = function(named: "NOW")
        XCTAssertEqual(fn.minArgs, 0)
        XCTAssertEqual(fn.maxArgs, 0)
    }

    func testYEARMetadata() {
        let fn = function(named: "YEAR")
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertEqual(fn.maxArgs, 1)
    }

    func testDATEMetadata() {
        let fn = function(named: "DATE")
        XCTAssertEqual(fn.minArgs, 3)
        XCTAssertEqual(fn.maxArgs, 3)
    }
}
