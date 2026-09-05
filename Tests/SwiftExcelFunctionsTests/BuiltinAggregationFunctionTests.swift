import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

final class BuiltinAggregationFunctionTests: XCTestCase {

    // MARK: - Helpers

    private func function(named name: String) -> ExcelFunction {
        guard let fn = BuiltinAggregationFunctions.all.first(where: { $0.name == name }) else {
            fatalError("Function \(name) not found in BuiltinAggregationFunctions.all")
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

    /// By name rather than by count: a count says something changed without
    /// saying what, and fails the same way whether a function arrived or went.
    func testAllContainsEveryFunctionInTheGroup() {
        XCTAssertEqual(
            Set(BuiltinAggregationFunctions.all.map(\.name)),
            ["SUM", "SUMIF", "SUMIFS", "COUNTIF", "COUNTIFS", "AVERAGEIF",
             "SUMPRODUCT", "SUMSQ"])
    }

    // MARK: - SUM

    func testSUMBasic() throws {
        let result = try eval("SUM", .number(1), .number(2), .number(3))
        assertNumber(result, 6)
    }

    func testSUMWithArray() throws {
        let result = try eval("SUM", .array([.number(1), .number(2), .number(3)]))
        assertNumber(result, 6)
    }

    func testSUMIgnoresText() throws {
        let result = try eval("SUM", .number(1), .text("hello"), .number(2))
        assertNumber(result, 3)
    }

    func testSUMIgnoresBlank() throws {
        let result = try eval("SUM", .number(1), .blank, .number(2))
        assertNumber(result, 3)
    }

    func testSUMFlattensNestedArrays() throws {
        let result = try eval("SUM",
            .array([.number(1), .number(2)]),
            .number(3),
            .array([.number(4)])
        )
        assertNumber(result, 10)
    }

    func testSUMErrorPropagation() throws {
        let result = try eval("SUM", .number(1), .error(.ref), .number(2))
        assertError(result, .ref)
    }

    func testSUMBoolValues() throws {
        // In SUM, TRUE=1, FALSE=0
        let result = try eval("SUM", .bool(true), .bool(false), .number(3))
        assertNumber(result, 4)
    }

    func testSUMSingleValue() throws {
        let result = try eval("SUM", .number(42))
        assertNumber(result, 42)
    }

    // MARK: - SUMIF

    func testSUMIFGreaterThan() throws {
        let range: CellValue = .array([.number(1), .number(5), .number(10), .number(15)])
        let result = try eval("SUMIF", range, .text(">5"))
        assertNumber(result, 25) // 10 + 15
    }

    func testSUMIFEquals() throws {
        let range: CellValue = .array([.number(1), .number(2), .number(1), .number(3)])
        let result = try eval("SUMIF", range, .text("1"))
        assertNumber(result, 2) // 1 + 1
    }

    func testSUMIFNotEqual() throws {
        let range: CellValue = .array([.number(0), .number(5), .number(0), .number(10)])
        let result = try eval("SUMIF", range, .text("<>0"))
        assertNumber(result, 15) // 5 + 10
    }

    func testSUMIFWithSumRange() throws {
        let criteriaRange: CellValue = .array([.text("A"), .text("B"), .text("A"), .text("C")])
        let sumRange: CellValue = .array([.number(10), .number(20), .number(30), .number(40)])
        let result = try eval("SUMIF", criteriaRange, .text("A"), sumRange)
        assertNumber(result, 40) // 10 + 30
    }

    func testSUMIFGreaterOrEqual() throws {
        let range: CellValue = .array([.number(1), .number(5), .number(10)])
        let result = try eval("SUMIF", range, .text(">=5"))
        assertNumber(result, 15) // 5 + 10
    }

    func testSUMIFLessThan() throws {
        let range: CellValue = .array([.number(1), .number(5), .number(10)])
        let result = try eval("SUMIF", range, .text("<5"))
        assertNumber(result, 1)
    }

    func testSUMIFNoMatch() throws {
        let range: CellValue = .array([.number(1), .number(2), .number(3)])
        let result = try eval("SUMIF", range, .text(">100"))
        assertNumber(result, 0)
    }

    // MARK: - SUMIFS

    func testSUMIFSMultipleCriteria() throws {
        let sumRange: CellValue = .array([.number(10), .number(20), .number(30), .number(40)])
        let criteria1Range: CellValue = .array([.text("A"), .text("B"), .text("A"), .text("B")])
        let criteria2Range: CellValue = .array([.number(1), .number(2), .number(3), .number(4)])
        let result = try eval("SUMIFS",
            sumRange,
            criteria1Range, .text("A"),
            criteria2Range, .text(">1")
        )
        assertNumber(result, 30) // Only index 2 matches (A and 3 > 1)
    }

    func testSUMIFSSingleCriteria() throws {
        let sumRange: CellValue = .array([.number(10), .number(20), .number(30)])
        let criteriaRange: CellValue = .array([.text("A"), .text("B"), .text("A")])
        let result = try eval("SUMIFS", sumRange, criteriaRange, .text("A"))
        assertNumber(result, 40) // 10 + 30
    }

    // MARK: - COUNTIF

    func testCOUNTIFEquals() throws {
        let range: CellValue = .array([.number(1), .number(2), .number(1), .number(3), .number(1)])
        let result = try eval("COUNTIF", range, .text("1"))
        assertNumber(result, 3)
    }

    func testCOUNTIFGreaterThan() throws {
        let range: CellValue = .array([.number(1), .number(5), .number(10)])
        let result = try eval("COUNTIF", range, .text(">3"))
        assertNumber(result, 2) // 5 and 10
    }

    func testCOUNTIFText() throws {
        let range: CellValue = .array([.text("apple"), .text("banana"), .text("apple")])
        let result = try eval("COUNTIF", range, .text("apple"))
        assertNumber(result, 2)
    }

    func testCOUNTIFNoMatch() throws {
        let range: CellValue = .array([.number(1), .number(2)])
        let result = try eval("COUNTIF", range, .text(">100"))
        assertNumber(result, 0)
    }

    func testCOUNTIFCaseInsensitive() throws {
        let range: CellValue = .array([.text("Apple"), .text("APPLE"), .text("apple")])
        let result = try eval("COUNTIF", range, .text("apple"))
        assertNumber(result, 3)
    }

    // MARK: - COUNTIFS

    func testCOUNTIFSMultipleCriteria() throws {
        let range1: CellValue = .array([.text("A"), .text("B"), .text("A"), .text("A")])
        let range2: CellValue = .array([.number(1), .number(2), .number(3), .number(1)])
        let result = try eval("COUNTIFS",
            range1, .text("A"),
            range2, .text(">1")
        )
        assertNumber(result, 1) // Only index 2 (A and 3 > 1)
    }

    func testCOUNTIFSSingleCriteria() throws {
        let range: CellValue = .array([.number(1), .number(2), .number(3)])
        let result = try eval("COUNTIFS", range, .text(">=2"))
        assertNumber(result, 2) // 2 and 3
    }

    // MARK: - AVERAGEIF

    func testAVERAGEIFBasic() throws {
        let range: CellValue = .array([.number(10), .number(20), .number(30)])
        let result = try eval("AVERAGEIF", range, .text(">5"))
        assertNumber(result, 20) // (10 + 20 + 30) / 3
    }

    func testAVERAGEIFWithRange() throws {
        let criteriaRange: CellValue = .array([.text("A"), .text("B"), .text("A")])
        let avgRange: CellValue = .array([.number(10), .number(20), .number(30)])
        let result = try eval("AVERAGEIF", criteriaRange, .text("A"), avgRange)
        assertNumber(result, 20) // (10 + 30) / 2
    }

    func testAVERAGEIFNoMatch() throws {
        let range: CellValue = .array([.number(1), .number(2)])
        let result = try eval("AVERAGEIF", range, .text(">100"))
        assertError(result, .div0)
    }

    func testAVERAGEIFSingleMatch() throws {
        let range: CellValue = .array([.number(10), .number(20), .number(30)])
        let result = try eval("AVERAGEIF", range, .text("20"))
        assertNumber(result, 20)
    }

    // MARK: - Criteria matching edge cases

    func testMatchesCriteriaLessOrEqual() throws {
        let range: CellValue = .array([.number(1), .number(5), .number(10)])
        let result = try eval("COUNTIF", range, .text("<=5"))
        assertNumber(result, 2) // 1 and 5
    }

    func testMatchesCriteriaEqualsPrefix() throws {
        let range: CellValue = .array([.text("hello"), .text("world")])
        let result = try eval("COUNTIF", range, .text("=hello"))
        assertNumber(result, 1)
    }

    func testMatchesCriteriaNumericAsString() throws {
        // When criteria is "5" (no operator), it matches number 5
        let range: CellValue = .array([.number(3), .number(5), .number(7)])
        let result = try eval("COUNTIF", range, .number(5))
        assertNumber(result, 1)
    }

    // MARK: - Metadata

    func testSUMMetadata() {
        let fn = function(named: "SUM")
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertNil(fn.maxArgs)
    }

    func testSUMIFMetadata() {
        let fn = function(named: "SUMIF")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 3)
    }

    func testSUMIFSMetadata() {
        let fn = function(named: "SUMIFS")
        XCTAssertEqual(fn.minArgs, 3)
        XCTAssertNil(fn.maxArgs)
    }

    func testCOUNTIFMetadata() {
        let fn = function(named: "COUNTIF")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 2)
    }

    func testCOUNTIFSMetadata() {
        let fn = function(named: "COUNTIFS")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertNil(fn.maxArgs)
    }

    func testAVERAGEIFMetadata() {
        let fn = function(named: "AVERAGEIF")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 3)
    }
}
