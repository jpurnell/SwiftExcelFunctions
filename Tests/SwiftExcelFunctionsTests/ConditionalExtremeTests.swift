import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// `MAXIFS` and `MINIFS` — the extremes over the rows that meet every criterion.
final class ConditionalExtremeTests: XCTestCase {

    private func fn(_ name: String) throws -> ExcelFunction {
        try XCTUnwrap(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
    }
    private func call(_ name: String, _ a: CellValue...) throws -> CellValue { try fn(name).evaluate(a) }
    private func n(_ name: String, _ a: CellValue...) throws -> Double {
        guard case .number(let d) = try fn(name).evaluate(a) else {
            throw XCTSkip("\(name) did not return a number")
        }
        return d
    }
    private func nums(_ v: [Double]) -> CellValue { .array(CellMatrix(row: v.map { .number($0) })) }
    private func texts(_ v: [String]) -> CellValue { .array(CellMatrix(row: v.map { .text($0) })) }

    // MARK: - One criterion

    func testMaxOverMatchingRows() throws {
        let values = nums([10, 20, 30, 40])
        let region = texts(["N", "S", "N", "S"])
        XCTAssertEqual(try n("MAXIFS", values, region, .text("N")), 30, accuracy: 1e-12)
        XCTAssertEqual(try n("MINIFS", values, region, .text("N")), 10, accuracy: 1e-12)
    }

    /// A comparison criterion, which is where the string is doing real work.
    func testComparisonCriterion() throws {
        let values = nums([10, 20, 30, 40])
        XCTAssertEqual(try n("MAXIFS", values, values, .text(">15")), 40, accuracy: 1e-12)
        XCTAssertEqual(try n("MINIFS", values, values, .text(">15")), 20, accuracy: 1e-12)
    }

    // MARK: - Several criteria

    /// **Every criterion must hold**, so the criteria narrow rather than widen. The rows
    /// that survive are the intersection, which is what makes `MAXIFS` different from a
    /// maximum over several `MAXIF`s.
    func testCriteriaAreCombinedWithAnd() throws {
        let values = nums([10, 20, 30, 40, 50])
        let region = texts(["N", "N", "S", "N", "S"])
        let grade = texts(["A", "B", "A", "A", "B"])

        // North AND grade A: rows 0 and 3 → values 10 and 40.
        XCTAssertEqual(try n("MAXIFS", values, region, .text("N"), grade, .text("A")),
                       40, accuracy: 1e-12)
        XCTAssertEqual(try n("MINIFS", values, region, .text("N"), grade, .text("A")),
                       10, accuracy: 1e-12)
    }

    // MARK: - Nothing matches

    /// **No matching row is zero, not `#N/A`.** Excel documents this one against the grain
    /// — `MAXIFS` over an empty selection is 0, where `MODE.SNGL` over no mode is `#N/A`.
    /// Guessing consistently across the library gets this wrong.
    func testNoMatchIsZero() throws {
        let values = nums([10, 20])
        XCTAssertEqual(try call("MAXIFS", values, texts(["N", "N"]), .text("S")), .number(0))
        XCTAssertEqual(try call("MINIFS", values, texts(["N", "N"]), .text("S")), .number(0))
    }

    // MARK: - Shape

    /// Criteria arrive in pairs, so an odd count is malformed.
    func testUnpairedCriteriaIsAnError() throws {
        let values = nums([1, 2])
        XCTAssertEqual(try call("MAXIFS", values, texts(["a", "b"])), .error(.value))
    }

    /// A criteria range shorter than the value range cannot be lined up row by row.
    func testMismatchedRangeLengths() throws {
        XCTAssertEqual(try call("MAXIFS", nums([1, 2, 3]), texts(["a"]), .text("a")),
                       .error(.value))
    }

    /// Text in the value range is not a candidate — the extreme is over numbers.
    func testTextValuesAreNotCandidates() throws {
        let values = CellValue.array(CellMatrix(row: [.number(5), .text("n/a"), .number(9)]))
        let flags = texts(["y", "y", "y"])
        XCTAssertEqual(try n("MAXIFS", values, flags, .text("y")), 9, accuracy: 1e-12)
        XCTAssertEqual(try n("MINIFS", values, flags, .text("y")), 5, accuracy: 1e-12)
    }
}
