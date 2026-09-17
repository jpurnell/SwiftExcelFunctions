import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// What the evaluator counts, and where it stops.
///
/// These are the numbers `project/docs/technical/ExcelEvaluationLimits.md` measured against
/// Excel 16.114 over five conformance rounds, and they replace a single `maxDepth = 256`
/// incremented once per AST node — which was wrong three ways at once: an order of magnitude
/// off, counting the wrong thing, and conflating two budgets Excel keeps apart.
///
/// | | Excel | was |
/// |---|---|---|
/// | Expression nesting | **65 function calls** | 256 AST nodes |
/// | `LAMBDA` recursion | **4,096 calls** | the same counter |
/// | Are they one budget? | **no, two counters** | one |
///
/// The recursion half has nothing to count yet — `LAMBDA` is not implemented — so the bound
/// is stated here and tested where it is used. What this file pins is the nesting bound and,
/// more importantly, **what a nesting level is**.
final class EvaluationDepthTests: XCTestCase {

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

    private let cells = Cells()
    private let names = Names()

    private func eval(_ ast: FormulaAST) throws -> CellValue {
        try FormulaEvaluator.evaluate(ast, cells: cells, names: names, functions: .builtin)
    }

    /// `IF(TRUE, IF(TRUE, … , d), 0)` nested *n* calls deep.
    private func nestedCalls(_ depth: Int) -> FormulaAST {
        var ast = FormulaAST.number(0)
        for _ in 0..<depth {
            ast = .function("IF", [.bool(true), ast, .number(-1)])
        }
        return ast
    }

    // MARK: - The measured bound

    /// 65 is the measured limit and the bracket has no slack in it.
    ///
    /// Excel kept the cells asking for 2, 8, 32, 60, 62, 63, 64 and 65, and deleted exactly
    /// those asking for 66, 70, 100 and 128 — at *file load*, reporting the workbook as
    /// damaged rather than evaluating anything.
    func testSixtyFiveNestedCallsEvaluate() throws {
        XCTAssertEqual(try eval(nestedCalls(65)), .number(0))
    }

    /// 66 is refused, as it is by Excel — though not in the same manner, which it cannot be.
    ///
    /// Excel refuses the *file*: it deletes the cell and shows a repair dialog. An evaluator
    /// has nothing to delete, so the honest analogue is to refuse the formula and let the
    /// caller decide. A file arriving with 66-deep nesting was written by something that is
    /// not Excel.
    func testSixtySixNestedCallsAreRefused() {
        XCTAssertThrowsError(try eval(nestedCalls(66))) { error in
            XCTAssertEqual(error as? FormulaEvaluator.EvaluationError, .callDepthExceeded)
        }
    }

    // MARK: - What a nesting level *is*

    /// Operators are not function calls, and Excel does not count them.
    ///
    /// This is the half the old counter got most wrong. `A1+A2+…` a few hundred terms long is
    /// an ordinary thing to find in a real sheet — it is one expression, not nesting — and
    /// Excel's own limit on it is the 8,192-character formula length, not the 64 nested
    /// levels. Counting AST nodes refused it at 256, so the evaluator was **wrong about
    /// working spreadsheets**, which is the more expensive direction to be wrong in.
    func testALongChainOfOperatorsIsNotNesting() throws {
        var ast = FormulaAST.number(1)
        for _ in 0..<300 { ast = .add(ast, .number(1)) }
        XCTAssertEqual(try eval(ast), .number(301))
    }

    /// Nor is a stack of unary operators.
    func testAStackOfNegationsIsNotNesting() throws {
        var ast = FormulaAST.number(42)
        for _ in 0..<300 { ast = .negate(ast) }
        XCTAssertEqual(try eval(ast), .number(42))
    }

    /// Arguments sit side by side rather than one inside another.
    ///
    /// `SUM(1, 2, 3, …)` with many arguments is one call at one level. A counter that
    /// incremented per node would see the width as depth.
    func testManyArgumentsAreOneLevel() throws {
        let terms = (1...200).map { FormulaAST.number(Double($0)) }
        XCTAssertEqual(try eval(.function("SUM", terms)), .number(20100))
    }

    // MARK: - The bound that is ours rather than Excel's

    /// A formula deeper than any legal Excel formula still has to stop somewhere.
    ///
    /// Excel caps formula *text* at 8,192 characters, and every nesting level costs at least
    /// one character, so nothing Excel can hold reaches that depth. This bound exists only so
    /// that a hand-built AST cannot exhaust the stack, and it is named for what it is rather
    /// than presented as a rule about spreadsheets.
    func testAnAbsurdlyDeepTreeIsRefusedRatherThanCrashing() {
        var ast = FormulaAST.number(1)
        for _ in 0..<(FormulaEvaluator.maxNodeDepth + 10) { ast = .negate(ast) }
        XCTAssertThrowsError(try eval(ast)) { error in
            XCTAssertEqual(error as? FormulaEvaluator.EvaluationError, .nodeDepthExceeded)
        }
    }

    /// The three bounds are the measured ones, and separate.
    func testTheBoundsAreTheMeasuredOnes() {
        XCTAssertEqual(FormulaEvaluator.maxCallDepth, 65)
        XCTAssertEqual(FormulaEvaluator.maxRecursionDepth, 4096)
        XCTAssertNotEqual(FormulaEvaluator.maxCallDepth, FormulaEvaluator.maxRecursionDepth,
                          "Excel keeps two counters and so must this")
    }
}
