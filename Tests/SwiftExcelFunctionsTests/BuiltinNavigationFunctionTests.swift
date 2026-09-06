import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

final class BuiltinNavigationFunctionTests: XCTestCase {

    // MARK: - Helpers

    private func function(named name: String) -> ExcelFunction {
        guard let fn = BuiltinNavigationFunctions.all.first(where: { $0.name == name }) else {
            fatalError("Function \(name) not found in BuiltinNavigationFunctions.all")
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

    /// A table with the shape the test means, instead of one the callee has to
    /// guess. Guessing is what `VLOOKUP` used to do, and what it got wrong.
    private func grid(_ rows: [[CellValue]],
                      file: StaticString = #filePath, line: UInt = #line) -> CellValue {
        let width = rows.first?.count ?? 0
        guard rows.allSatisfy({ $0.count == width }),
              let matrix = CellMatrix(elements: rows.flatMap { $0 },
                                      rows: rows.count, columns: width) else {
            XCTFail("ragged table", file: file, line: line)
            return .error(.value)
        }
        return .array(matrix)
    }

    /// A lookup vector — one column, which is what `MATCH` and 1-D `INDEX` read.
    private func column(_ values: [CellValue]) -> CellValue {
        .array(CellMatrix(column: values))
    }

    // MARK: - Registration count

    /// The group's inventory, by name rather than by count — a count says
    /// something changed without saying what, and fails the same way whether a
    /// function arrived or went missing.
    func testAllContainsEveryFunctionInTheGroup() {
        XCTAssertEqual(
            Set(BuiltinNavigationFunctions.all.map(\.name)),
            ["VLOOKUP", "HLOOKUP", "XLOOKUP", "INDEX", "MATCH", "ADDRESS",
             "COLUMN", "ROW", "INDIRECT", "OFFSET", "CHOOSE", "LOOKUP",
             "ROWS", "COLUMNS", "HYPERLINK"])
    }

    // MARK: - VLOOKUP (exact match)

    func testVLOOKUPExactMatch() throws {
        // Table: 2 columns, 3 rows
        // 1 "A"
        // 2 "B"
        // 3 "C"
        let table = grid([[.number(1), .text("A")],
                          [.number(2), .text("B")],
                          [.number(3), .text("C")]])
        let result = try eval("VLOOKUP", .number(2), table, .number(2), .bool(false))
        XCTAssertEqual(result, .text("B"))
    }

    func testVLOOKUPExactMatchNotFound() throws {
        let table = grid([[.number(1), .text("A")],
                          [.number(2), .text("B")]])
        let result = try eval("VLOOKUP", .number(5), table, .number(2), .bool(false))
        assertError(result, .na)
    }

    func testVLOOKUPExactMatchCaseInsensitive() throws {
        let table = grid([[.text("apple"), .number(1)],
                          [.text("banana"), .number(2)]])
        let result = try eval("VLOOKUP", .text("APPLE"), table, .number(2), .bool(false))
        XCTAssertEqual(result, .number(1))
    }

    func testVLOOKUPApproximateMatch() throws {
        // Sorted ascending table
        let table = grid([[.number(10), .text("Low")],
                          [.number(20), .text("Mid")],
                          [.number(30), .text("High")]])
        // Looking for 25 should find 20 (largest <= 25)
        let result = try eval("VLOOKUP", .number(25), table, .number(2), .bool(true))
        XCTAssertEqual(result, .text("Mid"))
    }

    func testVLOOKUPApproximateMatchExact() throws {
        let table = grid([[.number(10), .text("Ten")],
                          [.number(20), .text("Twenty")]])
        let result = try eval("VLOOKUP", .number(20), table, .number(2), .bool(true))
        XCTAssertEqual(result, .text("Twenty"))
    }

    func testVLOOKUPDefaultIsApproximate() throws {
        let table = grid([[.number(10), .text("Low")],
                          [.number(20), .text("High")]])
        // No fourth argument: default is approximate (TRUE)
        let result = try eval("VLOOKUP", .number(15), table, .number(2))
        XCTAssertEqual(result, .text("Low"))
    }

    // MARK: - HLOOKUP

    func testHLOOKUPExactMatch() throws {
        // Table: 3 columns, 2 rows (row-major)
        // Row 1: 1, 2, 3
        // Row 2: A, B, C
        let table = grid([[.number(1), .number(2), .number(3)],
                          [.text("A"), .text("B"), .text("C")]])
        let result = try eval("HLOOKUP", .number(2), table, .number(2), .bool(false))
        XCTAssertEqual(result, .text("B"))
    }

    func testHLOOKUPNotFound() throws {
        let table = grid([[.number(1), .number(2)],
                          [.text("A"), .text("B")]])
        let result = try eval("HLOOKUP", .number(5), table, .number(2), .bool(false))
        assertError(result, .na)
    }

    // MARK: - INDEX

    func testINDEX1D() throws {
        let arr = column([.text("A"), .text("B"), .text("C"), .text("D")])
        let result = try eval("INDEX", arr, .number(3))
        XCTAssertEqual(result, .text("C"))
    }

    func testINDEXFirstElement() throws {
        let arr = column([.number(10), .number(20), .number(30)])
        let result = try eval("INDEX", arr, .number(1))
        XCTAssertEqual(result, .number(10))
    }

    func testINDEXOutOfBounds() throws {
        let arr = column([.number(10), .number(20)])
        let result = try eval("INDEX", arr, .number(5))
        assertError(result, .ref)
    }

    func testINDEXZeroReturnsError() throws {
        let arr = column([.number(10)])
        let result = try eval("INDEX", arr, .number(0))
        assertError(result, .value)
    }

    func testINDEX2D() throws {
        // 2x3 array (row-major):
        // 1  2  3
        // 4  5  6
        let arr = grid([[.number(1), .number(2), .number(3)],
                        [.number(4), .number(5), .number(6)]])
        let result = try eval("INDEX", arr, .number(2), .number(3))
        XCTAssertEqual(result, .number(6))
    }

    // MARK: - MATCH

    func testMATCHExact() throws {
        let arr = column([.text("A"), .text("B"), .text("C")])
        let result = try eval("MATCH", .text("B"), arr, .number(0))
        XCTAssertEqual(result, .number(2))
    }

    func testMATCHExactNotFound() throws {
        let arr = column([.text("A"), .text("B")])
        let result = try eval("MATCH", .text("D"), arr, .number(0))
        assertError(result, .na)
    }

    func testMATCHExactCaseInsensitive() throws {
        let arr = column([.text("apple"), .text("banana"), .text("cherry")])
        let result = try eval("MATCH", .text("BANANA"), arr, .number(0))
        XCTAssertEqual(result, .number(2))
    }

    func testMATCHSortedAscending() throws {
        let arr = column([.number(10), .number(20), .number(30)])
        // Find largest <= 25
        let result = try eval("MATCH", .number(25), arr, .number(1))
        XCTAssertEqual(result, .number(2)) // Position of 20
    }

    func testMATCHSortedAscendingExact() throws {
        let arr = column([.number(10), .number(20), .number(30)])
        let result = try eval("MATCH", .number(20), arr, .number(1))
        XCTAssertEqual(result, .number(2))
    }

    func testMATCHSortedDescending() throws {
        let arr = column([.number(30), .number(20), .number(10)])
        // Find smallest >= 15
        let result = try eval("MATCH", .number(15), arr, .number(-1))
        XCTAssertEqual(result, .number(2)) // Position of 20
    }

    func testMATCHDefaultIsAscending() throws {
        let arr = column([.number(1), .number(2), .number(3)])
        // No match_type argument: default is 1 (sorted ascending)
        let result = try eval("MATCH", .number(2), arr)
        XCTAssertEqual(result, .number(2))
    }

    func testMATCHEmptyArray() throws {
        let arr = column([])
        let result = try eval("MATCH", .number(1), arr, .number(0))
        assertError(result, .na)
    }

    // MARK: - Metadata

    func testVLOOKUPMetadata() {
        let fn = function(named: "VLOOKUP")
        XCTAssertEqual(fn.minArgs, 3)
        XCTAssertEqual(fn.maxArgs, 4)
    }

    func testINDEXMetadata() {
        let fn = function(named: "INDEX")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 3)
    }

    func testMATCHMetadata() {
        let fn = function(named: "MATCH")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 3)
    }

    // MARK: - Error propagation

    func testVLOOKUPErrorInColIndex() throws {
        let table = grid([[.number(1), .text("A")]])
        let result = try eval("VLOOKUP", .number(1), table, .error(.ref), .bool(false))
        assertError(result, .ref)
    }

    func testMATCHErrorInLookupValue() throws {
        let arr = column([.number(1)])
        let result = try eval("MATCH", .error(.na), arr, .number(0))
        // Error in lookup value: won't match any cell, returns #N/A
        assertError(result, .na)
    }
}
