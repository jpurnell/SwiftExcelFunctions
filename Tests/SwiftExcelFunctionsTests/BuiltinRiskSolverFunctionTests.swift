import Foundation
import Testing
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// The parts of Risk Solver a spreadsheet can carry that are not simulation.
@Suite struct BuiltinRiskSolverFunctionTests {

    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let fn = BuiltinRiskSolverFunctions.all.first(where: { $0.name == name }) else {
            Issue.record("\(name) is not registered")
            return .error(.name)
        }
        return try fn.evaluate(args)
    }

    /// The group is exactly its three parts, with nothing duplicated or orphaned.
    ///
    /// Structural rather than a list of names: the distributions have their own
    /// inventory tests, and a second hand-maintained copy of fifty-odd names here
    /// would go stale rather than catch anything.
    @Test func allIsExactlyItsParts() {
        let markers = ["PSIOUTPUT", "PSIBASECASE", "PSINAME"]
        let expected = Set(markers)
            .union(BuiltinRiskSolverFunctions.distributions.map(\.name))
            .union(BuiltinRiskSolverFunctions.furtherDistributions.map(\.name))
            .union(BuiltinRiskSolverFunctions.completingDistributions.map(\.name))
        #expect(Set(BuiltinRiskSolverFunctions.all.map(\.name)) == expected)
        #expect(BuiltinRiskSolverFunctions.all.count == expected.count, "a name is registered twice")
        for marker in markers {
            #expect(BuiltinRiskSolverFunctions.all.contains { $0.name == marker }, "\(marker) is missing")
        }
    }

    /// `PsiOutput()` marks a cell as a simulation result. It contributes nothing to
    /// the arithmetic, which is why it can be appended to a real formula.
    @Test func psiOutputIsZero() throws {
        #expect(try eval("PSIOUTPUT") == .number(0))
    }

    /// The shape the corpus actually writes: `SUM(J2:J11)+_xll.PsiOutput()`.
    ///
    /// 167 cells across 41 workbooks carry it — the most widespread of the family —
    /// and every one of them is an ordinary formula with a marker stuck on the end.
    @Test func aMarkedFormulaEvaluatesToTheFormula() throws {
        let plain = try FormulaEvaluator.evaluate(
            .function("SUM", [.number(10), .number(20), .number(12)]),
            cells: EmptyCells(), names: NamedRangeCollection())
        let marked = try FormulaEvaluator.evaluate(
            .add(.function("SUM", [.number(10), .number(20), .number(12)]),
                 .function("_xll.PsiOutput", [])),
            cells: EmptyCells(), names: NamedRangeCollection())
        #expect(marked == plain)
        #expect(marked == .number(42))
    }

    // MARK: - Property functions

    /// `PsiBaseCase(v)` is `v`. It is what a distribution shows when nothing is
    /// simulating, and it is deterministic — the one part of the family that is.
    @Test func psiBaseCaseIsItsArgument() throws {
        #expect(try eval("PSIBASECASE", .number(42)) == .number(42))
        #expect(try eval("PSIBASECASE", .text("x")) == .text("x"))
    }

    @Test func psiNameIsItsLabel() throws {
        #expect(try eval("PSINAME", .text("Aggressive Launch")) == .text("Aggressive Launch"))
    }

    /// The reason they are implemented before the distributions are: they are
    /// *arguments*, so the evaluator evaluates them regardless, and an unregistered
    /// one is `#NAME?` that propagation then carries outward — failing a distribution
    /// that is otherwise correct.
    @Test func aPropertyFunctionDoesNotPoisonItsEnclosingCall() throws {
        let result = try FormulaEvaluator.evaluate(
            .function("SUM", [.number(10),
                              .function("_xll.PsiBaseCase", [.number(5)])]),
            cells: EmptyCells(), names: NamedRangeCollection())
        #expect(result == .number(15))
    }

    /// They resolve through the add-in prefix, as the corpus writes them.
    @Test func thePropertyFunctionsResolveThroughThePrefix() {
        let registry = FunctionRegistry.builtin
        #expect(registry.resolvedName("_xll.PsiBaseCase") == "PSIBASECASE")
        #expect(registry.resolvedName("_xll.PsiName") == "PSINAME")
    }

    // MARK: - Excel's "not my name" prefixes

    /// `_xll.` marks an add-in function and `_xlfn.` one newer than the file format.
    /// Neither is part of the function's identity — Excel displays both without the
    /// prefix — so the registry resolves through them.
    @Test func theRegistryLooksThroughExcelsPrefixes() {
        let registry = FunctionRegistry.builtin
        #expect(registry.resolvedName("_xll.PsiOutput") == "PSIOUTPUT")
        #expect(registry.resolvedName("_XLL.PSIOUTPUT") == "PSIOUTPUT")
        #expect(registry.resolvedName("_xlfn.SUMIFS") == "SUMIFS", "a modern spelling")
        #expect(registry.resolvedName("SUM") == "SUM", "and a plain name still works")
    }

    /// A prefix on a name nothing defines is still unknown, rather than resolving to
    /// something with a similar tail.
    /// Resolving the prefix must not invent a function behind it.
    ///
    /// `PsiSip` is the example because it is a real Frontline function this package
    /// genuinely cannot answer, and for a reason that will not expire: it names a
    /// stored data packet in the workbook rather than computing anything, so it is
    /// address arithmetic and belongs downstream with `solver_adj`. A workbook using
    /// it should get `#NAME?` — "nobody here knows this" — rather than a number.
    ///
    /// It replaced `PsiPert`, which was the example until BusinessMath 2.15.0 made it
    /// answerable. That is the failure mode to watch for here: an example chosen
    /// because it was missing stops testing anything the moment it arrives.
    @Test func anUnknownPrefixedNameStaysUnknown() {
        #expect(FunctionRegistry.builtin.function(named: "_xll.PsiSip") == nil)
        #expect(FunctionRegistry.builtin.function(named: "_xlfn.NOTAFUNCTION") == nil)
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
