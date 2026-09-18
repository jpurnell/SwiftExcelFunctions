import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// `IFS`, `SWITCH` and `XOR` — the three `logical` rows the `LAMBDA` work did not cover.
///
/// The other eight in that bucket were `LAMBDA`, `LET` and the higher-order six. These are
/// what is left, and two of them were named in `LazyBranch` as belonging there and not
/// existing yet: *"`IFS` and `SWITCH` belong here and are not implemented at all yet; when
/// they arrive they arrive lazy."* They arrive lazy.
final class LogicalRemainderTests: XCTestCase {

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

    // Justification: reached only from one synchronous evaluation, on one thread.
    private final class Tally: @unchecked Sendable {
        private(set) var count = 0
        func hit() { count += 1 }
    }

    private func eval(_ ast: FormulaAST, _ tally: Tally? = nil) throws -> CellValue {
        var registry = FunctionRegistry.builtin
        if let tally {
            registry.register(ExcelFunction(name: "TALLY", minArgs: 0, maxArgs: 0) { _ in
                tally.hit()
                return .number(1)
            })
        }
        return try FormulaEvaluator.evaluate(
            ast, cells: Cells(), names: Names(), functions: registry)
    }

    // MARK: - IFS

    func testIfsTakesTheFirstTrueCondition() throws {
        let ast = FormulaAST.function("IFS", [
            .bool(false), .text("no"),
            .bool(true), .text("yes"),
            .bool(true), .text("also yes"),
        ])
        XCTAssertEqual(try eval(ast), .text("yes"))
    }

    /// No condition true is `#N/A`, which is Excel's answer and not `#VALUE!`.
    func testIfsWithNoMatchIsNotAvailable() throws {
        XCTAssertEqual(
            try eval(.function("IFS", [.bool(false), .number(1), .bool(false), .number(2)])),
            .error(.na))
    }

    /// Only the matching result is evaluated, and only up to the matching condition.
    func testIfsIsLazy() throws {
        let tally = Tally()
        let ast = FormulaAST.function("IFS", [
            .bool(true), .number(5),
            .function("TALLY", []), .function("TALLY", []),
        ])
        XCTAssertEqual(try eval(ast, tally), .number(5))
        XCTAssertEqual(tally.count, 0, "neither the later condition nor its result")
    }

    /// An error in a condition is the answer.
    func testIfsPropagatesAnErrorInACondition() throws {
        XCTAssertEqual(
            try eval(.function("IFS", [.divide(.number(1), .number(0)), .number(1)])),
            .error(.div0))
    }

    /// Conditions and results come in pairs.
    func testIfsNeedsPairs() throws {
        XCTAssertEqual(try eval(.function("IFS", [.bool(true), .number(1), .bool(true)])),
                       .error(.value))
    }

    // MARK: - SWITCH

    func testSwitchMatchesAValue() throws {
        let ast = FormulaAST.function("SWITCH", [
            .number(2),
            .number(1), .text("one"),
            .number(2), .text("two"),
        ])
        XCTAssertEqual(try eval(ast), .text("two"))
    }

    /// A trailing odd argument is the default.
    func testSwitchUsesItsDefault() throws {
        let ast = FormulaAST.function("SWITCH", [
            .number(9),
            .number(1), .text("one"),
            .text("none of them"),
        ])
        XCTAssertEqual(try eval(ast), .text("none of them"))
    }

    /// With no default and no match, `#N/A`.
    func testSwitchWithNoMatchAndNoDefault() throws {
        XCTAssertEqual(
            try eval(.function("SWITCH", [.number(9), .number(1), .text("one")])),
            .error(.na))
    }

    func testSwitchIsLazy() throws {
        let tally = Tally()
        let ast = FormulaAST.function("SWITCH", [
            .number(1),
            .number(1), .number(42),
            .number(2), .function("TALLY", []),
            .function("TALLY", []),
        ])
        XCTAssertEqual(try eval(ast, tally), .number(42))
        XCTAssertEqual(tally.count, 0)
    }

    /// Text matching is case-insensitive, as comparison is everywhere in Excel.
    func testSwitchMatchesTextWithoutCase() throws {
        let ast = FormulaAST.function("SWITCH", [
            .text("Red"), .text("RED"), .number(1), .number(0),
        ])
        XCTAssertEqual(try eval(ast), .number(1))
    }

    // MARK: - XOR

    func testXorIsTrueForAnOddNumberOfTruths() throws {
        XCTAssertEqual(try eval(.function("XOR", [.bool(true), .bool(false)])), .bool(true))
        XCTAssertEqual(try eval(.function("XOR", [.bool(true), .bool(true)])), .bool(false))
        XCTAssertEqual(
            try eval(.function("XOR", [.bool(true), .bool(true), .bool(true)])), .bool(true))
        XCTAssertEqual(try eval(.function("XOR", [.bool(false), .bool(false)])), .bool(false))
    }

    /// Numbers count as truthy, and zero does not.
    func testXorCoercesLikeItsSiblings() throws {
        XCTAssertEqual(try eval(.function("XOR", [.number(1), .number(0)])), .bool(true))
        XCTAssertEqual(try eval(.function("XOR", [.number(3), .number(7)])), .bool(false))
    }

    func testXorPropagatesAnError() throws {
        XCTAssertEqual(try eval(.function("XOR", [.bool(true), .error(.na)])), .error(.na))
    }
}
