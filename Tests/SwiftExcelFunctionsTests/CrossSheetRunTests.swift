import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// A model that **spans sheets**: the draw on one tab, the answer on another.
///
/// ## Why this is the normal shape
///
/// A run used to be one sheet's worth of cells, keyed by position alone. That is not how
/// models are built. A financial template takes its pricing from a separate tab so the
/// template can stay standard and the pricing can change; a case model reads its parameters
/// from a regression on a data sheet. In both, the cell worth treating as uncertain is on a
/// different sheet from the number it moves.
///
/// ## What had to change for it
///
/// Every address in the run carries its sheet now — the survey's draws and outputs, the
/// evaluation order, and the per-trial overlay. The overlay is the one that mattered most and
/// was least visible: it was keyed by position alone, so an override computed for `Model!B4`
/// would have been handed to a formula asking for `Pricing!B4`. Nothing would have errored.
/// The run would have completed and reported a model that never existed.
@Suite struct CrossSheetRunTests {

    /// Pricing on one sheet, a template on another that multiplies it by a volume.
    ///
    /// The shape of the thing: `Pricing!B2` is the uncertain price, `Model!B2` reads it
    /// across, and `Model!B3` is the answer.
    private func workbook() -> Workbook {
        let workbook = Workbook()

        let pricing = workbook.addSheet(name: "Pricing")
        pricing.write("Price", to: "A2")
        pricing.writeFormula("PsiNormal(50,10)", to: "B2")

        let model = workbook.addSheet(name: "Model")
        model.write("Price", to: "A2")
        model.write(FormulaAST.sheetRef(SheetReference(sheet: "Pricing", cell: CellRef("B2"))),
                    to: "B2", cached: .number(50))
        model.write("Volume", to: "A3")
        model.write(100.0, to: "B3")
        model.write("Revenue", to: "A4")
        model.writeFormula("B2*B3+PsiOutput()", to: "B4")
        return workbook
    }

    /// Every sheet of a workbook, which is what a cross-sheet run needs to see.
    private struct Book: CellValueProvider, PopulatedCellProvider {
        let workbook: Workbook

        private func sheet(_ name: String) -> Worksheet? {
            workbook.sheets.first { $0.name.lowercased() == name.lowercased() }
        }

        func value(at ref: CellRef) -> CellValue? { value(at: ref, inSheet: "") }

        func value(at ref: CellRef, inSheet name: String) -> CellValue? {
            let target = name.isEmpty ? workbook.sheets.first?.name ?? "" : name
            return WorkbookValueProvider(workbook: workbook, currentSheet: target)
                .value(at: ref, inSheet: target)
        }

        func values(in range: CellRange) -> [CellValue] { values(in: range, inSheet: "") }
        func values(in range: CellRange, inSheet name: String) -> [CellValue] {
            range.cells.map { value(at: $0, inSheet: name) ?? .blank }
        }

        func lastPopulatedCell() -> CellRef? { lastPopulatedCell(inSheet: "") }
        func lastPopulatedCell(inSheet name: String) -> CellRef? {
            populatedAddresses()
                .filter { name.isEmpty || $0.sheet.lowercased() == name.lowercased() }
                .map(\.cell)
                .max { ($0.row, $0.column) < ($1.row, $1.column) }
        }

        func populatedCells() -> [CellRef] { populatedAddresses().map(\.cell) }

        func populatedAddresses() -> [CellAddress] {
            workbook.sheets.flatMap { sheet in
                sheet.cellReferences.map { CellAddress(sheet: sheet.name, cell: CellRef($0)) }
            }
        }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    // MARK: - Finding it

    /// The survey sees the draw on the sheet it is actually on.
    @Test func theSurveyFindsADrawOnAnotherSheet() throws {
        let survey = ModelSurveyor().survey(Book(workbook: workbook()))

        let draw = try #require(survey.uncertain.first)
        #expect(draw.address.sheet == "Pricing")
        #expect(draw.address.cell.reference == "B2")
        #expect(draw.call.function == "PSINORMAL")

        #expect(survey.outputs.map(\.sheet) == ["Model"])
        #expect(survey.outputs.map(\.cell.reference) == ["B4"])
    }

    // MARK: - Running it

    /// **The whole point.** A price drawn on `Pricing` moves an answer on `Model`.
    @Test func aDrawOnOneSheetMovesAnAnswerOnAnother() throws {
        let cells = Book(workbook: workbook())
        let run = try InterpretedRun.run(
            survey: ModelSurveyor().survey(cells), over: cells, names: NoNames(),
            trials: 4_000, seed: 7)

        let revenue = try #require(run.results(for: CellAddress(sheet: "Model", ref: "B4")))
        #expect(revenue.values.count == 4_000, "every trial produced a number")
        #expect(abs(revenue.statistics.mean - 5_000) <= 120, "50 × 100, on average")
        #expect(abs(revenue.statistics.stdDev - 1_000) <= 120, "and 10 × 100 of spread")
    }

    /// The parallel engine agrees, because it is the same evaluator on another schedule.
    @Test func theParallelEngineAgreesAcrossSheets() async throws {
        let cells = Book(workbook: workbook())
        let survey = ModelSurveyor().survey(cells)
        let graph = DependencyGraph(cells: cells.populatedAddresses(), provider: cells)
        let engine = InterpretedRun(
            survey: survey, evaluationOrder: graph.evaluationOrder, trials: 2_000, seed: 7)

        let run = try await engine.runConcurrently(over: cells, names: NoNames())
        let revenue = try #require(run.results(for: CellAddress(sheet: "Model", ref: "B4")))
        #expect(abs(revenue.statistics.mean - 5_000) <= 170)
    }

    /// **An override reaches a draw on another sheet.** It could not, while an override named
    /// only a cell: `Pricing!B2` and `Model!B2` were one key.
    @Test func anOverrideReachesTheOtherSheet() async throws {
        let cells = Book(workbook: workbook())
        let survey = ModelSurveyor().survey(cells)
        let graph = DependencyGraph(cells: cells.populatedAddresses(), provider: cells)
        let engine = InterpretedRun(
            survey: survey, evaluationOrder: graph.evaluationOrder, trials: 2_000, seed: 7)

        let run = try await engine.runConcurrently(
            over: cells, names: NoNames(),
            overrides: [DistributionOverride(
                cell: CellAddress(sheet: "Pricing", ref: "B2"), parameter: 0, value: 80)])

        let revenue = try #require(run.results(for: CellAddress(sheet: "Model", ref: "B4")))
        #expect(abs(revenue.statistics.mean - 8_000) <= 170, "the mean moved to 80")
    }

    /// **The same address on two sheets is two cells**, which the overlay has to agree with.
    ///
    /// `Model!B2` is computed and `Pricing!B2` is drawn. Keyed by position alone, one of them
    /// would have shadowed the other and the run would have reported it without complaint.
    @Test func twoSheetsSharingAnAddressStaySeparate() throws {
        let cells = Book(workbook: workbook())
        let run = try InterpretedRun.run(
            survey: ModelSurveyor().survey(cells), over: cells, names: NoNames(),
            trials: 500, seed: 7)

        let revenue = try #require(run.results(for: CellAddress(sheet: "Model", ref: "B4")))
        // If `Model!B2` had been shadowed by the draw at `Pricing!B2`, this would still look
        // plausible — the tell is the volume, which only multiplies in when `Model!B2` is read
        // as itself rather than as the other sheet's cell.
        #expect(abs(revenue.statistics.mean - 5_000) <= 350)
        #expect(revenue.statistics.stdDev > 500, "and it genuinely varies")
    }
}
