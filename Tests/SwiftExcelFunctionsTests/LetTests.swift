import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// `LET` names a value so a formula can say it once.
///
/// The first of the two binding forms, and the one that carries no new `CellValue` case with
/// it. `LET(name, value, …, calculation)` binds each name to its value in order and evaluates
/// the calculation with all of them in scope.
///
/// It cannot be an ordinary registered function, because an ordinary function has its
/// arguments evaluated before it is called and the calculation references names that do not
/// exist until `LET` creates them. So the evaluator reaches it before evaluation, as it does
/// the branching forms.
final class LetTests: XCTestCase {

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

    private func eval(_ ast: FormulaAST,
                      cells: Cells = Cells(),
                      names: Names = Names()) throws -> CellValue {
        try FormulaEvaluator.evaluate(ast, cells: cells, names: names, functions: .builtin)
    }

    private func name(_ text: String) -> FormulaAST { .namedRange(text) }

    // MARK: - The basics

    /// `LET(a, 2, a*3)` → 6.
    func testOneBinding() throws {
        let ast = FormulaAST.function("LET", [
            name("a"), .number(2),
            .multiply(name("a"), .number(3)),
        ])
        XCTAssertEqual(try eval(ast), .number(6))
    }

    /// Excel writes the `_xlpm.` prefix on every declared name and on every use of it.
    ///
    /// Binding is by the spelling the form declares, whatever that spelling is — which makes
    /// the prefix travel through without needing to be understood. Depending on it would be
    /// the mistake: a file from LibreOffice or a hand-built fixture may not write it.
    func testTheParameterPrefixIsJustPartOfTheName() throws {
        let ast = FormulaAST.function("_xlfn.LET", [
            name("_xlpm.a"), .number(2),
            .multiply(name("_xlpm.a"), .number(3)),
        ])
        XCTAssertEqual(try eval(ast), .number(6))
    }

    /// Several names, and a later value may use an earlier name.
    func testBindingsAreVisibleToLaterBindings() throws {
        let ast = FormulaAST.function("LET", [
            name("a"), .number(2),
            name("b"), .multiply(name("a"), .number(5)),
            .add(name("a"), name("b")),
        ])
        XCTAssertEqual(try eval(ast), .number(12))
    }

    /// A name is not visible to the value it is being bound to.
    ///
    /// `LET(a, a+1, a)` asks for `a` before there is one. Excel answers `#NAME?`, and the
    /// alternative — seeing the binding under construction — is how a self-reference becomes
    /// an infinite loop instead of an error.
    func testANameCannotSeeItself() throws {
        let ast = FormulaAST.function("LET", [
            name("a"), .add(name("a"), .number(1)),
            name("a"),
        ])
        XCTAssertEqual(try eval(ast), .error(.name))
    }

    // MARK: - Scope

    /// A binding shadows a workbook name, and only inside.
    func testABindingShadowsAWorkbookName() throws {
        let names = Names(targets: ["rate": .cell(CellRef("A1"))])
        let cells = Cells(data: ["A1": .number(100)])

        XCTAssertEqual(try eval(name("rate"), cells: cells, names: names), .number(100))

        let shadowed = FormulaAST.function("LET", [name("rate"), .number(7), name("rate")])
        XCTAssertEqual(try eval(shadowed, cells: cells, names: names), .number(7))
    }

    /// Outside the `LET`, the workbook name is itself again.
    func testTheBindingDoesNotEscape() throws {
        let names = Names(targets: ["rate": .cell(CellRef("A1"))])
        let cells = Cells(data: ["A1": .number(100)])

        let ast = FormulaAST.add(
            .function("LET", [name("rate"), .number(7), name("rate")]),
            name("rate"))
        XCTAssertEqual(try eval(ast, cells: cells, names: names), .number(107))
    }

    /// An inner `LET` shadows an outer one, and the outer binding survives it.
    func testNestedLetShadowsAndRestores() throws {
        let ast = FormulaAST.function("LET", [
            name("a"), .number(1),
            .add(
                .function("LET", [name("a"), .number(10), name("a")]),
                name("a")),
        ])
        XCTAssertEqual(try eval(ast), .number(11))
    }

    /// A name still resolves to the workbook when no binding covers it.
    func testUnboundNamesStillReachTheWorkbook() throws {
        let names = Names(targets: ["rate": .cell(CellRef("A1"))])
        let cells = Cells(data: ["A1": .number(100)])

        let ast = FormulaAST.function("LET", [
            name("a"), .number(2), .multiply(name("a"), name("rate")),
        ])
        XCTAssertEqual(try eval(ast, cells: cells, names: names), .number(200))
    }

    // MARK: - Malformed

    /// `LET` takes name/value pairs and then a calculation, so the count is always odd.
    func testAnEvenArgumentCountIsRefused() throws {
        let ast = FormulaAST.function("LET", [name("a"), .number(2), name("b"), .number(3)])
        XCTAssertEqual(try eval(ast), .error(.value))
    }

    /// Fewer than three arguments is not a `LET` at all.
    func testTooFewArgumentsIsAnArityError() {
        XCTAssertThrowsError(try eval(.function("LET", [name("a"), .number(1)])))
    }

    /// The thing being named has to be a name.
    func testANonNameInTheNamePositionIsRefused() throws {
        let ast = FormulaAST.function("LET", [.number(1), .number(2), .number(3)])
        XCTAssertEqual(try eval(ast), .error(.value))
    }

    /// A binding holds whatever a cell holds, arrays included.
    func testABindingCanHoldARange() throws {
        let cells = Cells(data: ["A1": .number(1), "A2": .number(2), "A3": .number(3)])
        let ast = FormulaAST.function("LET", [
            name("xs"), .cellRange(CellRange(from: "A1", to: "A3")),
            .function("SUM", [name("xs")]),
        ])
        XCTAssertEqual(try eval(ast, cells: cells), .number(6))
    }

    /// A bound value is computed once, not once per mention.
    ///
    /// This is most of the reason `LET` exists — an author writes it to stop repeating an
    /// expensive subexpression — and evaluating the value at each use would be a `LET` that
    /// costs more than not using it.
    func testABoundValueIsEvaluatedOnce() throws {
        // Justification: reached only from one synchronous evaluation, on one thread.
        final class Tally: @unchecked Sendable {
            private(set) var count = 0
            func hit() { count += 1 }
        }
        let tally = Tally()
        var registry = FunctionRegistry.builtin
        registry.register(ExcelFunction(name: "TALLY", minArgs: 0, maxArgs: 0) { _ in
            tally.hit()
            return .number(2)
        })

        let ast = FormulaAST.function("LET", [
            name("a"), .function("TALLY", []),
            .add(name("a"), .add(name("a"), name("a"))),
        ])
        XCTAssertEqual(try FormulaEvaluator.evaluate(
            ast, cells: Cells(), names: Names(), functions: registry), .number(6))
        XCTAssertEqual(tally.count, 1, "three mentions, one evaluation")
    }
}
