import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// A `LAMBDA` that is not called is a value, and Excel says so.
///
/// Step 4 of the proposal, and the one that took a source-breaking change to a shared package.
/// The three shapes it exists for are all legal Excel and were all unreachable before:
///
/// ```
/// LAMBDA(x, LAMBDA(y, x+y))     returned by a lambda
/// LET(f, LAMBDA(x, x*2), f(3))  bound to a name
/// IF(flag, LAMBDA(x,x), …)      chosen by a formula
/// ```
///
/// Each would otherwise evaluate to something plausible rather than to an error — which is
/// the failure a workbook checker cannot afford, since it reports on other people's files.
final class LambdaAsValueTests: XCTestCase {

    private struct Cells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet sheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet sheet: String) -> [CellValue] { [] }
    }
    private struct Names: NameResolver {
        var targets: [String: NamedRangeTarget] = [:]
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? {
            targets[name.lowercased()]
        }
    }

    private func eval(_ ast: FormulaAST, names: Names = Names()) throws -> CellValue {
        try FormulaEvaluator.evaluate(ast, cells: Cells(), names: names, functions: .builtin)
    }

    // MARK: - A lambda is a value

    func testAnUncalledLambdaEvaluatesToALambda() throws {
        let result = try eval(.function("LAMBDA", [
            .namedRange("x"), .add(.namedRange("x"), .number(1)),
        ]))
        guard case .lambda(let parameters, _, _) = result else {
            return XCTFail("expected a lambda, got \(result)")
        }
        XCTAssertEqual(parameters, ["x"])
    }

    /// In a cell, that value shows as `#CALC!` — a function where a value belongs.
    func testALambdaUsedAsANumberIsCalc() throws {
        let sum = FormulaAST.add(
            .function("LAMBDA", [.namedRange("x"), .namedRange("x")]), .number(1))
        XCTAssertEqual(try eval(sum), .error(.calc))
    }

    /// `#CALC!` and not `#VALUE!`, which is a different mistake.
    ///
    /// `=myLambda + 1` has not used the wrong *kind* of value; it has forgotten to call
    /// something. Excel draws that distinction and so does this.
    func testItIsCalcRatherThanValue() throws {
        let wrongKind = FormulaAST.add(.text("banana"), .number(1))
        XCTAssertEqual(try eval(wrongKind), .error(.value))

        let uncalled = FormulaAST.add(
            .function("LAMBDA", [.namedRange("x"), .namedRange("x")]), .number(1))
        XCTAssertEqual(try eval(uncalled), .error(.calc))
    }

    func testALambdaConcatenatedIsCalc() throws {
        let joined = FormulaAST.concatenate(
            .text("f="), .function("LAMBDA", [.namedRange("x"), .namedRange("x")]))
        XCTAssertEqual(try eval(joined), .text("f=#CALC!"))
    }

    // MARK: - The three shapes

    /// Bound by a `LET`, then called.
    func testALambdaBoundByLetCanBeCalled() throws {
        let ast = FormulaAST.function("LET", [
            .namedRange("double"),
            .function("LAMBDA", [.namedRange("x"), .multiply(.namedRange("x"), .number(2))]),
            .function("DOUBLE", [.number(21)]),
        ])
        XCTAssertEqual(try eval(ast), .number(42))
    }

    /// Chosen by an `IF`, then called.
    func testALambdaChosenByAnIfCanBeCalled() throws {
        let ast = FormulaAST.function("LET", [
            .namedRange("f"),
            .function("IF", [
                .bool(true),
                .function("LAMBDA", [.namedRange("x"), .multiply(.namedRange("x"), .number(10))]),
                .function("LAMBDA", [.namedRange("x"), .number(0)]),
            ]),
            .function("F", [.number(4)]),
        ])
        XCTAssertEqual(try eval(ast), .number(40))
    }

    /// **Returned by a lambda, which is what `captured` is for.**
    ///
    /// `LET(add, LAMBDA(x, LAMBDA(y, x+y)), LET(add3, add(3), add3(4)))` is 7. The inner
    /// lambda escapes the scope that gave `x` its value, so it has to carry `x` with it. A
    /// lambda without a captured frame does not fail here — it answers `#NAME?` or, worse,
    /// finds a workbook name called `x` and returns a plausible number.
    func testALambdaReturnedByALambdaRemembersItsScope() throws {
        let adder = FormulaAST.function("LAMBDA", [
            .namedRange("x"),
            .function("LAMBDA", [
                .namedRange("y"), .add(.namedRange("x"), .namedRange("y")),
            ]),
        ])
        let ast = FormulaAST.function("LET", [
            .namedRange("add"), adder,
            .function("LET", [
                .namedRange("add3"), .function("ADD", [.number(3)]),
                .function("ADD3", [.number(4)]),
            ]),
        ])
        XCTAssertEqual(try eval(ast), .number(7))
    }

    /// The captured value is the one from the scope that made the lambda, not the caller's.
    func testTheCapturedValueWinsOverTheCallersName() throws {
        let ast = FormulaAST.function("LET", [
            .namedRange("x"), .number(100),
            .function("LET", [
                .namedRange("f"),
                .function("LET", [
                    .namedRange("x"), .number(1),
                    .function("LAMBDA", [.namedRange("y"), .add(.namedRange("x"),
                                                                .namedRange("y"))]),
                ]),
                .function("F", [.number(0)]),
            ]),
        ])
        XCTAssertEqual(try eval(ast), .number(1), "the lambda closed over x = 1, not x = 100")
    }

    // MARK: - Arity

    func testCallingWithTheWrongCountIsRefused() throws {
        let ast = FormulaAST.function("LET", [
            .namedRange("f"),
            .function("LAMBDA", [.namedRange("x"), .namedRange("x")]),
            .function("F", [.number(1), .number(2)]),
        ])
        XCTAssertEqual(try eval(ast), .error(.value))
    }

    /// A `LAMBDA` with no body is not a lambda.
    func testALambdaNeedsABody() throws {
        XCTAssertEqual(try eval(.function("LAMBDA", [])), .error(.calc))
    }

    /// A parameter list with something other than a name in it is malformed.
    func testAParameterMustBeAName() throws {
        XCTAssertEqual(
            try eval(.function("LAMBDA", [.number(1), .number(2)])), .error(.calc))
    }
}
