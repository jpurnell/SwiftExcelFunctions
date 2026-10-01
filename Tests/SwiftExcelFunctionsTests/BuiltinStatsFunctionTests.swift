import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

@Suite struct BuiltinStatsFunctionTests {

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



    // MARK: - Registration count

    @Test func allContainsThirteenFunctions() {
        #expect(BuiltinStatsFunctions.all.count == 13)
    }

    // MARK: - AVERAGE

    @Test func averageBasic() throws {
        let result = try eval("AVERAGE", .number(10), .number(20), .number(30))
        #expect(result.isNumber(20))
    }

    @Test func averageSingleValue() throws {
        let result = try eval("AVERAGE", .number(42))
        #expect(result.isNumber(42))
    }

    @Test func averageIgnoresBlanks() throws {
        let result = try eval("AVERAGE", .number(10), .blank, .number(20))
        #expect(result.isNumber(15))
    }

    @Test func averageIgnoresText() throws {
        let result = try eval("AVERAGE", .number(10), .text("hello"), .number(30))
        #expect(result.isNumber(20))
    }

    @Test func averageNoNumbersReturnsDiv0() throws {
        let result = try eval("AVERAGE", .blank, .text("abc"))
        #expect(result == .error(.div0))
    }

    @Test func averageWithArray() throws {
        let result = try eval("AVERAGE",
                              .array(CellMatrix(row: [.number(10), .number(20), .number(30)])))
        #expect(result.isNumber(20))
    }

    @Test func averageErrorPropagation() throws {
        let result = try eval("AVERAGE", .number(1), .error(.ref))
        #expect(result == .error(.ref))
    }

    // MARK: - STDEV (sample)

    @Test func stdevBasic() throws {
        // Data: [2, 4, 4, 4, 5, 5, 7, 9], mean=5
        // sum_sq_dev=32, sample var=32/7, sample stdev=sqrt(32/7) ~ 2.138
        let expected = (32.0 / 7.0).squareRoot()
        let result = try eval("STDEV",
                              .number(2), .number(4), .number(4), .number(4),
                              .number(5), .number(5), .number(7), .number(9))
        #expect(result.isNumber(expected, within: 1e-10))
    }

    @Test func stdevNeedsAtLeastTwoValues() throws {
        let result = try eval("STDEV", .number(5))
        #expect(result == .error(.div0))
    }

    @Test func stdevWithArray() throws {
        let expected = (32.0 / 7.0).squareRoot()
        let result = try eval("STDEV",
                              .array(CellMatrix(row: [.number(2), .number(4), .number(4), .number(4),
                                      .number(5), .number(5), .number(7), .number(9)])))
        #expect(result.isNumber(expected, within: 1e-10))
    }

    @Test func stdevErrorPropagation() throws {
        let result = try eval("STDEV", .number(1), .error(.value), .number(3))
        #expect(result == .error(.value))
    }

    // MARK: - STDEVP (population)

    @Test func stdevpBasic() throws {
        // Data: [2, 4, 4, 4, 5, 5, 7, 9], mean=5
        // sum_sq_dev=32, pop var=32/8=4, pop stdev=sqrt(4)=2
        let result = try eval("STDEVP",
                              .number(2), .number(4), .number(4), .number(4),
                              .number(5), .number(5), .number(7), .number(9))
        #expect(result.isNumber(2.0, within: 1e-10))
    }

    @Test func stdevpSingleValue() throws {
        // Population stdev of a single value is 0
        let result = try eval("STDEVP", .number(42))
        #expect(result.isNumber(0))
    }

    @Test func stdevpNoNumbersReturnsDiv0() throws {
        let result = try eval("STDEVP", .blank, .text("abc"))
        #expect(result == .error(.div0))
    }

    // MARK: - MEDIAN

    @Test func medianOddCount() throws {
        // [1, 3, 5] -> median = 3
        let result = try eval("MEDIAN", .number(1), .number(3), .number(5))
        #expect(result.isNumber(3))
    }

    @Test func medianEvenCount() throws {
        // [1, 2, 3, 4] -> median = (2+3)/2 = 2.5
        let result = try eval("MEDIAN", .number(1), .number(2), .number(3), .number(4))
        #expect(result.isNumber(2.5))
    }

    @Test func medianUnsortedInput() throws {
        // [5, 1, 3] -> sorted [1, 3, 5] -> median = 3
        let result = try eval("MEDIAN", .number(5), .number(1), .number(3))
        #expect(result.isNumber(3))
    }

    @Test func medianSingleValue() throws {
        let result = try eval("MEDIAN", .number(7))
        #expect(result.isNumber(7))
    }

    @Test func medianNoNumbersReturnsNum() throws {
        let result = try eval("MEDIAN", .blank, .text("abc"))
        #expect(result == .error(.num))
    }

    @Test func medianWithArray() throws {
        let result = try eval("MEDIAN",
                              .array(CellMatrix(row: [.number(5), .number(1), .number(3)])))
        #expect(result.isNumber(3))
    }

    @Test func medianErrorPropagation() throws {
        let result = try eval("MEDIAN", .number(1), .error(.na), .number(3))
        #expect(result == .error(.na))
    }

    // MARK: - MIN

    @Test func minBasic() throws {
        let result = try eval("MIN", .number(5), .number(2), .number(8))
        #expect(result.isNumber(2))
    }

    @Test func minIgnoresBlanks() throws {
        let result = try eval("MIN", .number(5), .blank, .number(2))
        #expect(result.isNumber(2))
    }

    @Test func minIgnoresText() throws {
        let result = try eval("MIN", .number(5), .text("hello"), .number(2))
        #expect(result.isNumber(2))
    }

    @Test func minWithArray() throws {
        let result = try eval("MIN",
                              .array(CellMatrix(row: [.number(5), .number(2), .number(8)])))
        #expect(result.isNumber(2))
    }

    @Test func minNoNumbersReturnsZero() throws {
        // Excel MIN with no numeric args returns 0
        let result = try eval("MIN", .blank, .text("abc"))
        #expect(result.isNumber(0))
    }

    @Test func minNegativeNumbers() throws {
        let result = try eval("MIN", .number(-5), .number(-2), .number(-8))
        #expect(result.isNumber(-8))
    }

    @Test func minErrorPropagation() throws {
        let result = try eval("MIN", .number(1), .error(.div0))
        #expect(result == .error(.div0))
    }

    // MARK: - MAX

    @Test func maxBasic() throws {
        let result = try eval("MAX", .number(5), .number(2), .number(8))
        #expect(result.isNumber(8))
    }

    @Test func maxIgnoresBlanks() throws {
        let result = try eval("MAX", .number(5), .blank, .number(8))
        #expect(result.isNumber(8))
    }

    @Test func maxWithArray() throws {
        let result = try eval("MAX",
                              .array(CellMatrix(row: [.number(5), .number(2), .number(8)])))
        #expect(result.isNumber(8))
    }

    @Test func maxNoNumbersReturnsZero() throws {
        let result = try eval("MAX", .blank, .text("abc"))
        #expect(result.isNumber(0))
    }

    @Test func maxErrorPropagation() throws {
        let result = try eval("MAX", .number(1), .error(.num))
        #expect(result == .error(.num))
    }

    // MARK: - COUNT

    @Test func countBasic() throws {
        let result = try eval("COUNT", .number(1), .number(2), .number(3))
        #expect(result.isNumber(3))
    }

    @Test func countIgnoresText() throws {
        let result = try eval("COUNT", .number(1), .text("hello"), .number(3))
        #expect(result.isNumber(2))
    }

    @Test func countIgnoresBlanks() throws {
        let result = try eval("COUNT", .number(1), .blank, .number(3))
        #expect(result.isNumber(2))
    }

    @Test func countIgnoresErrors() throws {
        let result = try eval("COUNT", .number(1), .error(.value), .number(3))
        #expect(result.isNumber(2))
    }

    @Test func countIncludesBoolAsNumber() throws {
        // In Excel, COUNT counts booleans when passed directly (not from range)
        // But we follow the spec: only .number and .date count
        let result = try eval("COUNT", .number(1), .bool(true), .number(3))
        #expect(result.isNumber(2))
    }

    @Test func countWithArray() throws {
        let result = try eval("COUNT",
                              .array(CellMatrix(row: [.number(1), .text("hi"), .number(3), .blank])))
        #expect(result.isNumber(2))
    }

    @Test func countNoNumbers() throws {
        let result = try eval("COUNT", .blank, .text("abc"))
        #expect(result.isNumber(0))
    }

    // MARK: - COUNTA

    @Test func countaBasic() throws {
        let result = try eval("COUNTA", .number(1), .text("hello"), .bool(true))
        #expect(result.isNumber(3))
    }

    @Test func countaIgnoresBlanks() throws {
        let result = try eval("COUNTA", .number(1), .blank, .text("hi"))
        #expect(result.isNumber(2))
    }

    @Test func countaCountsErrors() throws {
        let result = try eval("COUNTA", .error(.value), .number(1))
        #expect(result.isNumber(2))
    }

    @Test func countaAllBlanks() throws {
        let result = try eval("COUNTA", .blank, .blank)
        #expect(result.isNumber(0))
    }

    @Test func countaWithArray() throws {
        let result = try eval("COUNTA",
                              .array(CellMatrix(row: [.number(1), .blank, .text("hi"), .error(.na)])))
        #expect(result.isNumber(3))
    }

    // MARK: - PERCENTILE

    @Test func percentileMin() throws {
        // k=0 returns the minimum
        let result = try eval("PERCENTILE",
                              .array(CellMatrix(row: [.number(1), .number(2), .number(3), .number(4)])),
                              .number(0))
        #expect(result.isNumber(1))
    }

    @Test func percentileMax() throws {
        // k=1 returns the maximum
        let result = try eval("PERCENTILE",
                              .array(CellMatrix(row: [.number(1), .number(2), .number(3), .number(4)])),
                              .number(1))
        #expect(result.isNumber(4))
    }

    @Test func percentileMedian() throws {
        // k=0.5 returns the median
        let result = try eval("PERCENTILE",
                              .array(CellMatrix(row: [.number(1), .number(2), .number(3), .number(4)])),
                              .number(0.5))
        #expect(result.isNumber(2.5))
    }

    @Test func percentileInterpolation() throws {
        // Data: [1, 3, 5, 7], k=0.25
        // rank = 0.25 * (4-1) = 0.75
        // intPart = 0, fracPart = 0.75
        // result = sorted[0] + 0.75 * (sorted[1] - sorted[0]) = 1 + 0.75 * 2 = 2.5
        let result = try eval("PERCENTILE",
                              .array(CellMatrix(row: [.number(1), .number(3), .number(5), .number(7)])),
                              .number(0.25))
        #expect(result.isNumber(2.5))
    }

    @Test func percentilekOutOfRange() throws {
        let result = try eval("PERCENTILE",
                              .array(CellMatrix(row: [.number(1), .number(2)])),
                              .number(1.5))
        #expect(result == .error(.num))
    }

    @Test func percentilekNegative() throws {
        let result = try eval("PERCENTILE",
                              .array(CellMatrix(row: [.number(1), .number(2)])),
                              .number(-0.1))
        #expect(result == .error(.num))
    }

    @Test func percentileEmptyArray() throws {
        let result = try eval("PERCENTILE",
                              .array(CellMatrix(row: [.blank, .text("abc")])),
                              .number(0.5))
        #expect(result == .error(.num))
    }

    @Test func percentileErrorPropagation() throws {
        let result = try eval("PERCENTILE",
                              .array(CellMatrix(row: [.number(1), .error(.ref)])),
                              .number(0.5))
        #expect(result == .error(.ref))
    }

    // MARK: - LARGE

    @Test func largeFirst() throws {
        // k=1 returns the largest
        let result = try eval("LARGE",
                              .array(CellMatrix(row: [.number(3), .number(1), .number(5), .number(2)])),
                              .number(1))
        #expect(result.isNumber(5))
    }

    @Test func largeSecond() throws {
        // k=2 returns the second largest
        let result = try eval("LARGE",
                              .array(CellMatrix(row: [.number(3), .number(1), .number(5), .number(2)])),
                              .number(2))
        #expect(result.isNumber(3))
    }

    @Test func largeLast() throws {
        // k=n returns the smallest
        let result = try eval("LARGE",
                              .array(CellMatrix(row: [.number(3), .number(1), .number(5), .number(2)])),
                              .number(4))
        #expect(result.isNumber(1))
    }

    @Test func largekOutOfRange() throws {
        let result = try eval("LARGE",
                              .array(CellMatrix(row: [.number(1), .number(2)])),
                              .number(3))
        #expect(result == .error(.num))
    }

    @Test func largekZero() throws {
        let result = try eval("LARGE",
                              .array(CellMatrix(row: [.number(1), .number(2)])),
                              .number(0))
        #expect(result == .error(.num))
    }

    @Test func largeErrorPropagation() throws {
        let result = try eval("LARGE",
                              .array(CellMatrix(row: [.number(1), .error(.div0)])),
                              .number(1))
        #expect(result == .error(.div0))
    }

    // MARK: - SMALL

    @Test func smallFirst() throws {
        // k=1 returns the smallest
        let result = try eval("SMALL",
                              .array(CellMatrix(row: [.number(3), .number(1), .number(5), .number(2)])),
                              .number(1))
        #expect(result.isNumber(1))
    }

    @Test func smallSecond() throws {
        // k=2 returns the second smallest
        let result = try eval("SMALL",
                              .array(CellMatrix(row: [.number(3), .number(1), .number(5), .number(2)])),
                              .number(2))
        #expect(result.isNumber(2))
    }

    @Test func smallLast() throws {
        // k=n returns the largest
        let result = try eval("SMALL",
                              .array(CellMatrix(row: [.number(3), .number(1), .number(5), .number(2)])),
                              .number(4))
        #expect(result.isNumber(5))
    }

    @Test func smallkOutOfRange() throws {
        let result = try eval("SMALL",
                              .array(CellMatrix(row: [.number(1), .number(2)])),
                              .number(3))
        #expect(result == .error(.num))
    }

    @Test func smallkZero() throws {
        let result = try eval("SMALL",
                              .array(CellMatrix(row: [.number(1), .number(2)])),
                              .number(0))
        #expect(result == .error(.num))
    }

    @Test func smallErrorPropagation() throws {
        let result = try eval("SMALL",
                              .array(CellMatrix(row: [.error(.na), .number(2)])),
                              .number(1))
        #expect(result == .error(.na))
    }

    // MARK: - VAR (sample variance)

    @Test func varBasic() throws {
        // [2, 4, 4, 4, 5, 5, 7, 9], mean=5, sum_sq_dev=32, sample var=32/7
        let expected = 32.0 / 7.0
        let result = try eval("VAR",
                              .number(2), .number(4), .number(4), .number(4),
                              .number(5), .number(5), .number(7), .number(9))
        #expect(result.isNumber(expected, within: 1e-10))
    }

    @Test func varNeedsAtLeastTwoValues() throws {
        let result = try eval("VAR", .number(5))
        #expect(result == .error(.div0))
    }

    @Test func varWithArray() throws {
        let expected = 32.0 / 7.0
        let result = try eval("VAR",
                              .array(CellMatrix(row: [.number(2), .number(4), .number(4), .number(4),
                                      .number(5), .number(5), .number(7), .number(9)])))
        #expect(result.isNumber(expected, within: 1e-10))
    }

    @Test func varErrorPropagation() throws {
        let result = try eval("VAR", .number(1), .error(.null), .number(3))
        #expect(result == .error(.null))
    }

    // MARK: - VARP (population variance)

    @Test func varpBasic() throws {
        // [2, 4, 4, 4, 5, 5, 7, 9], mean=5, sum_sq_dev=32, pop var=32/8=4
        let result = try eval("VARP",
                              .number(2), .number(4), .number(4), .number(4),
                              .number(5), .number(5), .number(7), .number(9))
        #expect(result.isNumber(4.0, within: 1e-10))
    }

    @Test func varpSingleValue() throws {
        // Population variance of a single value is 0
        let result = try eval("VARP", .number(42))
        #expect(result.isNumber(0))
    }

    @Test func varpNoNumbersReturnsDiv0() throws {
        let result = try eval("VARP", .blank, .text("abc"))
        #expect(result == .error(.div0))
    }

    @Test func varpErrorPropagation() throws {
        let result = try eval("VARP", .number(1), .error(.name), .number(3))
        #expect(result == .error(.name))
    }

    // MARK: - Array flattening

    @Test func averageNestedArrays() throws {
        // Nested arrays should be flattened
        let result = try eval("AVERAGE",
                              .array(CellMatrix(row: [
                                  .number(10),
                                  .array(CellMatrix(row: [.number(20), .number(30)])),
                              ])))
        #expect(result.isNumber(20))
    }

    @Test func minMixedArrayAndScalar() throws {
        let result = try eval("MIN",
                              .number(5), .array(CellMatrix(row: [.number(3), .number(7)])))
        #expect(result.isNumber(3))
    }

    @Test func maxMixedArrayAndScalar() throws {
        let result = try eval("MAX",
                              .number(5), .array(CellMatrix(row: [.number(3), .number(7)])))
        #expect(result.isNumber(7))
    }

    // MARK: - ExcelFunction metadata

    @Test func averageMetadata() {
        let fn = function(named: "AVERAGE")
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == nil)
    }

    @Test func stdevMetadata() {
        let fn = function(named: "STDEV")
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == nil)
    }

    @Test func percentileMetadata() {
        let fn = function(named: "PERCENTILE")
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == 2)
    }

    @Test func largeMetadata() {
        let fn = function(named: "LARGE")
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == 2)
    }

    @Test func smallMetadata() {
        let fn = function(named: "SMALL")
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == 2)
    }

    @Test func countMetadata() {
        let fn = function(named: "COUNT")
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == nil)
    }

    @Test func countaMetadata() {
        let fn = function(named: "COUNTA")
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == nil)
    }

    // MARK: - Bool handling in direct arguments

    @Test func averageBoolDirectly() throws {
        // Bools passed directly as arguments are treated as 1/0
        let result = try eval("AVERAGE", .bool(true), .bool(false))
        #expect(result.isNumber(0.5))
    }

    @Test func minBoolDirectly() throws {
        let result = try eval("MIN", .number(5), .bool(true))
        #expect(result.isNumber(1))
    }

    @Test func maxBoolDirectly() throws {
        let result = try eval("MAX", .number(0), .bool(true))
        #expect(result.isNumber(1))
    }
}
