import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// A name that holds a `LAMBDA` can be called.
///
/// This is the shape the corpus actually contains: a defined name whose refers-to is
/// `_xlfn.LAMBDA(_xlpm.arr, _xlpm.y, MAX(_xlpm.arr)^_xlpm.y)`, and cells that say
/// `=maxEXP(B2:B9, 2)`. The parser already reads both halves; what was missing was the step
/// between them — a call whose name the registry does not know is not necessarily unknown.
///
/// ## Where the text becomes a tree
///
/// Not here. This package takes a `NameResolver` and has no parser: SwiftXLSX depends on
/// SwiftExcelCore and so does this, as siblings, and reaching sideways for a parser to make
/// `LAMBDA` work would be the wrong repair to the wrong problem.
///
/// The reader stores a lambda as ``NamedRangeTarget/unparsed(_:)`` — its own text, which is
/// what made 161,901 names round-trip unchanged — so a consumer that wants a callable lambda
/// resolves that text to ``NamedRangeTarget/formula(_:)`` at evaluation time, where it has a
/// parser and this package does not. The storage form is untouched by that, which is the
/// point of doing it at use.
final class NamedLambdaTests: XCTestCase {

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
        var targets: [String: NamedRangeTarget] = [:]
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? {
            targets[name.lowercased()]
        }
    }

    private func eval(_ ast: FormulaAST, cells: Cells = Cells(),
                      names: Names) throws -> CellValue {
        try FormulaEvaluator.evaluate(ast, cells: cells, names: names, functions: .builtin)
    }

    /// `LAMBDA(p…, body)` as the parser produces it.
    private func lambda(_ parameters: [String], _ body: FormulaAST) -> NamedRangeTarget {
        .formula(.function("LAMBDA", parameters.map { .namedRange($0) } + [body]))
    }

    // MARK: - Calling one

    func testANamedLambdaIsCalled() throws {
        let names = Names(targets: [
            "increment": lambda(["x"], .add(.namedRange("x"), .number(1))),
        ])
        XCTAssertEqual(try eval(.function("INCREMENT", [.number(5)]), names: names), .number(6))
    }

    /// The shape from the corpus, prefixes and all.
    func testTheCorpusShape() throws {
        let names = Names(targets: [
            "maxexp": .formula(.function("_XLFN.LAMBDA", [
                .namedRange("_xlpm.arr"), .namedRange("_xlpm.y"),
                .power(.function("MAX", [.namedRange("_xlpm.arr")]), .namedRange("_xlpm.y")),
            ])),
        ])
        let cells = Cells(data: ["B1": .number(2), "B2": .number(5), "B3": .number(3)])
        let call = FormulaAST.function("maxEXP", [
            .cellRange(CellRange(from: "B1", to: "B3")), .number(2),
        ])
        XCTAssertEqual(try eval(call, cells: cells, names: names), .number(25))
    }

    func testTwoParameters() throws {
        let names = Names(targets: [
            "hyp": lambda(["a", "b"], .function("SQRT", [
                .add(.power(.namedRange("a"), .number(2)),
                     .power(.namedRange("b"), .number(2))),
            ])),
        ])
        XCTAssertEqual(try eval(.function("HYP", [.number(3), .number(4)]), names: names),
                       .number(5))
    }

    func testNoParameters() throws {
        let names = Names(targets: ["answer": lambda([], .number(42))])
        XCTAssertEqual(try eval(.function("ANSWER", []), names: names), .number(42))
    }

    // MARK: - Scope

    /// A parameter shadows a workbook name, and only inside the body.
    func testAParameterShadowsAWorkbookName() throws {
        let names = Names(targets: [
            "rate": .cell(CellRef("A1")),
            "twice": lambda(["rate"], .multiply(.namedRange("rate"), .number(2))),
        ])
        let cells = Cells(data: ["A1": .number(100)])

        XCTAssertEqual(try eval(.function("TWICE", [.number(7)]), cells: cells, names: names),
                       .number(14))
        XCTAssertEqual(try eval(.namedRange("rate"), cells: cells, names: names), .number(100))
    }

    /// The body still reaches names it did not bind.
    func testTheBodySeesTheWorkbook() throws {
        let names = Names(targets: [
            "rate": .cell(CellRef("A1")),
            "grossed": lambda(["net"], .multiply(.namedRange("net"),
                                                 .add(.number(1), .namedRange("rate")))),
        ])
        // 0.25 rather than 0.1 on purpose. `200 * 1.1` is 220.00000000000003 in binary
        // floating point, and Excel hides that with its final-operation rounding — which this
        // package applies to the *outermost* operation only. Whether that rounding should see
        // through a lambda call, so that `=grossed(200)` displays 220, is a real question and
        // an unmeasured one; it is not what this test is about, so the arithmetic is chosen
        // to be exact and the question is written down instead.
        let cells = Cells(data: ["A1": .number(0.25)])
        XCTAssertEqual(try eval(.function("GROSSED", [.number(200)]), cells: cells, names: names),
                       .number(250))
    }

    /// Arguments are evaluated in the caller's scope, not the body's.
    func testArgumentsAreEvaluatedOutside() throws {
        let names = Names(targets: [
            "x": .cell(CellRef("A1")),
            "double": lambda(["x"], .multiply(.namedRange("x"), .number(2))),
        ])
        let cells = Cells(data: ["A1": .number(5)])
        // The argument `x` is the workbook's; the parameter `x` is what the body sees.
        XCTAssertEqual(try eval(.function("DOUBLE", [.namedRange("x")]),
                                cells: cells, names: names), .number(10))
    }

    // MARK: - Recursion

    /// Recursion by name, which is how a spreadsheet author writes a loop.
    func testALambdaCanCallItself() throws {
        let names = Names(targets: [
            "fact": lambda(["n"], .function("IF", [
                .lessOrEqual(.namedRange("n"), .number(1)),
                .number(1),
                .multiply(.namedRange("n"),
                          .function("FACT_", [.subtract(.namedRange("n"), .number(1))])),
            ])),
        ])
        // Named `FACT_` in the body so it does not collide with the builtin `FACT`.
        var targets = names.targets
        targets["fact_"] = targets["fact"]
        XCTAssertEqual(try eval(.function("FACT_", [.number(5)]),
                                names: Names(targets: targets)), .number(120))
    }

    /// Recursion works to the depth this evaluator's **stack** allows, which is not Excel's.
    ///
    /// Excel's measured bound is 4,096 invocations and ``FormulaEvaluator/maxRecursionDepth``
    /// holds it. In practice a different bound arrives first: `evaluateNode` recurses, so
    /// every lambda level costs several stack frames, and ``FormulaEvaluator/maxNodeDepth``
    /// — the stack guard, measured at 512 — is reached at about **160 levels**.
    ///
    /// That gap is real and is this evaluator's design rather than a defect in it. Closing it
    /// needs an explicit stack in `evaluateNode` instead of Swift's, which is a rewrite of the
    /// evaluator's core and not a larger constant: the constant was already measured against
    /// the stack, and raising it past what the stack holds produces `SIGSEGV` instead of a
    /// refusal. A caller that needs more today can run the evaluation on a thread with a
    /// larger stack, which is the same fix bought cheaply.
    ///
    /// What matters for correctness is that the limit is **reported, not crashed into**, and
    /// that the two budgets stay separate — a recursion 4,090 deep must not be refused for
    /// exhausting a 65-call nesting budget, which is what would happen if a lambda call
    /// counted as nesting.
    func testRecursionWorksToTheDepthTheStackAllows() throws {
        let names = Names(targets: [
            "countdown": lambda(["n"], .function("IF", [
                .lessOrEqual(.namedRange("n"), .number(0)),
                .number(0),
                .add(.number(1),
                     .function("COUNTDOWN", [.subtract(.namedRange("n"), .number(1))])),
            ])),
        ])
        // Far past the 65-call nesting budget, which proves the budgets are separate: each
        // level is a function call, and counting them as nesting would refuse this at 33.
        XCTAssertEqual(try eval(.function("COUNTDOWN", [.number(100)]), names: names),
                       .number(100))
    }

    /// Deeper than the stack allows is refused rather than crashed into.
    func testTooDeepIsRefusedRatherThanCrashing() throws {
        let names = Names(targets: [
            "countdown": lambda(["n"], .function("IF", [
                .lessOrEqual(.namedRange("n"), .number(0)),
                .number(0),
                .add(.number(1),
                     .function("COUNTDOWN", [.subtract(.namedRange("n"), .number(1))])),
            ])),
        ])
        XCTAssertThrowsError(try eval(.function("COUNTDOWN", [.number(10_000)]), names: names)) {
            XCTAssertEqual($0 as? FormulaEvaluator.EvaluationError, .nodeDepthExceeded,
                           "the stack guard, not Excel's recursion bound, is what bites first")
        }
    }

    /// The refusal is not something a formula can trap, because in Excel it is not.
    ///
    /// `IFERROR` sits on the same stack that ran out, so it never gets the chance to handle
    /// anything. An evaluator that routed the refusal through its own error handling would be
    /// **more forgiving than Excel**, and a formula would recover here where the real thing
    /// does not — the subtlest of the measured findings and the easiest to get wrong by being
    /// helpful. It travels as a thrown error for exactly that reason: `IFERROR`'s lazy path
    /// evaluates its first argument with `try`, so the throw goes straight past it.
    func testTheRefusalIsNotCatchable() throws {
        let names = Names(targets: [
            "forever": lambda(["n"], .add(.number(1), .function("FOREVER", [.namedRange("n")]))),
        ])
        let guarded = FormulaAST.function("IFERROR", [
            .function("FOREVER", [.number(1)]), .text("caught"),
        ])
        XCTAssertThrowsError(try eval(guarded, names: names)) { error in
            XCTAssertNotNil(error as? FormulaEvaluator.EvaluationError)
        }
    }

    // MARK: - Malformed

    /// Arity is exact, measured against Excel in conformance round 6.
    ///
    /// This test has now been written three ways, which is worth leaving visible. It first
    /// asserted that too few arguments was `#VALUE!` — correct, by luck, since nothing had
    /// been measured. `ISOMITTED` then reversed it on the strength of Microsoft's documented
    /// pattern being unusable otherwise. Round 6 asked Excel: a two-parameter lambda called
    /// with one argument is `#VALUE!`, with the two-argument control beside it answering 2.
    ///
    /// The original assertion was right and the reasoning that overturned it was documentation.
    /// Sixth time that has happened here.
    func testArityIsExact() throws {
        let names = Names(targets: [
            "hyp": lambda(["a", "b"], .add(.namedRange("a"), .namedRange("b"))),
        ])
        XCTAssertEqual(try eval(.function("HYP", [.number(3)]), names: names), .error(.value))
        XCTAssertEqual(try eval(.function("HYP", [.number(3), .number(4), .number(5)]),
                                names: names), .error(.value))
        XCTAssertEqual(try eval(.function("HYP", [.number(3), .number(4)]), names: names),
                       .number(7))
    }

    /// A name that is not a lambda is still not a function.
    ///
    /// `#NAME?` rather than a thrown error since the corpus run: an unknown name is a value
    /// Excel hands back, not a failure that destroys the formula around it.
    func testANameHoldingSomethingElseIsStillUnknown() throws {
        let names = Names(targets: ["taxrate": .cell(CellRef("A1"))])
        XCTAssertEqual(try eval(.function("TAXRATE", [.number(1)]), names: names), .error(.name))
        XCTAssertEqual(try eval(.function("NOSUCHNAME", [.number(1)]), names: names),
                       .error(.name))
    }

    /// A registered function wins over a name that shares its spelling.
    ///
    /// Excel resolves a call to the built-in first, and a workbook cannot define a name that
    /// shadows `SUM`. Checking the registry first is what makes that true here.
    func testTheRegistryWinsOverAName() throws {
        let names = Names(targets: ["sum": lambda(["x"], .number(-1))])
        XCTAssertEqual(try eval(.function("SUM", [.number(1), .number(2)]), names: names),
                       .number(3))
    }
}
