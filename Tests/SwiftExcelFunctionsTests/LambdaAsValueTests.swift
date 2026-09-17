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

/// A `LAMBDA` applied where it is written.
///
/// The third of the three corpus shapes, and the last to work. The parser learned it in
/// SwiftXLSX 0.28.0; this is the other half — evaluating what it produces.
final class ImmediatelyInvokedLambdaTests: XCTestCase {

    private struct Cells: CellValueProvider {
        var data: [String: CellValue] = [:]
        func value(at ref: CellRef) -> CellValue? { data[ref.reference] }
        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet sheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { range.cells.compactMap { value(at: $0) } }
        func values(in range: CellRange, inSheet sheet: String) -> [CellValue] { [] }
    }
    private struct Names: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func eval(_ ast: FormulaAST, cells: Cells = Cells()) throws -> CellValue {
        try FormulaEvaluator.evaluate(ast, cells: cells, names: Names(), functions: .builtin)
    }

    private func lambda(_ parameters: [String], _ body: FormulaAST) -> FormulaAST {
        .function("LAMBDA", parameters.map { .namedRange($0) } + [body])
    }

    func testALambdaAppliedWhereItIsWritten() throws {
        let ast = FormulaAST.call(
            lambda(["x"], .multiply(.namedRange("x"), .number(3))), [.number(7)])
        XCTAssertEqual(try eval(ast), .number(21))
    }

    /// Currying, with no name between the two calls.
    func testCallsChain() throws {
        let adder = lambda(["x"], lambda(["y"], .add(.namedRange("x"), .namedRange("y"))))
        XCTAssertEqual(try eval(.call(.call(adder, [.number(3)]), [.number(4)])), .number(7))
    }

    /// **The self-application trick**, which is how a recursive lambda is written with nothing
    /// added to the file — and what measured Excel's recursion limit.
    ///
    /// ```
    /// LAMBDA(f, n, IF(n<=0, 0, 1 + f(f, n-1)))(LAMBDA(f, n, …), 100)
    /// ```
    ///
    /// The body takes *itself* as a parameter and invokes that, so no defined name is needed.
    /// Two conformance rounds were lost to a `depthProbe` nobody had added by hand before this
    /// form removed the precondition altogether.
    func testSelfApplicationRecurses() throws {
        let body = lambda(["f", "n"], .function("IF", [
            .lessOrEqual(.namedRange("n"), .number(0)),
            .number(0),
            .add(.number(1), .call(.namedRange("f"),
                                   [.namedRange("f"),
                                    .subtract(.namedRange("n"), .number(1))])),
        ]))
        XCTAssertEqual(try eval(.call(body, [body, .number(100)])), .number(100))
    }

    /// Calling something that is not a function is `#VALUE!`.
    func testCallingANonFunctionIsRefused() throws {
        XCTAssertEqual(try eval(.call(.number(5), [.number(1)])), .error(.value))
    }

    /// An error in the callee is the answer, and the arguments are not reached.
    func testAnErrorInTheCalleePropagates() throws {
        XCTAssertEqual(try eval(.call(.divide(.number(1), .number(0)), [.number(1)])),
                       .error(.div0))
    }
}
