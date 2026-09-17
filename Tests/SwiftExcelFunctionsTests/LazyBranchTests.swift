import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// A branch not taken is a branch not evaluated.
///
/// The evaluator evaluated **every** argument before dispatching to a function — stated
/// plainly in `EvaluationContext`'s own documentation — which is right for `SUM` and wrong
/// for `IF`. Excel evaluates only the branch it takes, and the difference is invisible in
/// most formulas because an untaken branch usually just computes a value nobody reads.
///
/// It stops being invisible at recursion. The way a spreadsheet author writes a loop is
///
/// ```
/// LAMBDA(f, n, IF(n<=0, 0, 1 + f(f, n-1)))
/// ```
///
/// and if `IF` evaluates both arms then the recursive arm is evaluated on the base case too,
/// for ever. No `LAMBDA` can work until this does, which makes it a prerequisite the
/// `LAMBDA` proposal did not have.
final class LazyBranchTests: XCTestCase {

    private struct Cells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet sheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet sheet: String) -> [CellValue] { [] }
    }
    private struct Names: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    /// Counts how often it is evaluated, which is the only way to see the difference.
    // Justification: a counter reached only from one synchronous evaluation, on one thread.
    private final class Tally: @unchecked Sendable {
        private(set) var count = 0
        func hit() { count += 1 }
    }

    private func registry(counting tally: Tally) -> FunctionRegistry {
        var registry = FunctionRegistry.builtin
        registry.register(ExcelFunction(name: "TALLY", minArgs: 0, maxArgs: 0) { _ in
            tally.hit()
            return .number(1)
        })
        return registry
    }

    private func eval(_ ast: FormulaAST, _ tally: Tally) throws -> CellValue {
        try FormulaEvaluator.evaluate(ast, cells: Cells(), names: Names(),
                                      functions: registry(counting: tally))
    }

    // MARK: - IF

    func testIfEvaluatesOnlyTheBranchItTakes() throws {
        let tally = Tally()
        let result = try eval(
            .function("IF", [.bool(true), .number(7), .function("TALLY", [])]), tally)

        XCTAssertEqual(result, .number(7))
        XCTAssertEqual(tally.count, 0, "the false branch was evaluated and must not be")
    }

    func testIfEvaluatesTheFalseBranchWhenItTakesIt() throws {
        let tally = Tally()
        let result = try eval(
            .function("IF", [.bool(false), .number(7), .function("TALLY", [])]), tally)

        XCTAssertEqual(result, .number(1))
        XCTAssertEqual(tally.count, 1)
    }

    /// The condition is always evaluated, and exactly once.
    func testTheConditionIsEvaluatedOnce() throws {
        let tally = Tally()
        _ = try eval(.function("IF", [.function("TALLY", []), .number(1), .number(2)]), tally)
        XCTAssertEqual(tally.count, 1)
    }

    /// An omitted third argument is `FALSE`, as in Excel, and evaluates nothing.
    func testIfWithNoFalseBranch() throws {
        let tally = Tally()
        XCTAssertEqual(try eval(.function("IF", [.bool(false), .number(7)]), tally),
                       .bool(false))
        XCTAssertEqual(tally.count, 0)
    }

    // MARK: - The error handlers

    /// `IFERROR`'s whole purpose is a fallback, and a fallback computed regardless is not one.
    func testIferrorDoesNotEvaluateItsFallbackWhenThereIsNoError() throws {
        let tally = Tally()
        let result = try eval(
            .function("IFERROR", [.number(3), .function("TALLY", [])]), tally)

        XCTAssertEqual(result, .number(3))
        XCTAssertEqual(tally.count, 0)
    }

    func testIferrorEvaluatesItsFallbackOnAnError() throws {
        let tally = Tally()
        let result = try eval(
            .function("IFERROR", [.divide(.number(1), .number(0)),
                                  .function("TALLY", [])]), tally)

        XCTAssertEqual(result, .number(1))
        XCTAssertEqual(tally.count, 1)
    }

    func testIfnaIsLazyToo() throws {
        let tally = Tally()
        XCTAssertEqual(
            try eval(.function("IFNA", [.number(3), .function("TALLY", [])]), tally),
            .number(3))
        XCTAssertEqual(tally.count, 0)
    }

    // MARK: - Choosing among many

    func testChooseEvaluatesOnlyTheChosenOne() throws {
        let tally = Tally()
        let result = try eval(
            .function("CHOOSE", [.number(1), .number(9), .function("TALLY", []),
                                 .function("TALLY", [])]), tally)

        XCTAssertEqual(result, .number(9))
        XCTAssertEqual(tally.count, 0)
    }

    // `IFS` and `SWITCH` belong in this list and are not implemented at all — they are two
    // of the eleven rows in the `logical` bucket. When they arrive they arrive lazy, and
    // `LazyBranch` is where that is decided. Tests for them belong with their implementation
    // rather than here, asserting laziness of something that answers `#NAME?`.

    // MARK: - What stays eager

    /// `AND` and `OR` are **not** short-circuiting in Excel, and guessing otherwise would be
    /// inventing a rule. Every argument is evaluated.
    func testAndAndOrStayEager() throws {
        let tally = Tally()
        _ = try eval(.function("AND", [.bool(false), .function("TALLY", [])]), tally)
        _ = try eval(.function("OR", [.bool(true), .function("TALLY", [])]), tally)
        XCTAssertEqual(tally.count, 2, "Excel evaluates both, and so must this")
    }

    /// An ordinary function is unaffected: `SUM` needs all of its arguments.
    func testOrdinaryFunctionsAreUnaffected() throws {
        let tally = Tally()
        XCTAssertEqual(
            try eval(.function("SUM", [.number(1), .function("TALLY", []),
                                       .function("TALLY", [])]), tally),
            .number(3))
        XCTAssertEqual(tally.count, 2)
    }
}
