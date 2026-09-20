import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// `GROUPBY` and `PIVOTBY`.
///
/// Both were classified out of scope on **zero corpus demand**, not on difficulty, with the
/// note that the classification should move the moment they were wanted. These are the tests
/// that came with the move.
///
/// Unlike the `Psi*` family these are Excel's own functions and **can** be measured — a
/// workbook containing one opens and calculates. `ConformanceCases.roundTen` asks about the
/// defaults below rather than leaving them as this package's opinion.
final class GroupByTests: XCTestCase {

    private struct Sheet: CellValueProvider {
        let cells: [String: CellValue]
        func value(at ref: CellRef) -> CellValue? { cells[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { cells[ref.reference] }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { cells[$0.reference] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
        func lastPopulatedCell() -> CellRef? { CellRef("C4") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("C4") }
    }
    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    /// Four rows: region, quarter, sales.
    ///
    /// | | A | B | C |
    /// |---|---|---|---|
    /// | 1 | North | Q1 | 10 |
    /// | 2 | South | Q1 | 20 |
    /// | 3 | North | Q2 | 30 |
    /// | 4 | South | Q2 | 40 |
    private static let sheet = Sheet(cells: [
        "A1": .text("North"), "B1": .text("Q1"), "C1": .number(10),
        "A2": .text("South"), "B2": .text("Q1"), "C2": .number(20),
        "A3": .text("North"), "B3": .text("Q2"), "C3": .number(30),
        "A4": .text("South"), "B4": .text("Q2"), "C4": .number(40),
    ])

    private func evaluate(_ formula: String) throws -> CellValue {
        try FormulaEvaluator.evaluate(
            try FormulaParser.parse(formula), cells: Self.sheet, names: NoNames())
    }

    private func matrix(_ formula: String) throws -> CellMatrix {
        let answer = try evaluate(formula)
        guard case .array(let matrix) = answer else {
            XCTFail("\(formula) gave \(answer), expected an array")
            throw CocoaError(.featureUnsupported)
        }
        return matrix
    }

    // MARK: - GROUPBY

    /// **The aggregate is named, not called.** `SUM` here is the function itself.
    ///
    /// Two regions, their sales summed, plus a grand total: North 40, South 60, Total 100.
    func testGroupBySumsByRegion() throws {
        let result = try matrix("GROUPBY(A1:A4, C1:C4, SUM)")
        XCTAssertEqual(result.columns, 2)
        XCTAssertEqual(result.rows, 3, "two groups and a grand total")
        XCTAssertEqual(result.elements, [
            .text("North"), .number(40),
            .text("South"), .number(60),
            .text("Total"), .number(100),
        ])
    }

    /// Groups sort ascending by key by default.
    func testGroupsSortAscendingByDefault() throws {
        let result = try matrix("GROUPBY(A1:A4, C1:C4, SUM)")
        XCTAssertEqual(result.elements.first, .text("North"))
        // Descending is asked for with a negative sort order.
        let descending = try matrix("GROUPBY(A1:A4, C1:C4, SUM, 0, 1, -1)")
        XCTAssertEqual(descending.elements.first, .text("South"))
    }

    /// `total_depth` of zero drops the total row.
    func testTheTotalRowCanBeTurnedOff() throws {
        let result = try matrix("GROUPBY(A1:A4, C1:C4, SUM, 0, 0)")
        XCTAssertEqual(result.rows, 2)
        XCTAssertFalse(result.elements.contains(.text("Total")))
    }

    /// **The grand total aggregates the data, not the group aggregates.**
    ///
    /// Summing sums agrees either way. Averaging averages does **not**: the mean of the group
    /// means is 25 here, while the mean of the four values is 25 as well — so the test uses
    /// an unbalanced column where the two genuinely differ, which is the only way this
    /// assertion means anything.
    func testTheGrandTotalIsOverTheDataNotTheGroups() throws {
        // North has one row (10), South has three (20, 30, 40).
        let unbalanced = Sheet(cells: [
            "A1": .text("North"), "C1": .number(10),
            "A2": .text("South"), "C2": .number(20),
            "A3": .text("South"), "C3": .number(30),
            "A4": .text("South"), "C4": .number(40),
        ])
        let answer = try FormulaEvaluator.evaluate(
            try FormulaParser.parse("GROUPBY(A1:A4, C1:C4, AVERAGE)"),
            cells: unbalanced, names: NoNames())
        guard case .array(let result) = answer else { return XCTFail("got \(answer)") }
        // Group means: North 10, South 30. Their mean is 20; the data's mean is 25.
        XCTAssertEqual(result.elements.last, .number(25),
                       "the total is the mean of the data, not of the group means")
    }

    /// A `LAMBDA` works in the aggregate position, which is what makes it open-ended.
    func testALambdaCanBeTheAggregate() throws {
        let result = try matrix("GROUPBY(A1:A4, C1:C4, LAMBDA(v, MAX(v)-MIN(v)), 0, 0)")
        // North spans 10…30, South spans 20…40; both ranges are 20.
        XCTAssertEqual(result.elements, [
            .text("North"), .number(20),
            .text("South"), .number(20),
        ])
    }

    /// Other aggregates reach the same groups.
    func testOtherAggregates() throws {
        let counted = try matrix("GROUPBY(A1:A4, C1:C4, COUNT, 0, 0)")
        XCTAssertEqual(counted.elements, [
            .text("North"), .number(2), .text("South"), .number(2),
        ])
        let largest = try matrix("GROUPBY(A1:A4, C1:C4, MAX, 0, 0)")
        XCTAssertEqual(largest.elements, [
            .text("North"), .number(30), .text("South"), .number(40),
        ])
    }

    /// Keys match case-insensitively, as Excel compares text everywhere else.
    func testKeysMatchCaseInsensitively() throws {
        let mixed = Sheet(cells: [
            "A1": .text("North"), "C1": .number(10),
            "A2": .text("north"), "C2": .number(20),
        ])
        let answer = try FormulaEvaluator.evaluate(
            try FormulaParser.parse("GROUPBY(A1:A2, C1:C2, SUM, 0, 0)"),
            cells: mixed, names: NoNames())
        guard case .array(let result) = answer else { return XCTFail("got \(answer)") }
        XCTAssertEqual(result.rows, 1, "North and north are one region")
        XCTAssertEqual(result.elements.last, .number(30))
    }

    /// Mismatched column lengths describe no table.
    func testMismatchedColumnsAreRefused() throws {
        XCTAssertEqual(try evaluate("GROUPBY(A1:A4, C1:C2, SUM)"), .error(.value))
    }

    /// A name that is neither a function nor a lambda.
    func testAnUnknownAggregateIsRefused() throws {
        XCTAssertEqual(try evaluate("GROUPBY(A1:A4, C1:C4, NotAFunction)"), .error(.value))
    }

    // MARK: - PIVOTBY

    /// Regions down, quarters across, with a header row and totals both ways.
    func testPivotByCrossTabulates() throws {
        let result = try matrix("PIVOTBY(A1:A4, B1:B4, C1:C4, SUM)")
        XCTAssertEqual(result.columns, 4, "a corner, two quarters and a total")
        XCTAssertEqual(result.rows, 4, "a header, two regions and a total")
        XCTAssertEqual(result.elements, [
            .blank,         .text("Q1"), .text("Q2"), .text("Total"),
            .text("North"), .number(10), .number(30), .number(40),
            .text("South"), .number(20), .number(40), .number(60),
            .text("Total"), .number(30), .number(70), .number(100),
        ])
    }

    /// **A cell with no rows behind it is empty, not zero.**
    ///
    /// No observation is not an observation of nothing. A zero there would be indistinguishable
    /// from a real zero to everything downstream — and would be counted and averaged with the
    /// genuine values.
    func testAnEmptyIntersectionIsBlank() throws {
        let sparse = Sheet(cells: [
            "A1": .text("North"), "B1": .text("Q1"), "C1": .number(10),
            "A2": .text("South"), "B2": .text("Q2"), "C2": .number(20),
        ])
        let answer = try FormulaEvaluator.evaluate(
            try FormulaParser.parse("PIVOTBY(A1:A2, B1:B2, C1:C2, SUM, 0, 0)"),
            cells: sparse, names: NoNames())
        guard case .array(let result) = answer else { return XCTFail("got \(answer)") }
        // North/Q2 and South/Q1 have no rows.
        //
        // The `Total` column is here because `col_total_depth` was omitted, and omitted is 1
        // — measured in round twelve, where `COLUMNS(PIVOTBY(…, SUM, 0, 0))` is 4. The two
        // depths are independent, and `0` in the fifth position suppresses only the total
        // *row*. This test asserted a 3×3 grid before that was known.
        XCTAssertEqual(result.elements, [
            .blank,         .text("Q1"), .text("Q2"), .text("Total"),
            .text("North"), .number(10), .blank,      .number(10),
            .text("South"), .blank,      .number(20), .number(20),
        ])
    }

    // MARK: - What round twelve measured

    /// Excel detects a header row, and consumes it.
    ///
    /// **Measured in round twelve**, on `{"k";"a";"b"}` over `{"v";1;2}`: with
    /// `field_headers` at 1 *or omitted* Excel answers three rows — two groups and a total —
    /// and only an explicit 0 treats the first row as data. This package had the default
    /// backwards, counting `k` as a third group.
    func testAHeaderRowIsDetectedAndConsumed() throws {
        XCTAssertEqual(try matrix("GROUPBY({\"k\";\"a\";\"b\"}, {\"v\";1;2}, SUM, 1)").rows, 3,
                       "field_headers 1 consumes the header")
        XCTAssertEqual(try matrix("GROUPBY({\"k\";\"a\";\"b\"}, {\"v\";1;2}, SUM)").rows, 3,
                       "omitted detects it, which is the default Excel documents and keeps")
        XCTAssertEqual(try matrix("GROUPBY({\"k\";\"a\";\"b\"}, {\"v\";1;2}, SUM, 0)").rows, 4,
                       "and an explicit 0 makes it data — the one case already agreeing")
    }

    /// A negative `total_depth` puts the total **above**, it does not remove it.
    ///
    /// Measured: `ROWS(GROUPBY({"a";"a";"b"}, {1;2;3}, SUM, 0, -1))` is 3 — two groups and a
    /// total. This package read the sign as "no totals" and answered 2.
    func testANegativeTotalDepthPutsTheTotalAbove() throws {
        let result = try matrix("GROUPBY({\"a\";\"a\";\"b\"}, {1;2;3}, SUM, 0, -1)")
        XCTAssertEqual(result.rows, 3, "the total is present, not suppressed")
        XCTAssertEqual(result[0, 0], .text("Total"), "and it is the first row, not the last")
        XCTAssertEqual(result[0, 1], .number(6))
    }

    /// A `total_depth` deeper than the grouping is `#VALUE!`.
    ///
    /// Measured: one grouping level and `total_depth` 2 is refused. This package answered.
    func testATotalDepthDeeperThanTheGroupingIsRefused() throws {
        XCTAssertEqual(try evaluate("GROUPBY({\"a\";\"a\";\"b\"}, {1;2;3}, SUM, 0, 2)"),
                       .error(.value))
    }

    /// `sort_order` names a **column**, and its sign is the direction.
    ///
    /// Measured: over keys `{"a";"b"}` and values `{2;1}`, `sort_order` 2 puts `"b"` first —
    /// sorted by the values column ascending — and −2 puts `"a"` first. This package ignored
    /// the magnitude and read only the sign, so both answered by key.
    func testSortOrderNamesAColumn() throws {
        XCTAssertEqual(try matrix("GROUPBY({\"a\";\"b\"}, {2;1}, SUM, 0, 0, 2)")[0, 0],
                       .text("b"), "column 2 ascending: b holds 1, a holds 2")
        XCTAssertEqual(try matrix("GROUPBY({\"a\";\"b\"}, {2;1}, SUM, 0, 0, -2)")[0, 0],
                       .text("a"), "and descending")
        XCTAssertEqual(try matrix("GROUPBY({\"a\";\"b\"}, {2;1}, SUM, 0, 0, 1)")[0, 0],
                       .text("a"), "column 1 ascending is still by key")
        XCTAssertEqual(try matrix("GROUPBY({\"a\";\"b\"}, {2;1}, SUM, 0, 0, -1)")[0, 0],
                       .text("b"), "and by key descending")
    }

    /// `filter_array` excludes the rows it marks false.
    ///
    /// Measured: `SUM(GROUPBY({"a";"b";"c"}, {1;2;3}, SUM, 0, 0, 1, {TRUE;FALSE;TRUE}))` is 4
    /// — 1 and 3, with the middle row dropped. This package ignored the argument and summed 6.
    func testAFilterArrayExcludesRows() throws {
        let result = try matrix(
            "GROUPBY({\"a\";\"b\";\"c\"}, {1;2;3}, SUM, 0, 0, 1, {TRUE;FALSE;TRUE})")
        XCTAssertEqual(result.rows, 2, "two groups survive the filter")
        var total = 0.0
        for row in 0..<result.rows {
            if case .number(let value) = result[row, 1] { total += value }
        }
        XCTAssertEqual(total, 4, accuracy: 1e-12, "1 and 3, not 6")
    }
}
