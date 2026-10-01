import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// Phase 1, second half — the recognizer applied to a whole sheet.
///
/// ``PsiRecognizer`` reads one formula. ``ModelSurveyor`` walks a provider, applies it to
/// every formula cell, and assigns the input indices a sampler will fill. That index
/// assignment is the part with a contract worth pinning: it has to be stable, and it has
/// to be per *call site* rather than per cell.
@Suite struct ModelSurveyTests {

    /// A provider backed by formula strings, parsed by the real parser.
    private struct Sheet: CellValueProvider {
        var cells: [CellRef: CellValue] = [:]

        init(_ formulas: [String: String]) throws {
            for (ref, formula) in formulas {
                let ast = try FormulaParser.parse(formula)
                cells[CellRef(ref)] = .formula(ast, cached: nil)
            }
        }

        init(cells: [CellRef: CellValue]) { self.cells = cells }

        func value(at ref: CellRef) -> CellValue? { cells[ref] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { cells[ref] }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
        func lastPopulatedCell() -> CellRef? {
            guard let maxCol = cells.keys.map(\.column).max(),
                  let maxRow = cells.keys.map(\.row).max() else { return nil }
            return CellRef(column: maxCol, row: maxRow)
        }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
    }

    private let surveyor = ModelSurveyor()

    // MARK: - Finding the roles

    @Test func emptySheetSurveysToNothing() {
        let survey = surveyor.survey(Sheet(cells: [:]))
        #expect(survey.uncertain.isEmpty)
        #expect(survey.outputs.isEmpty)
        #expect(!survey.isSimulable)
    }

    @Test func uncertainCellsAndOutputsAreFound() throws {
        let survey = surveyor.survey(try Sheet([
            "B1": "PsiNormal(100, 10)",
            "B2": "PsiTriangular(5, 7, 12)",
            "B3": "B1*B2",
            "B4": "B3+_xll.PsiOutput()"
        ]))

        #expect(survey.uncertain.count == 2)
        #expect(survey.outputs == [CellAddress(sheet: "", ref: "B4")])
        #expect(survey.isSimulable)
    }

    /// A cell holding a literal is not a formula and carries no role.
    @Test func literalCellsAreIgnored() throws {
        var sheet = try Sheet(["B1": "PsiNormal(0, 1)"])
        sheet.cells[CellRef("D1")] = .number(250)
        sheet.cells[CellRef("D2")] = .text("Revenue")

        let survey = surveyor.survey(sheet)
        #expect(survey.uncertain.count == 1)
    }

    // MARK: - Input indices

    /// Indices must be contiguous from zero, because they address positions in the
    /// `[Double]` the sampler hands to a compiled model.
    @Test func inputIndicesAreContiguousFromZero() throws {
        let survey = surveyor.survey(try Sheet([
            "B1": "PsiNormal(0, 1)",
            "B2": "PsiUniform(0, 1)",
            "B3": "PsiPoisson(4)"
        ]))
        #expect(survey.uncertain.map(\.inputIndex).sorted() == [0, 1, 2])
    }

    /// **The call-site contract, at sheet scope.**
    ///
    /// Two draws in one cell need two uniforms. If the surveyor assigned one index per
    /// *cell*, the two would share a draw and become perfectly correlated — a wrong
    /// answer that reads as plausible.
    @Test func twoDrawsInOneCellGetTwoIndices() throws {
        let survey = surveyor.survey(try Sheet([
            "B1": "PsiNormal(0, 1) + PsiNormal(0, 1)"
        ]))
        #expect(survey.uncertain.count == 2)
        #expect(Set(survey.uncertain.map(\.inputIndex)) == [0, 1])
        #expect(Set(survey.uncertain.map(\.address)) == [CellAddress(sheet: "", ref: "B1")])
    }

    /// A survey run twice on the same sheet must assign the same indices, or a seeded
    /// run stops being reproducible across processes — dictionary ordering is not stable
    /// between launches, so the surveyor cannot inherit it.
    @Test func indexAssignmentIsDeterministic() throws {
        let formulas = [
            "Z9": "PsiNormal(0, 1)",
            "A1": "PsiUniform(0, 1)",
            "M5": "PsiPoisson(4)"
        ]
        let first = surveyor.survey(try Sheet(formulas))
        let second = surveyor.survey(try Sheet(formulas))

        #expect(first.uncertain.map(\.address) == second.uncertain.map(\.address))
        #expect(first.uncertain.map(\.inputIndex) == second.uncertain.map(\.inputIndex))
    }

    /// Reading order, so a person looking at the sheet and a person reading the input
    /// vector are looking at the same sequence.
    @Test func indicesFollowRowThenColumnOrder() throws {
        let survey = surveyor.survey(try Sheet([
            "B2": "PsiNormal(0, 1)",
            "A1": "PsiUniform(0, 1)",
            "B1": "PsiPoisson(4)"
        ]))
        #expect(survey.uncertain.map(\.address) == [CellAddress(sheet: "", ref: "A1"), CellAddress(sheet: "", ref: "B1"), CellAddress(sheet: "", ref: "B2")])
    }

    // MARK: - Refusing to simulate what it cannot

    /// A model carrying a property function nobody has modelled is reported, with the
    /// cell named. §5.1 of the proposal: refuse rather than approximate.
    @Test func unhandledPropertiesAreReportedWithTheirCell() throws {
        let survey = surveyor.survey(try Sheet([
            "B1": "PsiNormal(100, 10, PsiCorrIndep(1))"
        ]))
        #expect(survey.unhandledProperties[CellAddress(sheet: "", ref: "B1")] == ["PSICORRINDEP"])
        #expect(!survey.isFullyModelled)
    }

    /// Draws with no marker are still simulable — the marker is Frontline's convention,
    /// not a precondition. What the model does not say is which cells to collect.
    @Test func distributionsWithoutAnOutputMarkerAreStillSimulable() throws {
        let survey = surveyor.survey(try Sheet(["B1": "PsiNormal(0, 1)"]))
        #expect(survey.isSimulable)
        #expect(!survey.declaresItsOwnOutputs)
    }

    /// An output with nothing uncertain feeding it is a constant, not a simulation.
    @Test func outputWithoutUncertaintyIsNotSimulable() throws {
        let survey = surveyor.survey(try Sheet(["B4": "SUM(A1:A3)+PsiOutput()"]))
        #expect(!survey.isSimulable)
        #expect(survey.outputs == [CellAddress(sheet: "", ref: "B4")])
    }

    /// **A cell asked about is an output.**
    ///
    /// `PsiMean(B4)` declares `B4` collected without any marker on `B4` itself. A real
    /// 126-call workbook does exactly this and carries no `PsiOutput()` at all, so
    /// requiring the marker rejected it outright.
    @Test func aCellNamedByAStatisticIsAnOutput() throws {
        let survey = surveyor.survey(try Sheet([
            "B1": "PsiNormal(0, 1)",
            "B4": "B1*2",
            "D1": "PsiMean(B4)"
        ]))
        #expect(survey.isSimulable)
        #expect(survey.declaresItsOwnOutputs)
        #expect(survey.outputs == [CellAddress(sheet: "", ref: "B4")])
    }

    /// A marker and a statistic naming the same cell is one output, not two.
    @Test func aMarkedCellAlsoAskedAboutIsNotCountedTwice() throws {
        let survey = surveyor.survey(try Sheet([
            "B1": "PsiNormal(0, 1)",
            "B4": "B1+PsiOutput()",
            "D1": "PsiMean(B4)"
        ]))
        #expect(survey.outputs == [CellAddress(sheet: "", ref: "B4")])
    }
}
