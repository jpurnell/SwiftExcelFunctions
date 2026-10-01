import Foundation
import Testing
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
@Suite struct LambdaAsValueTests {

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

    @Test func anUncalledLambdaEvaluatesToALambda() throws {
        let result = try eval(.function("LAMBDA", [
            .namedRange("x"), .add(.namedRange("x"), .number(1)),
        ]))
        guard case .lambda(let parameters, _, _) = result else {
            Issue.record("expected a lambda, got \(result)"); return
        }
        #expect(parameters == ["x"])
    }

    /// In a cell, that value shows as `#CALC!` — a function where a value belongs.
    @Test func aLambdaUsedAsANumberIsCalc() throws {
        let sum = FormulaAST.add(
            .function("LAMBDA", [.namedRange("x"), .namedRange("x")]), .number(1))
        #expect(try eval(sum) == .error(.calc))
    }

    /// `#CALC!` and not `#VALUE!`, which is a different mistake.
    ///
    /// `=myLambda + 1` has not used the wrong *kind* of value; it has forgotten to call
    /// something. Excel draws that distinction and so does this.
    @Test func itIsCalcRatherThanValue() throws {
        let wrongKind = FormulaAST.add(.text("banana"), .number(1))
        #expect(try eval(wrongKind) == .error(.value))

        let uncalled = FormulaAST.add(
            .function("LAMBDA", [.namedRange("x"), .namedRange("x")]), .number(1))
        #expect(try eval(uncalled) == .error(.calc))
    }

    @Test func aLambdaConcatenatedIsCalc() throws {
        let joined = FormulaAST.concatenate(
            .text("f="), .function("LAMBDA", [.namedRange("x"), .namedRange("x")]))
        #expect(try eval(joined) == .text("f=#CALC!"))
    }

    // MARK: - The three shapes

    /// Bound by a `LET`, then called.
    @Test func aLambdaBoundByLetCanBeCalled() throws {
        let ast = FormulaAST.function("LET", [
            .namedRange("double"),
            .function("LAMBDA", [.namedRange("x"), .multiply(.namedRange("x"), .number(2))]),
            .function("DOUBLE", [.number(21)]),
        ])
        #expect(try eval(ast) == .number(42))
    }

    /// Chosen by an `IF`, then called.
    @Test func aLambdaChosenByAnIfCanBeCalled() throws {
        let ast = FormulaAST.function("LET", [
            .namedRange("f"),
            .function("IF", [
                .bool(true),
                .function("LAMBDA", [.namedRange("x"), .multiply(.namedRange("x"), .number(10))]),
                .function("LAMBDA", [.namedRange("x"), .number(0)]),
            ]),
            .function("F", [.number(4)]),
        ])
        #expect(try eval(ast) == .number(40))
    }

    /// **Returned by a lambda, which is what `captured` is for.**
    ///
    /// `LET(add, LAMBDA(x, LAMBDA(y, x+y)), LET(add3, add(3), add3(4)))` is 7. The inner
    /// lambda escapes the scope that gave `x` its value, so it has to carry `x` with it. A
    /// lambda without a captured frame does not fail here — it answers `#NAME?` or, worse,
    /// finds a workbook name called `x` and returns a plausible number.
    @Test func aLambdaReturnedByALambdaRemembersItsScope() throws {
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
        #expect(try eval(ast) == .number(7))
    }

    /// The captured value is the one from the scope that made the lambda, not the caller's.
    @Test func theCapturedValueWinsOverTheCallersName() throws {
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
        #expect(try eval(ast) == .number(1), "the lambda closed over x = 1, not x = 100")
    }

    // MARK: - Arity

    @Test func callingWithTheWrongCountIsRefused() throws {
        let ast = FormulaAST.function("LET", [
            .namedRange("f"),
            .function("LAMBDA", [.namedRange("x"), .namedRange("x")]),
            .function("F", [.number(1), .number(2)]),
        ])
        #expect(try eval(ast) == .error(.value))
    }

    /// A `LAMBDA` with no body is not a lambda.
    @Test func aLambdaNeedsABody() throws {
        #expect(try eval(.function("LAMBDA", [])) == .error(.calc))
    }

    /// A parameter list with something other than a name in it is malformed.
    @Test func aParameterMustBeAName() throws {
        #expect(try eval(.function("LAMBDA", [.number(1), .number(2)])) == .error(.calc))
    }
}

/// A `LAMBDA` applied where it is written.
///
/// The third of the three corpus shapes, and the last to work. The parser learned it in
/// SwiftXLSX 0.28.0; this is the other half — evaluating what it produces.
@Suite struct ImmediatelyInvokedLambdaTests {

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

    @Test func aLambdaAppliedWhereItIsWritten() throws {
        let ast = FormulaAST.call(
            lambda(["x"], .multiply(.namedRange("x"), .number(3))), [.number(7)])
        #expect(try eval(ast) == .number(21))
    }

    /// Currying, with no name between the two calls.
    @Test func callsChain() throws {
        let adder = lambda(["x"], lambda(["y"], .add(.namedRange("x"), .namedRange("y"))))
        #expect(try eval(.call(.call(adder, [.number(3)]), [.number(4)])) == .number(7))
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
    @Test func selfApplicationRecurses() async throws {
        let body = lambda(["f", "n"], .function("IF", [
            .lessOrEqual(.namedRange("n"), .number(0)),
            .number(0),
            .add(.number(1), .call(.namedRange("f"),
                                   [.namedRange("f"),
                                    .subtract(.namedRange("n"), .number(1))])),
        ]))
        #expect(try await onMeasuredStack { try eval(.call(body, [body, .number(100)])) } == .number(100))
    }

    /// Calling something that is not a function is `#VALUE!`.
    @Test func callingANonFunctionIsRefused() throws {
        #expect(try eval(.call(.number(5), [.number(1)])) == .error(.value))
    }

    /// An error in the callee is the answer, and the arguments are not reached.
    @Test func anErrorInTheCalleePropagates() throws {
        #expect(try eval(.call(.divide(.number(1), .number(0)), [.number(1)])) == .error(.div0))
    }
}
