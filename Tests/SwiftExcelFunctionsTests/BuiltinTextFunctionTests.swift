import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

final class BuiltinTextFunctionTests: XCTestCase {

    // MARK: - Helpers

    private func function(named name: String) -> ExcelFunction {
        guard let fn = BuiltinTextFunctions.all.first(where: { $0.name == name }) else {
            fatalError("Function \(name) not found in BuiltinTextFunctions.all")
        }
        return fn
    }

    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        try function(named: name).evaluate(args)
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

    // MARK: - Registration

    /// The group's inventory, by name rather than by count — a count says something
    /// changed without saying what, and fails the same way whether a function
    /// arrived or went missing.
    func testAllContainsEveryFunctionInTheGroup() {
        XCTAssertEqual(
            Set(BuiltinTextFunctions.all.map(\.name)),
            ["LEN", "LEFT", "RIGHT", "MID", "TRIM", "UPPER", "LOWER", "CONCATENATE",
             "TEXT", "FIND", "SEARCH", "SUBSTITUTE", "PROPER", "CLEAN", "NUMBERVALUE"])
    }

    // MARK: - LEN

    func testLENBasic() throws {
        let result = try eval("LEN", .text("Hello"))
        XCTAssertEqual(result, .number(5))
    }

    func testLENEmpty() throws {
        let result = try eval("LEN", .text(""))
        XCTAssertEqual(result, .number(0))
    }

    func testLENBlank() throws {
        let result = try eval("LEN", .blank)
        XCTAssertEqual(result, .number(0))
    }

    func testLENNumber() throws {
        let result = try eval("LEN", .number(123))
        XCTAssertEqual(result, .number(3))
    }

    func testLENBool() throws {
        let result = try eval("LEN", .bool(true))
        XCTAssertEqual(result, .number(4)) // "TRUE" = 4 chars
    }

    func testLENErrorPropagation() throws {
        let result = try eval("LEN", .error(.ref))
        assertError(result, .ref)
    }

    // MARK: - LEFT

    func testLEFTDefault() throws {
        let result = try eval("LEFT", .text("Hello"))
        XCTAssertEqual(result, .text("H"))
    }

    func testLEFTWithCount() throws {
        let result = try eval("LEFT", .text("Hello"), .number(3))
        XCTAssertEqual(result, .text("Hel"))
    }

    func testLEFTExceedsLength() throws {
        let result = try eval("LEFT", .text("Hi"), .number(10))
        XCTAssertEqual(result, .text("Hi"))
    }

    func testLEFTZero() throws {
        let result = try eval("LEFT", .text("Hello"), .number(0))
        XCTAssertEqual(result, .text(""))
    }

    func testLEFTNegativeReturnsError() throws {
        let result = try eval("LEFT", .text("Hello"), .number(-1))
        assertError(result, .num)
    }

    // MARK: - RIGHT

    func testRIGHTDefault() throws {
        let result = try eval("RIGHT", .text("Hello"))
        XCTAssertEqual(result, .text("o"))
    }

    func testRIGHTWithCount() throws {
        let result = try eval("RIGHT", .text("Hello"), .number(3))
        XCTAssertEqual(result, .text("llo"))
    }

    func testRIGHTExceedsLength() throws {
        let result = try eval("RIGHT", .text("Hi"), .number(10))
        XCTAssertEqual(result, .text("Hi"))
    }

    func testRIGHTZero() throws {
        let result = try eval("RIGHT", .text("Hello"), .number(0))
        XCTAssertEqual(result, .text(""))
    }

    // MARK: - MID

    func testMIDBasic() throws {
        let result = try eval("MID", .text("Hello World"), .number(7), .number(5))
        XCTAssertEqual(result, .text("World"))
    }

    func testMIDFromStart() throws {
        let result = try eval("MID", .text("Hello"), .number(1), .number(3))
        XCTAssertEqual(result, .text("Hel"))
    }

    func testMIDExceedsLength() throws {
        let result = try eval("MID", .text("Hi"), .number(1), .number(10))
        XCTAssertEqual(result, .text("Hi"))
    }

    func testMIDStartBeyondEnd() throws {
        let result = try eval("MID", .text("Hi"), .number(10), .number(1))
        XCTAssertEqual(result, .text(""))
    }

    func testMIDStartZeroReturnsError() throws {
        let result = try eval("MID", .text("Hello"), .number(0), .number(1))
        assertError(result, .num)
    }

    // MARK: - TRIM

    func testTRIMLeadingTrailing() throws {
        let result = try eval("TRIM", .text("  Hello  "))
        XCTAssertEqual(result, .text("Hello"))
    }

    func testTRIMInternalSpaces() throws {
        let result = try eval("TRIM", .text("  Hello   World  "))
        XCTAssertEqual(result, .text("Hello World"))
    }

    func testTRIMNoSpaces() throws {
        let result = try eval("TRIM", .text("Hello"))
        XCTAssertEqual(result, .text("Hello"))
    }

    func testTRIMBlank() throws {
        let result = try eval("TRIM", .blank)
        XCTAssertEqual(result, .text(""))
    }

    // MARK: - UPPER

    func testUPPERBasic() throws {
        let result = try eval("UPPER", .text("hello"))
        XCTAssertEqual(result, .text("HELLO"))
    }

    func testUPPERMixed() throws {
        let result = try eval("UPPER", .text("Hello World"))
        XCTAssertEqual(result, .text("HELLO WORLD"))
    }

    func testUPPERNumber() throws {
        let result = try eval("UPPER", .number(42))
        XCTAssertEqual(result, .text("42"))
    }

    // MARK: - LOWER

    func testLOWERBasic() throws {
        let result = try eval("LOWER", .text("HELLO"))
        XCTAssertEqual(result, .text("hello"))
    }

    func testLOWERMixed() throws {
        let result = try eval("LOWER", .text("Hello World"))
        XCTAssertEqual(result, .text("hello world"))
    }

    // MARK: - CONCATENATE

    func testCONCATENATEBasic() throws {
        let result = try eval("CONCATENATE", .text("Hello"), .text(" "), .text("World"))
        XCTAssertEqual(result, .text("Hello World"))
    }

    func testCONCATENATEMixedTypes() throws {
        let result = try eval("CONCATENATE", .text("Value: "), .number(42))
        XCTAssertEqual(result, .text("Value: 42"))
    }

    func testCONCATENATEBool() throws {
        let result = try eval("CONCATENATE", .text("Is: "), .bool(true))
        XCTAssertEqual(result, .text("Is: TRUE"))
    }

    func testCONCATENATEBlank() throws {
        let result = try eval("CONCATENATE", .text("Hello"), .blank, .text("World"))
        XCTAssertEqual(result, .text("HelloWorld"))
    }

    func testCONCATENATESingle() throws {
        let result = try eval("CONCATENATE", .text("Solo"))
        XCTAssertEqual(result, .text("Solo"))
    }

    func testCONCATENATEErrorPropagation() throws {
        let result = try eval("CONCATENATE", .text("Hello"), .error(.na))
        assertError(result, .na)
    }

    // MARK: - TEXT

    func testTEXTInteger() throws {
        let result = try eval("TEXT", .number(1234.7), .text("0"))
        XCTAssertEqual(result, .text("1235"))
    }

    func testTEXTTwoDecimals() throws {
        let result = try eval("TEXT", .number(1234.5), .text("0.00"))
        XCTAssertEqual(result, .text("1234.50"))
    }

    func testTEXTThousands() throws {
        let result = try eval("TEXT", .number(1234567), .text("#,##0"))
        XCTAssertEqual(result, .text("1,234,567"))
    }

    func testTEXTThousandsWithDecimals() throws {
        let result = try eval("TEXT", .number(1234.5), .text("#,##0.00"))
        XCTAssertEqual(result, .text("1,234.50"))
    }

    func testTEXTPercent() throws {
        let result = try eval("TEXT", .number(0.126), .text("0%"))
        XCTAssertEqual(result, .text("13%"))
    }

    func testTEXTPercentWithDecimals() throws {
        let result = try eval("TEXT", .number(0.125), .text("0.00%"))
        XCTAssertEqual(result, .text("12.50%"))
    }

    func testTEXTErrorPropagation() throws {
        let result = try eval("TEXT", .error(.value), .text("0.00"))
        assertError(result, .value)
    }

    // MARK: - Metadata

    func testLENMetadata() {
        let fn = function(named: "LEN")
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertEqual(fn.maxArgs, 1)
    }

    func testLEFTMetadata() {
        let fn = function(named: "LEFT")
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertEqual(fn.maxArgs, 2)
    }

    func testMIDMetadata() {
        let fn = function(named: "MID")
        XCTAssertEqual(fn.minArgs, 3)
        XCTAssertEqual(fn.maxArgs, 3)
    }

    func testCONCATENATEMetadata() {
        let fn = function(named: "CONCATENATE")
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertNil(fn.maxArgs)
    }

    func testTEXTMetadata() {
        let fn = function(named: "TEXT")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 2)
    }
}
