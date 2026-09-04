import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

final class BuiltinStatsFunctionTests: XCTestCase {

    // MARK: - Helpers

    /// Look up a function by name from the built-in stats set.
    private func function(named name: String) -> ExcelFunction {
        guard let fn = BuiltinStatsFunctions.all.first(where: { $0.name == name }) else {
            fatalError("Function \(name) not found in BuiltinStatsFunctions.all")
        }
        return fn
    }

    /// Evaluate a function by name with the given arguments.
    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        try function(named: name).evaluate(args)
    }

    /// Assert a CellValue equals a number within accuracy.
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

    func testAllContainsThirteenFunctions() {
        XCTAssertEqual(BuiltinStatsFunctions.all.count, 13)
    }

    // MARK: - AVERAGE

    func testAVERAGEBasic() throws {
        let result = try eval("AVERAGE", .number(10), .number(20), .number(30))
        assertNumber(result, 20)
    }

    func testAVERAGESingleValue() throws {
        let result = try eval("AVERAGE", .number(42))
        assertNumber(result, 42)
    }

    func testAVERAGEIgnoresBlanks() throws {
        let result = try eval("AVERAGE", .number(10), .blank, .number(20))
        assertNumber(result, 15)
    }

    func testAVERAGEIgnoresText() throws {
        let result = try eval("AVERAGE", .number(10), .text("hello"), .number(30))
        assertNumber(result, 20)
    }

    func testAVERAGENoNumbersReturnsDiv0() throws {
        let result = try eval("AVERAGE", .blank, .text("abc"))
        assertError(result, .div0)
    }

    func testAVERAGEWithArray() throws {
        let result = try eval("AVERAGE",
                              .array([.number(10), .number(20), .number(30)]))
        assertNumber(result, 20)
    }

    func testAVERAGEErrorPropagation() throws {
        let result = try eval("AVERAGE", .number(1), .error(.ref))
        assertError(result, .ref)
    }

    // MARK: - STDEV (sample)

    func testSTDEVBasic() throws {
        // Data: [2, 4, 4, 4, 5, 5, 7, 9], mean=5
        // sum_sq_dev=32, sample var=32/7, sample stdev=sqrt(32/7) ~ 2.138
        let expected = (32.0 / 7.0).squareRoot()
        let result = try eval("STDEV",
                              .number(2), .number(4), .number(4), .number(4),
                              .number(5), .number(5), .number(7), .number(9))
        assertNumber(result, expected, accuracy: 1e-10)
    }

    func testSTDEVNeedsAtLeastTwoValues() throws {
        let result = try eval("STDEV", .number(5))
        assertError(result, .div0)
    }

    func testSTDEVWithArray() throws {
        let expected = (32.0 / 7.0).squareRoot()
        let result = try eval("STDEV",
                              .array([.number(2), .number(4), .number(4), .number(4),
                                      .number(5), .number(5), .number(7), .number(9)]))
        assertNumber(result, expected, accuracy: 1e-10)
    }

    func testSTDEVErrorPropagation() throws {
        let result = try eval("STDEV", .number(1), .error(.value), .number(3))
        assertError(result, .value)
    }

    // MARK: - STDEVP (population)

    func testSTDEVPBasic() throws {
        // Data: [2, 4, 4, 4, 5, 5, 7, 9], mean=5
        // sum_sq_dev=32, pop var=32/8=4, pop stdev=sqrt(4)=2
        let result = try eval("STDEVP",
                              .number(2), .number(4), .number(4), .number(4),
                              .number(5), .number(5), .number(7), .number(9))
        assertNumber(result, 2.0, accuracy: 1e-10)
    }

    func testSTDEVPSingleValue() throws {
        // Population stdev of a single value is 0
        let result = try eval("STDEVP", .number(42))
        assertNumber(result, 0)
    }

    func testSTDEVPNoNumbersReturnsDiv0() throws {
        let result = try eval("STDEVP", .blank, .text("abc"))
        assertError(result, .div0)
    }

    // MARK: - MEDIAN

    func testMEDIANOddCount() throws {
        // [1, 3, 5] -> median = 3
        let result = try eval("MEDIAN", .number(1), .number(3), .number(5))
        assertNumber(result, 3)
    }

    func testMEDIANEvenCount() throws {
        // [1, 2, 3, 4] -> median = (2+3)/2 = 2.5
        let result = try eval("MEDIAN", .number(1), .number(2), .number(3), .number(4))
        assertNumber(result, 2.5)
    }

    func testMEDIANUnsortedInput() throws {
        // [5, 1, 3] -> sorted [1, 3, 5] -> median = 3
        let result = try eval("MEDIAN", .number(5), .number(1), .number(3))
        assertNumber(result, 3)
    }

    func testMEDIANSingleValue() throws {
        let result = try eval("MEDIAN", .number(7))
        assertNumber(result, 7)
    }

    func testMEDIANNoNumbersReturnsNum() throws {
        let result = try eval("MEDIAN", .blank, .text("abc"))
        assertError(result, .num)
    }

    func testMEDIANWithArray() throws {
        let result = try eval("MEDIAN",
                              .array([.number(5), .number(1), .number(3)]))
        assertNumber(result, 3)
    }

    func testMEDIANErrorPropagation() throws {
        let result = try eval("MEDIAN", .number(1), .error(.na), .number(3))
        assertError(result, .na)
    }

    // MARK: - MIN

    func testMINBasic() throws {
        let result = try eval("MIN", .number(5), .number(2), .number(8))
        assertNumber(result, 2)
    }

    func testMINIgnoresBlanks() throws {
        let result = try eval("MIN", .number(5), .blank, .number(2))
        assertNumber(result, 2)
    }

    func testMINIgnoresText() throws {
        let result = try eval("MIN", .number(5), .text("hello"), .number(2))
        assertNumber(result, 2)
    }

    func testMINWithArray() throws {
        let result = try eval("MIN",
                              .array([.number(5), .number(2), .number(8)]))
        assertNumber(result, 2)
    }

    func testMINNoNumbersReturnsZero() throws {
        // Excel MIN with no numeric args returns 0
        let result = try eval("MIN", .blank, .text("abc"))
        assertNumber(result, 0)
    }

    func testMINNegativeNumbers() throws {
        let result = try eval("MIN", .number(-5), .number(-2), .number(-8))
        assertNumber(result, -8)
    }

    func testMINErrorPropagation() throws {
        let result = try eval("MIN", .number(1), .error(.div0))
        assertError(result, .div0)
    }

    // MARK: - MAX

    func testMAXBasic() throws {
        let result = try eval("MAX", .number(5), .number(2), .number(8))
        assertNumber(result, 8)
    }

    func testMAXIgnoresBlanks() throws {
        let result = try eval("MAX", .number(5), .blank, .number(8))
        assertNumber(result, 8)
    }

    func testMAXWithArray() throws {
        let result = try eval("MAX",
                              .array([.number(5), .number(2), .number(8)]))
        assertNumber(result, 8)
    }

    func testMAXNoNumbersReturnsZero() throws {
        let result = try eval("MAX", .blank, .text("abc"))
        assertNumber(result, 0)
    }

    func testMAXErrorPropagation() throws {
        let result = try eval("MAX", .number(1), .error(.num))
        assertError(result, .num)
    }

    // MARK: - COUNT

    func testCOUNTBasic() throws {
        let result = try eval("COUNT", .number(1), .number(2), .number(3))
        assertNumber(result, 3)
    }

    func testCOUNTIgnoresText() throws {
        let result = try eval("COUNT", .number(1), .text("hello"), .number(3))
        assertNumber(result, 2)
    }

    func testCOUNTIgnoresBlanks() throws {
        let result = try eval("COUNT", .number(1), .blank, .number(3))
        assertNumber(result, 2)
    }

    func testCOUNTIgnoresErrors() throws {
        let result = try eval("COUNT", .number(1), .error(.value), .number(3))
        assertNumber(result, 2)
    }

    func testCOUNTIncludesBoolAsNumber() throws {
        // In Excel, COUNT counts booleans when passed directly (not from range)
        // But we follow the spec: only .number and .date count
        let result = try eval("COUNT", .number(1), .bool(true), .number(3))
        assertNumber(result, 2)
    }

    func testCOUNTWithArray() throws {
        let result = try eval("COUNT",
                              .array([.number(1), .text("hi"), .number(3), .blank]))
        assertNumber(result, 2)
    }

    func testCOUNTNoNumbers() throws {
        let result = try eval("COUNT", .blank, .text("abc"))
        assertNumber(result, 0)
    }

    // MARK: - COUNTA

    func testCOUNTABasic() throws {
        let result = try eval("COUNTA", .number(1), .text("hello"), .bool(true))
        assertNumber(result, 3)
    }

    func testCOUNTAIgnoresBlanks() throws {
        let result = try eval("COUNTA", .number(1), .blank, .text("hi"))
        assertNumber(result, 2)
    }

    func testCOUNTACountsErrors() throws {
        let result = try eval("COUNTA", .error(.value), .number(1))
        assertNumber(result, 2)
    }

    func testCOUNTAAllBlanks() throws {
        let result = try eval("COUNTA", .blank, .blank)
        assertNumber(result, 0)
    }

    func testCOUNTAWithArray() throws {
        let result = try eval("COUNTA",
                              .array([.number(1), .blank, .text("hi"), .error(.na)]))
        assertNumber(result, 3)
    }

    // MARK: - PERCENTILE

    func testPERCENTILEMin() throws {
        // k=0 returns the minimum
        let result = try eval("PERCENTILE",
                              .array([.number(1), .number(2), .number(3), .number(4)]),
                              .number(0))
        assertNumber(result, 1)
    }

    func testPERCENTILEMax() throws {
        // k=1 returns the maximum
        let result = try eval("PERCENTILE",
                              .array([.number(1), .number(2), .number(3), .number(4)]),
                              .number(1))
        assertNumber(result, 4)
    }

    func testPERCENTILEMedian() throws {
        // k=0.5 returns the median
        let result = try eval("PERCENTILE",
                              .array([.number(1), .number(2), .number(3), .number(4)]),
                              .number(0.5))
        assertNumber(result, 2.5)
    }

    func testPERCENTILEInterpolation() throws {
        // Data: [1, 3, 5, 7], k=0.25
        // rank = 0.25 * (4-1) = 0.75
        // intPart = 0, fracPart = 0.75
        // result = sorted[0] + 0.75 * (sorted[1] - sorted[0]) = 1 + 0.75 * 2 = 2.5
        let result = try eval("PERCENTILE",
                              .array([.number(1), .number(3), .number(5), .number(7)]),
                              .number(0.25))
        assertNumber(result, 2.5)
    }

    func testPERCENTILEKOutOfRange() throws {
        let result = try eval("PERCENTILE",
                              .array([.number(1), .number(2)]),
                              .number(1.5))
        assertError(result, .num)
    }

    func testPERCENTILEKNegative() throws {
        let result = try eval("PERCENTILE",
                              .array([.number(1), .number(2)]),
                              .number(-0.1))
        assertError(result, .num)
    }

    func testPERCENTILEEmptyArray() throws {
        let result = try eval("PERCENTILE",
                              .array([.blank, .text("abc")]),
                              .number(0.5))
        assertError(result, .num)
    }

    func testPERCENTILEErrorPropagation() throws {
        let result = try eval("PERCENTILE",
                              .array([.number(1), .error(.ref)]),
                              .number(0.5))
        assertError(result, .ref)
    }

    // MARK: - LARGE

    func testLARGEFirst() throws {
        // k=1 returns the largest
        let result = try eval("LARGE",
                              .array([.number(3), .number(1), .number(5), .number(2)]),
                              .number(1))
        assertNumber(result, 5)
    }

    func testLARGESecond() throws {
        // k=2 returns the second largest
        let result = try eval("LARGE",
                              .array([.number(3), .number(1), .number(5), .number(2)]),
                              .number(2))
        assertNumber(result, 3)
    }

    func testLARGELast() throws {
        // k=n returns the smallest
        let result = try eval("LARGE",
                              .array([.number(3), .number(1), .number(5), .number(2)]),
                              .number(4))
        assertNumber(result, 1)
    }

    func testLARGEKOutOfRange() throws {
        let result = try eval("LARGE",
                              .array([.number(1), .number(2)]),
                              .number(3))
        assertError(result, .num)
    }

    func testLARGEKZero() throws {
        let result = try eval("LARGE",
                              .array([.number(1), .number(2)]),
                              .number(0))
        assertError(result, .num)
    }

    func testLARGEErrorPropagation() throws {
        let result = try eval("LARGE",
                              .array([.number(1), .error(.div0)]),
                              .number(1))
        assertError(result, .div0)
    }

    // MARK: - SMALL

    func testSMALLFirst() throws {
        // k=1 returns the smallest
        let result = try eval("SMALL",
                              .array([.number(3), .number(1), .number(5), .number(2)]),
                              .number(1))
        assertNumber(result, 1)
    }

    func testSMALLSecond() throws {
        // k=2 returns the second smallest
        let result = try eval("SMALL",
                              .array([.number(3), .number(1), .number(5), .number(2)]),
                              .number(2))
        assertNumber(result, 2)
    }

    func testSMALLLast() throws {
        // k=n returns the largest
        let result = try eval("SMALL",
                              .array([.number(3), .number(1), .number(5), .number(2)]),
                              .number(4))
        assertNumber(result, 5)
    }

    func testSMALLKOutOfRange() throws {
        let result = try eval("SMALL",
                              .array([.number(1), .number(2)]),
                              .number(3))
        assertError(result, .num)
    }

    func testSMALLKZero() throws {
        let result = try eval("SMALL",
                              .array([.number(1), .number(2)]),
                              .number(0))
        assertError(result, .num)
    }

    func testSMALLErrorPropagation() throws {
        let result = try eval("SMALL",
                              .array([.error(.na), .number(2)]),
                              .number(1))
        assertError(result, .na)
    }

    // MARK: - VAR (sample variance)

    func testVARBasic() throws {
        // [2, 4, 4, 4, 5, 5, 7, 9], mean=5, sum_sq_dev=32, sample var=32/7
        let expected = 32.0 / 7.0
        let result = try eval("VAR",
                              .number(2), .number(4), .number(4), .number(4),
                              .number(5), .number(5), .number(7), .number(9))
        assertNumber(result, expected, accuracy: 1e-10)
    }

    func testVARNeedsAtLeastTwoValues() throws {
        let result = try eval("VAR", .number(5))
        assertError(result, .div0)
    }

    func testVARWithArray() throws {
        let expected = 32.0 / 7.0
        let result = try eval("VAR",
                              .array([.number(2), .number(4), .number(4), .number(4),
                                      .number(5), .number(5), .number(7), .number(9)]))
        assertNumber(result, expected, accuracy: 1e-10)
    }

    func testVARErrorPropagation() throws {
        let result = try eval("VAR", .number(1), .error(.null), .number(3))
        assertError(result, .null)
    }

    // MARK: - VARP (population variance)

    func testVARPBasic() throws {
        // [2, 4, 4, 4, 5, 5, 7, 9], mean=5, sum_sq_dev=32, pop var=32/8=4
        let result = try eval("VARP",
                              .number(2), .number(4), .number(4), .number(4),
                              .number(5), .number(5), .number(7), .number(9))
        assertNumber(result, 4.0, accuracy: 1e-10)
    }

    func testVARPSingleValue() throws {
        // Population variance of a single value is 0
        let result = try eval("VARP", .number(42))
        assertNumber(result, 0)
    }

    func testVARPNoNumbersReturnsDiv0() throws {
        let result = try eval("VARP", .blank, .text("abc"))
        assertError(result, .div0)
    }

    func testVARPErrorPropagation() throws {
        let result = try eval("VARP", .number(1), .error(.name), .number(3))
        assertError(result, .name)
    }

    // MARK: - Array flattening

    func testAVERAGENestedArrays() throws {
        // Nested arrays should be flattened
        let result = try eval("AVERAGE",
                              .array([.number(10), .array([.number(20), .number(30)])]))
        assertNumber(result, 20)
    }

    func testMINMixedArrayAndScalar() throws {
        let result = try eval("MIN",
                              .number(5), .array([.number(3), .number(7)]))
        assertNumber(result, 3)
    }

    func testMAXMixedArrayAndScalar() throws {
        let result = try eval("MAX",
                              .number(5), .array([.number(3), .number(7)]))
        assertNumber(result, 7)
    }

    // MARK: - ExcelFunction metadata

    func testAVERAGEMetadata() {
        let fn = function(named: "AVERAGE")
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertNil(fn.maxArgs)
    }

    func testSTDEVMetadata() {
        let fn = function(named: "STDEV")
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertNil(fn.maxArgs)
    }

    func testPERCENTILEMetadata() {
        let fn = function(named: "PERCENTILE")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 2)
    }

    func testLARGEMetadata() {
        let fn = function(named: "LARGE")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 2)
    }

    func testSMALLMetadata() {
        let fn = function(named: "SMALL")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 2)
    }

    func testCOUNTMetadata() {
        let fn = function(named: "COUNT")
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertNil(fn.maxArgs)
    }

    func testCOUNTAMetadata() {
        let fn = function(named: "COUNTA")
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertNil(fn.maxArgs)
    }

    // MARK: - Bool handling in direct arguments

    func testAVERAGEBoolDirectly() throws {
        // Bools passed directly as arguments are treated as 1/0
        let result = try eval("AVERAGE", .bool(true), .bool(false))
        assertNumber(result, 0.5)
    }

    func testMINBoolDirectly() throws {
        let result = try eval("MIN", .number(5), .bool(true))
        assertNumber(result, 1)
    }

    func testMAXBoolDirectly() throws {
        let result = try eval("MAX", .number(0), .bool(true))
        assertNumber(result, 1)
    }
}
