import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

@Suite struct BuiltinAggregationFunctionTests {

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



    // MARK: - Registration count

    /// By name rather than by count: a count says something changed without
    /// saying what, and fails the same way whether a function arrived or went.
    @Test func allContainsEveryFunctionInTheGroup() {
        #expect(Set(BuiltinAggregationFunctions.all.map(\.name)) == ["SUM", "SUMIF", "SUMIFS", "COUNTIF", "COUNTIFS", "AVERAGEIF", "AVERAGEIFS",
             "SUMPRODUCT", "SUMSQ"])
    }

    // MARK: - SUM

    @Test func sumBasic() throws {
        let result = try eval("SUM", .number(1), .number(2), .number(3))
        #expect(result.isNumber(6))
    }

    @Test func sumWithArray() throws {
        let result = try eval("SUM", .array(CellMatrix(row: [.number(1), .number(2), .number(3)])))
        #expect(result.isNumber(6))
    }

    @Test func sumIgnoresText() throws {
        let result = try eval("SUM", .number(1), .text("hello"), .number(2))
        #expect(result.isNumber(3))
    }

    @Test func sumIgnoresBlank() throws {
        let result = try eval("SUM", .number(1), .blank, .number(2))
        #expect(result.isNumber(3))
    }

    @Test func sumFlattensNestedArrays() throws {
        let result = try eval("SUM",
            .array(CellMatrix(row: [.number(1), .number(2)])),
            .number(3),
            .array(CellMatrix(row: [.number(4)]))
        )
        #expect(result.isNumber(10))
    }

    @Test func sumErrorPropagation() throws {
        let result = try eval("SUM", .number(1), .error(.ref), .number(2))
        #expect(result == .error(.ref))
    }

    @Test func sumBoolValues() throws {
        // In SUM, TRUE=1, FALSE=0
        let result = try eval("SUM", .bool(true), .bool(false), .number(3))
        #expect(result.isNumber(4))
    }

    @Test func sumSingleValue() throws {
        let result = try eval("SUM", .number(42))
        #expect(result.isNumber(42))
    }

    // MARK: - SUMIF

    @Test func sumifGreaterThan() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(5), .number(10), .number(15)]))
        let result = try eval("SUMIF", range, .text(">5"))
        #expect(result.isNumber(25)) // 10 + 15
    }

    @Test func sumifEquals() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(1), .number(3)]))
        let result = try eval("SUMIF", range, .text("1"))
        #expect(result.isNumber(2)) // 1 + 1
    }

    @Test func sumifNotEqual() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(0), .number(5), .number(0), .number(10)]))
        let result = try eval("SUMIF", range, .text("<>0"))
        #expect(result.isNumber(15)) // 5 + 10
    }

    @Test func sumifWithSumRange() throws {
        let criteriaRange: CellValue = .array(CellMatrix(row: [.text("A"), .text("B"), .text("A"), .text("C")]))
        let sumRange: CellValue = .array(CellMatrix(row: [.number(10), .number(20), .number(30), .number(40)]))
        let result = try eval("SUMIF", criteriaRange, .text("A"), sumRange)
        #expect(result.isNumber(40)) // 10 + 30
    }

    @Test func sumifGreaterOrEqual() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(5), .number(10)]))
        let result = try eval("SUMIF", range, .text(">=5"))
        #expect(result.isNumber(15)) // 5 + 10
    }

    @Test func sumifLessThan() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(5), .number(10)]))
        let result = try eval("SUMIF", range, .text("<5"))
        #expect(result.isNumber(1))
    }

    @Test func sumifNoMatch() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3)]))
        let result = try eval("SUMIF", range, .text(">100"))
        #expect(result.isNumber(0))
    }

    // MARK: - SUMIFS

    @Test func sumifsMultipleCriteria() throws {
        let sumRange: CellValue = .array(CellMatrix(row: [.number(10), .number(20), .number(30), .number(40)]))
        let criteria1Range: CellValue = .array(CellMatrix(row: [.text("A"), .text("B"), .text("A"), .text("B")]))
        let criteria2Range: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3), .number(4)]))
        let result = try eval("SUMIFS",
            sumRange,
            criteria1Range, .text("A"),
            criteria2Range, .text(">1")
        )
        #expect(result.isNumber(30)) // Only index 2 matches (A and 3 > 1)
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
    @Test func anErrorAsTheCriteriaMatchesNothing() throws {
        let keys: CellValue = .array(CellMatrix(row: [.text("x"), .text("y"), .text("x")]))
        let values: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3)]))

        #expect(try eval("SUMIF", keys, .error(.ref), values).isNumber(0))
        #expect(try eval("SUMIFS", values, keys, .error(.ref)).isNumber(0))
    }

    /// A **blank** criteria matches nothing either — not blanks, and not zero.
    ///
    /// Measured in round fifteen over a range that *contains* a blank, which is the case that
    /// could have gone either way. Excel answers `0` for all four spellings; this package
    /// matched the blank and answered `2`, or counted it and answered `1`.
    @Test func aBlankCriteriaMatchesNothing() throws {
        let keys: CellValue = .array(CellMatrix(row: [.text("x"), .blank, .text("x")]))
        let values: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3)]))

        #expect(try eval("SUMIF", keys, .blank, values).isNumber(0, within: 0))
        #expect(try eval("SUMIFS", values, keys, .blank).isNumber(0, within: 0))
        #expect(try eval("COUNTIF", keys, .blank).isNumber(0, within: 0))
        #expect(try eval("COUNTIFS", keys, .blank).isNumber(0, within: 0))
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
    @Test func sumifStretchesAShortSumRangeAndSUMIFSRefusesOne() throws {
        let keys: CellValue = .array(CellMatrix(row: [.text("x"), .text("y"), .text("x")]))
        let oneCell: CellValue = .number(1)

        #expect(try eval("SUMIFS", oneCell, keys, .text("x")) == .error(.value), "SUMIFS requires the shapes to match")

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
    @Test func sumifPropagatesAnErrorOnlyFromASelectedRow() throws {
        let keys: CellValue = .array(CellMatrix(row: [.text("x"), .text("y"), .text("x")]))

        let matching: CellValue = .array(CellMatrix(row: [.error(.ref), .number(2), .number(3)]))
        #expect(try eval("SUMIF", keys, .text("x"), matching) == .error(.ref), "the error sits in a row the criteria selects")

        let skipped: CellValue = .array(CellMatrix(row: [.number(1), .error(.ref), .number(3)]))
        // The error sits in the row keyed y, which is not summed.
        #expect(try eval("SUMIF", keys, .text("x"), skipped).isNumber(4))

        let inCriteria: CellValue = .array(CellMatrix(row: [.text("x"), .error(.ref), .text("x")]))
        let values: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3)]))
        // An error in the criteria range matches nothing, and poisons nothing.
        #expect(try eval("SUMIF", inCriteria, .text("x"), values).isNumber(4))
    }

    /// `SUMIFS` follows the same rule, which it need not have.
    @Test func sumifsPropagatesAnErrorOnlyFromASelectedRow() throws {
        let keys: CellValue = .array(CellMatrix(row: [.text("x"), .text("y"), .text("x")]))

        let matching: CellValue = .array(CellMatrix(row: [.error(.ref), .number(2), .number(3)]))
        #expect(try eval("SUMIFS", matching, keys, .text("x")) == .error(.ref))

        let skipped: CellValue = .array(CellMatrix(row: [.number(1), .error(.ref), .number(3)]))
        #expect(try eval("SUMIFS", skipped, keys, .text("x")).isNumber(4))
    }

    /// And `AVERAGEIF`, which was asked because it need not have agreed either.
    @Test func averageifPropagatesAnErrorFromASelectedRow() throws {
        let keys: CellValue = .array(CellMatrix(row: [.text("x"), .text("y"), .text("x")]))
        let matching: CellValue = .array(CellMatrix(row: [.error(.ref), .number(2), .number(3)]))
        #expect(try eval("AVERAGEIF", keys, .text("x"), matching) == .error(.ref))
    }

    /// `COUNTIF` counts around an error rather than propagating it — measured, and the
    /// control that says the rule above is about summing rather than about ranges.
    @Test func countifCountsAroundAnError() throws {
        let inCriteria: CellValue = .array(CellMatrix(row: [.text("x"), .error(.ref), .text("x")]))
        #expect(try eval("COUNTIF", inCriteria, .text("x")).isNumber(2))

        let numbers: CellValue = .array(CellMatrix(row: [.number(1), .error(.ref), .number(3)]))
        #expect(try eval("COUNTIF", numbers, .text(">1")).isNumber(1))
    }

    @Test func sumifsPropagatesAnErrorArgument() throws {
        let criteriaRange: CellValue = .array(CellMatrix(row: [.text("A"), .text("B")]))
        let result = try eval("SUMIFS", .error(.ref), criteriaRange, .text("A"))
        #expect(result == .error(.ref), "a broken reference is not an empty sum")
    }

    @Test func sumifsSingleCriteria() throws {
        let sumRange: CellValue = .array(CellMatrix(row: [.number(10), .number(20), .number(30)]))
        let criteriaRange: CellValue = .array(CellMatrix(row: [.text("A"), .text("B"), .text("A")]))
        let result = try eval("SUMIFS", sumRange, criteriaRange, .text("A"))
        #expect(result.isNumber(40)) // 10 + 30
    }

    // MARK: - COUNTIF

    @Test func countifEquals() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(1), .number(3), .number(1)]))
        let result = try eval("COUNTIF", range, .text("1"))
        #expect(result.isNumber(3))
    }

    @Test func countifGreaterThan() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(5), .number(10)]))
        let result = try eval("COUNTIF", range, .text(">3"))
        #expect(result.isNumber(2)) // 5 and 10
    }

    @Test func countifText() throws {
        let range: CellValue = .array(CellMatrix(row: [.text("apple"), .text("banana"), .text("apple")]))
        let result = try eval("COUNTIF", range, .text("apple"))
        #expect(result.isNumber(2))
    }

    @Test func countifNoMatch() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(2)]))
        let result = try eval("COUNTIF", range, .text(">100"))
        #expect(result.isNumber(0))
    }

    @Test func countifCaseInsensitive() throws {
        let range: CellValue = .array(CellMatrix(row: [.text("Apple"), .text("APPLE"), .text("apple")]))
        let result = try eval("COUNTIF", range, .text("apple"))
        #expect(result.isNumber(3))
    }

    // MARK: - COUNTIFS

    @Test func countifsMultipleCriteria() throws {
        let range1: CellValue = .array(CellMatrix(row: [.text("A"), .text("B"), .text("A"), .text("A")]))
        let range2: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3), .number(1)]))
        let result = try eval("COUNTIFS",
            range1, .text("A"),
            range2, .text(">1")
        )
        #expect(result.isNumber(1)) // Only index 2 (A and 3 > 1)
    }

    @Test func countifsSingleCriteria() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(2), .number(3)]))
        let result = try eval("COUNTIFS", range, .text(">=2"))
        #expect(result.isNumber(2)) // 2 and 3
    }

    // MARK: - AVERAGEIF

    @Test func averageifBasic() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(10), .number(20), .number(30)]))
        let result = try eval("AVERAGEIF", range, .text(">5"))
        #expect(result.isNumber(20)) // (10 + 20 + 30) / 3
    }

    @Test func averageifWithRange() throws {
        let criteriaRange: CellValue = .array(CellMatrix(row: [.text("A"), .text("B"), .text("A")]))
        let avgRange: CellValue = .array(CellMatrix(row: [.number(10), .number(20), .number(30)]))
        let result = try eval("AVERAGEIF", criteriaRange, .text("A"), avgRange)
        #expect(result.isNumber(20)) // (10 + 30) / 2
    }

    @Test func averageifNoMatch() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(2)]))
        let result = try eval("AVERAGEIF", range, .text(">100"))
        #expect(result == .error(.div0))
    }

    @Test func averageifSingleMatch() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(10), .number(20), .number(30)]))
        let result = try eval("AVERAGEIF", range, .text("20"))
        #expect(result.isNumber(20))
    }

    // MARK: - Criteria matching edge cases

    @Test func matchesCriteriaLessOrEqual() throws {
        let range: CellValue = .array(CellMatrix(row: [.number(1), .number(5), .number(10)]))
        let result = try eval("COUNTIF", range, .text("<=5"))
        #expect(result.isNumber(2)) // 1 and 5
    }

    @Test func matchesCriteriaEqualsPrefix() throws {
        let range: CellValue = .array(CellMatrix(row: [.text("hello"), .text("world")]))
        let result = try eval("COUNTIF", range, .text("=hello"))
        #expect(result.isNumber(1))
    }

    @Test func matchesCriteriaNumericAsString() throws {
        // When criteria is "5" (no operator), it matches number 5
        let range: CellValue = .array(CellMatrix(row: [.number(3), .number(5), .number(7)]))
        let result = try eval("COUNTIF", range, .number(5))
        #expect(result.isNumber(1))
    }

    // MARK: - Metadata

    @Test func sumMetadata() {
        let fn = function(named: "SUM")
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == nil)
    }

    @Test func sumifMetadata() {
        let fn = function(named: "SUMIF")
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == 3)
    }

    @Test func sumifsMetadata() {
        let fn = function(named: "SUMIFS")
        #expect(fn.minArgs == 3)
        #expect(fn.maxArgs == nil)
    }

    @Test func countifMetadata() {
        let fn = function(named: "COUNTIF")
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == 2)
    }

    @Test func countifsMetadata() {
        let fn = function(named: "COUNTIFS")
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == nil)
    }

    @Test func averageifMetadata() {
        let fn = function(named: "AVERAGEIF")
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == 3)
    }
}
