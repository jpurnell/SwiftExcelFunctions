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
            ["SUM", "SUMIF", "SUMIFS", "COUNTIF", "COUNTIFS", "AVERAGEIF", "AVERAGEIFS",
             "SUMPRODUCT", "SUMSQ"])
    }

    // MARK: - SUM

    func testSUMBasic() throws {
        let result = try eval("SUM", .number(1), .number(2), .number(3))
        assertNumber(result, 6)
    }

    func testSUMWithArray() throws {
        let result = try eval("SUM", .array(CellMatrix(row: [.number(1), .number(2), .number(3)])))
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
            .array(CellMatrix(row: [.number(1), .number(2)])),
            .number(3),
            .array(CellMatrix(row: [.number(4)]))
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
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(5), .number(10), .number(15)]))
        let result = try eval("SUMIF", range, .text(">5"))
        assertNumber(result, 25) // 10 + 15
    }

    func testSUMIFEquals() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(1), .number(3)]))
        let result = try eval("SUMIF", range, .text("1"))
        assertNumber(result, 2) // 1 + 1
    }

    func testSUMIFNotEqual() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(0), .number(5), .number(0), .number(10)]))
        let result = try eval("SUMIF", range, .text("<>0"))
        assertNumber(result, 15) // 5 + 10
    }

    func testSUMIFWithSumRange() throws {
        let criteriaRange: CellValue = .array(CellMatrix(row: [.text("A"), .text("B"), .text("A"), .text("C")]))
        let sumRange: CellValue = .array(CellMatrix(row: [.number(10), .number(20), .number(30), .number(40)]))
        let result = try eval("SUMIF", criteriaRange, .text("A"), sumRange)
        assertNumber(result, 40) // 10 + 30
    }

    func testSUMIFGreaterOrEqual() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(5), .number(10)]))
        let result = try eval("SUMIF", range, .text(">=5"))
        assertNumber(result, 15) // 5 + 10
    }

    func testSUMIFLessThan() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(5), .number(10)]))
        let result = try eval("SUMIF", range, .text("<5"))
        assertNumber(result, 1)
    }

    func testSUMIFNoMatch() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3)]))
        let result = try eval("SUMIF", range, .text(">100"))
        assertNumber(result, 0)
    }

    // MARK: - SUMIFS

    func testSUMIFSMultipleCriteria() throws {
        let sumRange: CellValue = .array(CellMatrix(row: [.number(10), .number(20), .number(30), .number(40)]))
        let criteria1Range: CellValue = .array(CellMatrix(row: [.text("A"), .text("B"), .text("A"), .text("B")]))
        let criteria2Range: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3), .number(4)]))
        let result = try eval("SUMIFS",
            sumRange,
            criteria1Range, .text("A"),
            criteria2Range, .text(">1")
        )
        assertNumber(result, 30) // Only index 2 matches (A and 3 > 1)
    }

    /// An argument that is *itself* an error poisons the call.
    ///
    /// `SUMIFS(#REF!, …)` is `#REF!`. This returned `0` — `toArray` was reached without
    /// anything having looked at the arguments, and an error flattened to no values at all,
    /// which sums to nothing.
    ///
    /// Found by the corpus oracle in **202 cells** of one Excel-written workbook, every one
    /// spelling `IF(SUMIFS(#REF!, 'Daily'!A1:XFD1, …)=0, "", …)`. A broken reference inside
    /// the model therefore read as "the total is zero", and the `IF` returned the empty
    /// string — a wrong answer wearing the same clothes as a legitimately empty cell, which
    /// is why nobody saw it.
    ///
    /// This is about an **argument** that is an error, not about error *cells inside a range*
    /// — Excel treats those differently function by function, and that is a separate question.
    // MARK: - Criteria semantics, measured in round fifteen

    /// An error **as the criteria** does not propagate — it matches nothing.
    ///
    /// **This corrects an over-generalisation of mine.** An earlier fix propagated an error
    /// from *any* argument position after measuring only the **sum-range** position, and 672
    /// corpus cells reading `SUMIF($G$8:$G$250, #REF!, K$8:K$250)` disagreed with Excel ever
    /// since: Excel answers `0`, this package answered `#REF!`.
    ///
    /// Round fourteen had already measured that an error *cell inside* the criteria range
    /// propagates nothing, which pointed the same way without settling it — a cell in a range
    /// and the whole criteria are different things. Round fifteen asked directly.
    func testAnErrorAsTheCriteriaMatchesNothing() throws {
        let keys: CellValue = .array(CellMatrix(row: [.text("x"), .text("y"), .text("x")]))
        let values: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3)]))

        assertNumber(try eval("SUMIF", keys, .error(.ref), values), 0)
        assertNumber(try eval("SUMIFS", values, keys, .error(.ref)), 0)
    }

    /// A **blank** criteria matches nothing either — not blanks, and not zero.
    ///
    /// Measured in round fifteen over a range that *contains* a blank, which is the case that
    /// could have gone either way. Excel answers `0` for all four spellings; this package
    /// matched the blank and answered `2`, or counted it and answered `1`.
    func testABlankCriteriaMatchesNothing() throws {
        let keys: CellValue = .array(CellMatrix(row: [.text("x"), .blank, .text("x")]))
        let values: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3)]))

        assertNumber(try eval("SUMIF", keys, .blank, values), 0, accuracy: 0)
        assertNumber(try eval("SUMIFS", values, keys, .blank), 0, accuracy: 0)
        assertNumber(try eval("COUNTIF", keys, .blank), 0, accuracy: 0)
        assertNumber(try eval("COUNTIFS", keys, .blank), 0, accuracy: 0)
    }

    /// `SUMIF` stretches a short `sum_range`; `SUMIFS` refuses one.
    ///
    /// **This is what makes them two functions rather than one with its arguments moved.**
    /// Given three keys and a one-cell sum range, Excel answers **4** for `SUMIF` — the range
    /// is extended to the criteria range's shape, taking the two rows keyed `x` — and
    /// **`#VALUE!`** for `SUMIFS`, whose ranges must match. This package answered `0` to both,
    /// stretching neither and refusing neither.
    ///
    /// Every rule measured for one of these now has to be measured for the other. Round
    /// fourteen's selective error propagation held for both; this does not.
    func testSUMIFStretchesAShortSumRangeAndSUMIFSRefusesOne() throws {
        let keys: CellValue = .array(CellMatrix(row: [.text("x"), .text("y"), .text("x")]))
        let oneCell: CellValue = .number(1)

        XCTAssertEqual(try eval("SUMIFS", oneCell, keys, .text("x")), .error(.value),
                       "SUMIFS requires the shapes to match")

        // `SUMIF`'s half is asserted through the evaluator rather than here: stretching needs
        // the **reference**, and an `ExcelFunction` is handed values, so a one-cell sum range
        // has no address by the time this code runs. See
        // `SumRangeStretchTests.testSUMIFStretchesAShortSumRange`.
    }

    // MARK: - An error cell inside a range, measured in round fourteen

    /// An error in a **selected** row poisons the call; one in a row the criteria skips does
    /// not.
    ///
    /// **Measured, and not what blanket propagation would give.** Round fourteen asked with
    /// real cells — `SUMIF` takes a range, so the question cannot be built from array
    /// constants — and separated the two cases a single corpus row could not:
    ///
    /// | data | Excel |
    /// |---|---|
    /// | error in a matching row | `#REF!` |
    /// | error in a non-matching row | 4 |
    /// | error in the criteria range | 4 |
    ///
    /// The corpus found this as 12,960 cells across four workbooks reading
    /// `SUMIF($EU$12:$EU$178, $B223, AO$12:AO$178)`, where `AO12` holds a literal `#REF!`.
    /// It could not say *which* rule was at work, because there the error row happened to
    /// match — and assuming the blanket rule from that would have been wrong twice over.
    ///
    /// This is a separate question from an error passed as an *argument*, which propagates
    /// whatever it selects.
    func testSUMIFPropagatesAnErrorOnlyFromASelectedRow() throws {
        let keys: CellValue = .array(CellMatrix(row: [.text("x"), .text("y"), .text("x")]))

        let matching: CellValue = .array(CellMatrix(row: [.error(.ref), .number(2), .number(3)]))
        XCTAssertEqual(try eval("SUMIF", keys, .text("x"), matching), .error(.ref),
                       "the error sits in a row the criteria selects")

        let skipped: CellValue = .array(CellMatrix(row: [.number(1), .error(.ref), .number(3)]))
        // The error sits in the row keyed y, which is not summed.
        assertNumber(try eval("SUMIF", keys, .text("x"), skipped), 4)

        let inCriteria: CellValue = .array(CellMatrix(row: [.text("x"), .error(.ref), .text("x")]))
        let values: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3)]))
        // An error in the criteria range matches nothing, and poisons nothing.
        assertNumber(try eval("SUMIF", inCriteria, .text("x"), values), 4)
    }

    /// `SUMIFS` follows the same rule, which it need not have.
    func testSUMIFSPropagatesAnErrorOnlyFromASelectedRow() throws {
        let keys: CellValue = .array(CellMatrix(row: [.text("x"), .text("y"), .text("x")]))

        let matching: CellValue = .array(CellMatrix(row: [.error(.ref), .number(2), .number(3)]))
        XCTAssertEqual(try eval("SUMIFS", matching, keys, .text("x")), .error(.ref))

        let skipped: CellValue = .array(CellMatrix(row: [.number(1), .error(.ref), .number(3)]))
        assertNumber(try eval("SUMIFS", skipped, keys, .text("x")), 4)
    }

    /// And `AVERAGEIF`, which was asked because it need not have agreed either.
    func testAVERAGEIFPropagatesAnErrorFromASelectedRow() throws {
        let keys: CellValue = .array(CellMatrix(row: [.text("x"), .text("y"), .text("x")]))
        let matching: CellValue = .array(CellMatrix(row: [.error(.ref), .number(2), .number(3)]))
        XCTAssertEqual(try eval("AVERAGEIF", keys, .text("x"), matching), .error(.ref))
    }

    /// `COUNTIF` counts around an error rather than propagating it — measured, and the
    /// control that says the rule above is about summing rather than about ranges.
    func testCOUNTIFCountsAroundAnError() throws {
        let inCriteria: CellValue = .array(CellMatrix(row: [.text("x"), .error(.ref), .text("x")]))
        assertNumber(try eval("COUNTIF", inCriteria, .text("x")), 2)

        let numbers: CellValue = .array(CellMatrix(row: [.number(1), .error(.ref), .number(3)]))
        assertNumber(try eval("COUNTIF", numbers, .text(">1")), 1)
    }

    func testSUMIFSPropagatesAnErrorArgument() throws {
        let criteriaRange: CellValue = .array(CellMatrix(row: [.text("A"), .text("B")]))
        let result = try eval("SUMIFS", .error(.ref), criteriaRange, .text("A"))
        XCTAssertEqual(result, .error(.ref),
                       "a broken reference is not an empty sum")
    }

    func testSUMIFSSingleCriteria() throws {
        let sumRange: CellValue = .array(CellMatrix(row: [.number(10), .number(20), .number(30)]))
        let criteriaRange: CellValue = .array(CellMatrix(row: [.text("A"), .text("B"), .text("A")]))
        let result = try eval("SUMIFS", sumRange, criteriaRange, .text("A"))
        assertNumber(result, 40) // 10 + 30
    }

    // MARK: - COUNTIF

    func testCOUNTIFEquals() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(1), .number(3), .number(1)]))
        let result = try eval("COUNTIF", range, .text("1"))
        assertNumber(result, 3)
    }

    func testCOUNTIFGreaterThan() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(5), .number(10)]))
        let result = try eval("COUNTIF", range, .text(">3"))
        assertNumber(result, 2) // 5 and 10
    }

    func testCOUNTIFText() throws {
        let range: CellValue = .array(CellMatrix(row: [.text("apple"), .text("banana"), .text("apple")]))
        let result = try eval("COUNTIF", range, .text("apple"))
        assertNumber(result, 2)
    }

    func testCOUNTIFNoMatch() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(2)]))
        let result = try eval("COUNTIF", range, .text(">100"))
        assertNumber(result, 0)
    }

    func testCOUNTIFCaseInsensitive() throws {
        let range: CellValue = .array(CellMatrix(row: [.text("Apple"), .text("APPLE"), .text("apple")]))
        let result = try eval("COUNTIF", range, .text("apple"))
        assertNumber(result, 3)
    }

    // MARK: - COUNTIFS

    func testCOUNTIFSMultipleCriteria() throws {
        let range1: CellValue = .array(CellMatrix(row: [.text("A"), .text("B"), .text("A"), .text("A")]))
        let range2: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3), .number(1)]))
        let result = try eval("COUNTIFS",
            range1, .text("A"),
            range2, .text(">1")
        )
        assertNumber(result, 1) // Only index 2 (A and 3 > 1)
    }

    func testCOUNTIFSSingleCriteria() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3)]))
        let result = try eval("COUNTIFS", range, .text(">=2"))
        assertNumber(result, 2) // 2 and 3
    }

    // MARK: - AVERAGEIF

    func testAVERAGEIFBasic() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(10), .number(20), .number(30)]))
        let result = try eval("AVERAGEIF", range, .text(">5"))
        assertNumber(result, 20) // (10 + 20 + 30) / 3
    }

    func testAVERAGEIFWithRange() throws {
        let criteriaRange: CellValue = .array(CellMatrix(row: [.text("A"), .text("B"), .text("A")]))
        let avgRange: CellValue = .array(CellMatrix(row: [.number(10), .number(20), .number(30)]))
        let result = try eval("AVERAGEIF", criteriaRange, .text("A"), avgRange)
        assertNumber(result, 20) // (10 + 30) / 2
    }

    func testAVERAGEIFNoMatch() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(2)]))
        let result = try eval("AVERAGEIF", range, .text(">100"))
        assertError(result, .div0)
    }

    func testAVERAGEIFSingleMatch() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(10), .number(20), .number(30)]))
        let result = try eval("AVERAGEIF", range, .text("20"))
        assertNumber(result, 20)
    }

    // MARK: - Criteria matching edge cases

    func testMatchesCriteriaLessOrEqual() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(5), .number(10)]))
        let result = try eval("COUNTIF", range, .text("<=5"))
        assertNumber(result, 2) // 1 and 5
    }

    func testMatchesCriteriaEqualsPrefix() throws {
        let range: CellValue = .array(CellMatrix(row: [.text("hello"), .text("world")]))
        let result = try eval("COUNTIF", range, .text("=hello"))
        assertNumber(result, 1)
    }

    func testMatchesCriteriaNumericAsString() throws {
        // When criteria is "5" (no operator), it matches number 5
        let range: CellValue = .array(CellMatrix(row: [.number(3), .number(5), .number(7)]))
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
