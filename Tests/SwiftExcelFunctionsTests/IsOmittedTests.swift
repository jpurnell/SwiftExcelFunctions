import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// `ISOMITTED` asks whether a `LAMBDA` argument was supplied.
///
/// Step 5, and the function the information family recorded as out of scope because *"there is
/// no `LAMBDA` yet"*. There is one now.
///
/// It is how an author writes an optional parameter, since Excel has no syntax for one — the
/// `[y]` in Microsoft's documentation is a convention for readers, not something the formula
/// language parses:
///
/// ```
/// LAMBDA(x, y, IF(ISOMITTED(y), x, x + y))
/// ```
///
/// ## What round 6 measured, and what it reversed
///
/// This file first assumed a trailing argument could be left out — `f(5)` where `f` declares
/// two — because Microsoft's documented `ISOMITTED` pattern is unusable otherwise. **Excel
/// refuses it.** A two-parameter lambda called with one argument is `#VALUE!`, and the control
/// beside it answered 2, so the reading means what it says. Sixth time documentation has been
/// wrong here.
///
/// So arity is exact, and the count is of **argument positions**. That is what keeps
/// `ISOMITTED` meaningful: `f(7,)` supplies two positions and leaves the second empty, which
/// is a different thing from `f(7)`. Whether Excel reads *that* as omitted is not yet
/// measured — round 6's row for it asked `f(7,,)`, which is three positions and re-tested the
/// rule above. Round 7 asks it properly.
final class IsOmittedTests: XCTestCase {

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
                      names: Names = Names()) throws -> CellValue {
        try FormulaEvaluator.evaluate(ast, cells: cells, names: names, functions: .builtin)
    }

    /// `plus = LAMBDA(x, y, IF(ISOMITTED(y), x, x + y))`
    private var plus: Names {
        Names(targets: [
            "plus": .formula(.function("LAMBDA", [
                .namedRange("x"), .namedRange("y"),
                .function("IF", [
                    .function("ISOMITTED", [.namedRange("y")]),
                    .namedRange("x"),
                    .add(.namedRange("x"), .namedRange("y")),
                ]),
            ])),
        ])
    }

    // MARK: - Arity is exact

    /// Measured, round 6: a two-parameter lambda called with one argument is `#VALUE!`.
    ///
    /// This asserted the opposite until Excel was asked.
    func testATrailingArgumentMayNotBeLeftOut() throws {
        XCTAssertEqual(try eval(.function("PLUS", [.number(5)]), names: plus), .error(.value))
    }

    func testSupplyingItUsesIt() throws {
        XCTAssertEqual(try eval(.function("PLUS", [.number(5), .number(3)]), names: plus),
                       .number(8))
    }

    // MARK: - A skipped argument

    /// `f(1,,3)` — three positions, the middle one empty. The parser produces `.missing`,
    /// and an empty position is supplied-but-omitted rather than absent.
    ///
    /// **Not yet confirmed against Excel.** Round 6 asked this with `f(7,,)`, which is three
    /// positions against two parameters and therefore measured the arity rule instead. Round 7
    /// asks it with the right number of positions.
    func testASkippedArgumentIsOmitted() throws {
        let names = Names(targets: [
            "pick": .formula(.function("LAMBDA", [
                .namedRange("a"), .namedRange("b"), .namedRange("c"),
                .function("IF", [
                    .function("ISOMITTED", [.namedRange("b")]),
                    .text("no b"),
                    .namedRange("b"),
                ]),
            ])),
        ])
        XCTAssertEqual(
            try eval(.function("PICK", [.number(1), .missing, .number(3)]), names: names),
            .text("no b"))
        XCTAssertEqual(
            try eval(.function("PICK", [.number(1), .number(2), .number(3)]), names: names),
            .number(2))
    }

    // MARK: - What it is not

    /// A supplied argument is not omitted, whatever it holds.
    ///
    /// A blank cell is the case that matters: `f(A1)` with `A1` empty passes a blank, and a
    /// blank is a value. An implementation that marked omission by binding blank could not
    /// tell the two apart, and would report an argument the author wrote as absent.
    func testABlankArgumentIsSuppliedNotOmitted() throws {
        let names = Names(targets: [
            "isit": .formula(.function("LAMBDA", [
                .namedRange("v"), .function("ISOMITTED", [.namedRange("v")]),
            ])),
        ])
        let cells = Cells(data: [:])
        XCTAssertEqual(try eval(.function("ISIT", [.cellRef(CellRef("A1"))]),
                                cells: cells, names: names), .bool(false),
                       "an empty cell was still passed")
        XCTAssertEqual(try eval(.function("ISIT", [.missing]), names: names), .bool(true),
                       "an empty *position* is the omission")
    }

    /// An omitted parameter reads as blank where it is used as a value.
    func testAnOmittedParameterIsBlankWhenRead() throws {
        let names = Names(targets: [
            "total": .formula(.function("LAMBDA", [
                .namedRange("a"), .namedRange("b"),
                .add(.namedRange("a"), .namedRange("b")),
            ])),
        ])
        XCTAssertEqual(try eval(.function("TOTAL", [.number(7), .missing]), names: names),
                       .number(7))
    }

    /// Asking about something that is not a parameter is `FALSE`, not an error.
    func testAskingAboutAValueIsFalse() throws {
        XCTAssertEqual(try eval(.function("ISOMITTED", [.number(1)])), .bool(false))
        XCTAssertEqual(try eval(.function("ISOMITTED", [.text("x")])), .bool(false))
    }

    /// Outside a `LAMBDA` there are no parameters, so nothing is omitted.
    func testOutsideALambdaNothingIsOmitted() throws {
        XCTAssertEqual(try eval(.function("ISOMITTED", [.namedRange("whatever")])),
                       .bool(false))
    }

    // MARK: - Arity

    /// Measured, round 6: too many arguments is `#VALUE!`.
    func testMoreArgumentsThanParametersIsRefused() throws {
        XCTAssertEqual(
            try eval(.function("PLUS", [.number(1), .number(2), .number(3)]), names: plus),
            .error(.value))
    }

    /// Omission does not leak out of the call that made it.
    func testOmissionDoesNotEscape() throws {
        let names = Names(targets: [
            "outer": .formula(.function("LAMBDA", [
                .namedRange("p"),
                .function("IF", [
                    .function("ISOMITTED", [.namedRange("p")]),
                    .function("INNER", [.number(1)]),
                    .text("supplied"),
                ]),
            ])),
            "inner": .formula(.function("LAMBDA", [
                .namedRange("p"), .function("ISOMITTED", [.namedRange("p")]),
            ])),
        ])
        XCTAssertEqual(try eval(.function("OUTER", [.missing]), names: names), .bool(false),
                       "inner's p was supplied, whatever outer's p was")
    }
}
