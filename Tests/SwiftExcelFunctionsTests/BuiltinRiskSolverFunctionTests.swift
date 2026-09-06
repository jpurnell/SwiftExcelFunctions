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

    func testAllContainsEveryFunctionInTheGroup() {
        XCTAssertEqual(Set(BuiltinRiskSolverFunctions.all.map(\.name)), ["PSIOUTPUT"])
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
    func testAnUnknownPrefixedNameStaysUnknown() {
        XCTAssertNil(FunctionRegistry.builtin.function(named: "_xll.PsiTriangular"))
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
