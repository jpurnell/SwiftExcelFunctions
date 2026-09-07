import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// The parts of Risk Solver a spreadsheet can carry that are not simulation.
final class BuiltinRiskSolverFunctionTests: XCTestCase {

    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let fn = BuiltinRiskSolverFunctions.all.first(where: { $0.name == name }) else {
            XCTFail("\(name) is not registered")
            return .error(.name)
        }
        return try fn.evaluate(args)
    }

    /// The group is exactly its three parts, with nothing duplicated or orphaned.
    ///
    /// Structural rather than a list of names: the distributions have their own
    /// inventory tests, and a second hand-maintained copy of fifty-odd names here
    /// would go stale rather than catch anything.
    func testAllIsExactlyItsParts() {
        let markers = ["PSIOUTPUT", "PSIBASECASE", "PSINAME"]
        let expected = Set(markers)
            .union(BuiltinRiskSolverFunctions.distributions.map(\.name))
            .union(BuiltinRiskSolverFunctions.furtherDistributions.map(\.name))
        XCTAssertEqual(Set(BuiltinRiskSolverFunctions.all.map(\.name)), expected)
        XCTAssertEqual(BuiltinRiskSolverFunctions.all.count, expected.count,
                       "a name is registered twice")
        for marker in markers {
            XCTAssertTrue(BuiltinRiskSolverFunctions.all.contains { $0.name == marker },
                          "\(marker) is missing")
        }
    }

    /// `PsiOutput()` marks a cell as a simulation result. It contributes nothing to
    /// the arithmetic, which is why it can be appended to a real formula.
    func testPsiOutputIsZero() throws {
        XCTAssertEqual(try eval("PSIOUTPUT"), .number(0))
    }

    /// The shape the corpus actually writes: `SUM(J2:J11)+_xll.PsiOutput()`.
    ///
    /// 167 cells across 41 workbooks carry it — the most widespread of the family —
    /// and every one of them is an ordinary formula with a marker stuck on the end.
    func testAMarkedFormulaEvaluatesToTheFormula() throws {
        let plain = try FormulaEvaluator.evaluate(
            .function("SUM", [.number(10), .number(20), .number(12)]),
            cells: EmptyCells(), names: NamedRangeCollection())
        let marked = try FormulaEvaluator.evaluate(
            .add(.function("SUM", [.number(10), .number(20), .number(12)]),
                 .function("_xll.PsiOutput", [])),
            cells: EmptyCells(), names: NamedRangeCollection())
        XCTAssertEqual(marked, plain)
        XCTAssertEqual(marked, .number(42))
    }

    // MARK: - Property functions

    /// `PsiBaseCase(v)` is `v`. It is what a distribution shows when nothing is
    /// simulating, and it is deterministic — the one part of the family that is.
    func testPsiBaseCaseIsItsArgument() throws {
        XCTAssertEqual(try eval("PSIBASECASE", .number(42)), .number(42))
        XCTAssertEqual(try eval("PSIBASECASE", .text("x")), .text("x"))
    }

    func testPsiNameIsItsLabel() throws {
        XCTAssertEqual(try eval("PSINAME", .text("Aggressive Launch")),
                       .text("Aggressive Launch"))
    }

    /// The reason they are implemented before the distributions are: they are
    /// *arguments*, so the evaluator evaluates them regardless, and an unregistered
    /// one is `#NAME?` that propagation then carries outward — failing a distribution
    /// that is otherwise correct.
    func testAPropertyFunctionDoesNotPoisonItsEnclosingCall() throws {
        let result = try FormulaEvaluator.evaluate(
            .function("SUM", [.number(10),
                              .function("_xll.PsiBaseCase", [.number(5)])]),
            cells: EmptyCells(), names: NamedRangeCollection())
        XCTAssertEqual(result, .number(15))
    }

    /// They resolve through the add-in prefix, as the corpus writes them.
    func testThePropertyFunctionsResolveThroughThePrefix() {
        let registry = FunctionRegistry.builtin
        XCTAssertNotNil(registry.function(named: "_xll.PsiBaseCase"))
        XCTAssertNotNil(registry.function(named: "_xll.PsiName"))
    }

    // MARK: - Excel's "not my name" prefixes

    /// `_xll.` marks an add-in function and `_xlfn.` one newer than the file format.
    /// Neither is part of the function's identity — Excel displays both without the
    /// prefix — so the registry resolves through them.
    func testTheRegistryLooksThroughExcelsPrefixes() {
        let registry = FunctionRegistry.builtin
        XCTAssertNotNil(registry.function(named: "_xll.PsiOutput"))
        XCTAssertNotNil(registry.function(named: "_XLL.PSIOUTPUT"))
        XCTAssertNotNil(registry.function(named: "_xlfn.SUMIFS"), "a modern spelling")
        XCTAssertNotNil(registry.function(named: "SUM"), "and a plain name still works")
    }

    /// A prefix on a name nothing defines is still unknown, rather than resolving to
    /// something with a similar tail.
    /// Resolving the prefix must not invent a function behind it.
    ///
    /// `PsiPert` is the example because it is a real Frontline distribution this
    /// package genuinely cannot answer — BusinessMath has no Beta-PERT at 2.14.0,
    /// recorded in `project/plans/psi_upstream_gaps.md`. A workbook using it should
    /// get `#NAME?`, which says "nobody here knows this", rather than a number.
    func testAnUnknownPrefixedNameStaysUnknown() {
        XCTAssertNil(FunctionRegistry.builtin.function(named: "_xll.PsiPert"))
        XCTAssertNil(FunctionRegistry.builtin.function(named: "_xlfn.NOTAFUNCTION"))
    }

    private struct EmptyCells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }
}
