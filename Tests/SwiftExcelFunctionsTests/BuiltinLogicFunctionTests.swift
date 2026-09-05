import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

final class BuiltinLogicFunctionTests: XCTestCase {

    // MARK: - Helpers

    /// Look up a function by name from the built-in logical set.
    private func function(named name: String) -> ExcelFunction {
        guard let fn = BuiltinLogicFunctions.all.first(where: { $0.name == name }) else {
            fatalError("Function \(name) not found in BuiltinLogicFunctions.all")
        }
        return fn
    }

    /// Evaluate a function by name with the given arguments.
    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        try function(named: name).evaluate(args)
    }

    /// Assert a CellValue is a specific Excel error.
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

    /// The group's inventory, asserted by name rather than only by count.
    ///
    /// A count alone says a function was added but not which, and it fails the
    /// same way whether something arrived or something was lost.
    func testAllContainsEveryFunctionInTheGroup() {
        XCTAssertEqual(
            Set(BuiltinLogicFunctions.all.map(\.name)),
            ["IF", "AND", "OR", "NOT", "IFERROR", "IFNA",
             "ISERROR", "ISERR", "ISNA", "ISBLANK", "ISNUMBER", "ISTEXT", "NA", "ISREF"])
    }

    // MARK: - IF

    func testIFTrueCondition() throws {
        let result = try eval("IF", .bool(true), .text("yes"), .text("no"))
        XCTAssertEqual(result, .text("yes"))
    }

    func testIFFalseCondition() throws {
        let result = try eval("IF", .bool(false), .text("yes"), .text("no"))
        XCTAssertEqual(result, .text("no"))
    }

    func testIFNonZeroNumber() throws {
        let result = try eval("IF", .number(42), .text("truthy"), .text("falsy"))
        XCTAssertEqual(result, .text("truthy"))
    }

    func testIFZeroNumber() throws {
        let result = try eval("IF", .number(0), .text("truthy"), .text("falsy"))
        XCTAssertEqual(result, .text("falsy"))
    }

    func testIFBlankIsFalsy() throws {
        let result = try eval("IF", .blank, .text("truthy"), .text("falsy"))
        XCTAssertEqual(result, .text("falsy"))
    }

    func testIFTextReturnsValueError() throws {
        let result = try eval("IF", .text("hello"), .text("yes"), .text("no"))
        assertError(result, .value)
    }

    func testIFErrorPropagation() throws {
        let result = try eval("IF", .error(.ref), .text("yes"), .text("no"))
        assertError(result, .ref)
    }

    func testIFTwoArgs() throws {
        // IF with only 2 args: if false, return FALSE
        let result = try eval("IF", .bool(false), .text("yes"))
        XCTAssertEqual(result, .bool(false))
    }

    func testIFTwoArgsTrue() throws {
        let result = try eval("IF", .bool(true), .number(10))
        XCTAssertEqual(result, .number(10))
    }

    // MARK: - AND

    func testANDAllTrue() throws {
        let result = try eval("AND", .bool(true), .bool(true), .bool(true))
        XCTAssertEqual(result, .bool(true))
    }

    func testANDOneFalse() throws {
        let result = try eval("AND", .bool(true), .bool(false), .bool(true))
        XCTAssertEqual(result, .bool(false))
    }

    func testANDWithNumbers() throws {
        let result = try eval("AND", .number(1), .number(5), .number(-3))
        XCTAssertEqual(result, .bool(true))
    }

    func testANDWithZero() throws {
        let result = try eval("AND", .number(1), .number(0))
        XCTAssertEqual(result, .bool(false))
    }

    func testANDFlattensArrays() throws {
        let result = try eval("AND", .array([.bool(true), .bool(true)]), .bool(true))
        XCTAssertEqual(result, .bool(true))
    }

    func testANDFlattensArraysWithFalse() throws {
        let result = try eval("AND", .array([.bool(true), .bool(false)]))
        XCTAssertEqual(result, .bool(false))
    }

    func testANDErrorPropagation() throws {
        let result = try eval("AND", .bool(true), .error(.na))
        assertError(result, .na)
    }

    // MARK: - OR

    func testORAllFalse() throws {
        let result = try eval("OR", .bool(false), .bool(false))
        XCTAssertEqual(result, .bool(false))
    }

    func testOROneTrue() throws {
        let result = try eval("OR", .bool(false), .bool(true), .bool(false))
        XCTAssertEqual(result, .bool(true))
    }

    func testORWithNumbers() throws {
        let result = try eval("OR", .number(0), .number(5))
        XCTAssertEqual(result, .bool(true))
    }

    func testORAllZeros() throws {
        let result = try eval("OR", .number(0), .number(0))
        XCTAssertEqual(result, .bool(false))
    }

    func testORFlattensArrays() throws {
        let result = try eval("OR", .array([.bool(false), .bool(true)]))
        XCTAssertEqual(result, .bool(true))
    }

    func testORErrorPropagation() throws {
        let result = try eval("OR", .error(.div0), .bool(true))
        assertError(result, .div0)
    }

    // MARK: - NOT

    func testNOTTrue() throws {
        let result = try eval("NOT", .bool(true))
        XCTAssertEqual(result, .bool(false))
    }

    func testNOTFalse() throws {
        let result = try eval("NOT", .bool(false))
        XCTAssertEqual(result, .bool(true))
    }

    func testNOTNumber() throws {
        let result = try eval("NOT", .number(0))
        XCTAssertEqual(result, .bool(true))
    }

    func testNOTNonZero() throws {
        let result = try eval("NOT", .number(1))
        XCTAssertEqual(result, .bool(false))
    }

    func testNOTTextReturnsValueError() throws {
        let result = try eval("NOT", .text("hello"))
        assertError(result, .value)
    }

    func testNOTErrorPropagation() throws {
        let result = try eval("NOT", .error(.num))
        assertError(result, .num)
    }

    // MARK: - IFERROR

    func testIFERRORWithError() throws {
        let result = try eval("IFERROR", .error(.div0), .number(0))
        XCTAssertEqual(result, .number(0))
    }

    func testIFERRORWithoutError() throws {
        let result = try eval("IFERROR", .number(42), .number(0))
        XCTAssertEqual(result, .number(42))
    }

    func testIFERRORWithNAError() throws {
        let result = try eval("IFERROR", .error(.na), .text("not found"))
        XCTAssertEqual(result, .text("not found"))
    }

    func testIFERRORWithBlank() throws {
        let result = try eval("IFERROR", .blank, .number(0))
        XCTAssertEqual(result, .blank)
    }

    func testIFERRORWithText() throws {
        let result = try eval("IFERROR", .text("hello"), .number(0))
        XCTAssertEqual(result, .text("hello"))
    }

    // MARK: - IFNA

    func testIFNAWithNAError() throws {
        let result = try eval("IFNA", .error(.na), .text("not found"))
        XCTAssertEqual(result, .text("not found"))
    }

    func testIFNAWithOtherError() throws {
        // Non-NA errors pass through
        let result = try eval("IFNA", .error(.div0), .text("not found"))
        assertError(result, .div0)
    }

    func testIFNAWithValue() throws {
        let result = try eval("IFNA", .number(42), .text("not found"))
        XCTAssertEqual(result, .number(42))
    }

    func testIFNAWithBlank() throws {
        let result = try eval("IFNA", .blank, .text("not found"))
        XCTAssertEqual(result, .blank)
    }

    // MARK: - Metadata

    func testIFMetadata() {
        let fn = function(named: "IF")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 3)
    }

    func testANDMetadata() {
        let fn = function(named: "AND")
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertNil(fn.maxArgs)
    }

    func testORMetadata() {
        let fn = function(named: "OR")
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertNil(fn.maxArgs)
    }

    func testNOTMetadata() {
        let fn = function(named: "NOT")
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertEqual(fn.maxArgs, 1)
    }

    func testIFERRORMetadata() {
        let fn = function(named: "IFERROR")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 2)
    }

    func testIFNAMetadata() {
        let fn = function(named: "IFNA")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 2)
    }
}
