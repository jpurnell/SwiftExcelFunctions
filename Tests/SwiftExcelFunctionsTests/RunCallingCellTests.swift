import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// A **simulation** evaluates cells that know where they are.
///
/// ## The bug
///
/// Both run engines evaluated every cell with `at: nil`. The evaluator's own rule says what
/// that costs — *"with no calling cell there is nothing to intersect against and the range
/// stands"* — so implicit intersection, which the rest of the package implements and tests,
/// was switched off for the whole of every simulation. A formula that worked when evaluated on
/// its own stopped working the moment it was run, and the difference was invisible.
///
/// It compounded the argument gap rather than causing it: closing that seam changed nothing
/// here until the cell was passed, because there was still no position to intersect against.
@Suite struct RunCallingCellTests {

    /// A sheet using the idiom the lookup family is written with: a column of keys, and a
    /// formula per row whose lookup value is the whole column, meaning its own row.
    private struct Book: CellValueProvider, PopulatedCellProvider {
        var cells: [String: CellValue] = [
            "A1": .number(1), "B1": .number(10),
            "A2": .number(2), "B2": .number(20),
            "A3": .number(3), "B3": .number(30),
        ]
        func value(at ref: CellRef) -> CellValue? { cells[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { cells[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("D3") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("D3") }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { cells[$0.reference] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
        func populatedCells() -> [CellRef] { cells.keys.map { CellRef($0) } }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    /// Builds a sheet with `D2` looking its own row up and reporting it.
    private func book() throws -> Book {
        var book = Book()
        book.cells["D2"] = .formula(
            try FormulaParser.parse("VLOOKUP(A1:A3,A1:B3,2)+PsiOutput()"), cached: nil)
        return book
    }

    /// **The whole point.** `D2` looks up `A2`, so it is 20 — and was `#N/A` while the run
    /// evaluated it from nowhere.
    @Test func aRunIntersectsAgainstTheCellBeingEvaluated() throws {
        let cells = try book()
        let run = try InterpretedRun.run(
            survey: ModelSurveyor().survey(cells), over: cells, names: NoNames(),
            inSheet: "Sheet1", trials: 1, seed: 1)
        let results = try #require(run.results(for: CellRef("D2")))
        #expect(results.values == [20], "row 2 of the table")
    }

    /// The parallel engine is the same evaluator and must not disagree with the interpreted
    /// one — two engines that answer differently is worse than one that answers wrongly.
    @Test func theParallelEngineAgrees() async throws {
        let cells = try book()
        let survey = ModelSurveyor().survey(cells)
        let order = DependencyGraph(
            cells: cells.populatedCells().map { CellAddress(sheet: "Sheet1", cell: $0) },
            provider: cells).evaluationOrder
        // `inSheet:` because the order is built with a sheet name and the survey of a
        // single-sheet provider is not. Both sides resolve against it; leaving it out is how
        // the outputs and the overrides end up keyed under different names.
        let engine = InterpretedRun(survey: survey, evaluationOrder: order, trials: 4, seed: 1,
                                    inSheet: "Sheet1")
        let run = try await engine.runConcurrently(over: cells, names: NoNames())
        let results = try #require(run.results(for: CellAddress(sheet: "Sheet1", ref: "D2")))
        #expect(results.values == [20, 20, 20, 20])
    }
}
