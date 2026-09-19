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
        XCTAssertEqual(result.elements, [
            .blank,         .text("Q1"), .text("Q2"),
            .text("North"), .number(10), .blank,
            .text("South"), .blank,      .number(20),
        ])
    }
}
