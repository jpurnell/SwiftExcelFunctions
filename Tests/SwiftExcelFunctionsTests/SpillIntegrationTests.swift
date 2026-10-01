import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore
// The other half of the seam. Evaluation lives here and produces an assignment;
// writing lives in SwiftXLSX and applies one. Neither library depends on the
// other — this suite is the only place that holds both, and only in tests.
import SwiftXLSX

/// An array formula from written to filled and back out of a file.
///
/// Each package's own tests cover its half. These cover that the halves meet,
/// which is the part that has no owner and so is the part that rots.
@Suite struct SpillIntegrationTests {

    /// Builds a sheet, evaluates every array formula on it, and writes the results
    /// into the cells they fill.
    ///
    /// This is the whole loop, and it is short on purpose: if joining these two
    /// libraries needed more than this, the split between them would be wrong.
    private func recalculate(_ sheet: Worksheet, in workbook: Workbook) throws {
        let cells = WorkbookValueProvider(workbook: workbook, currentSheet: sheet.name)
        for formula in sheet.arrayFormulas {
            guard let ast = sheet.formulaAST(at: formula.anchor.reference) else { continue }
            sheet.apply(try FormulaEvaluator.spill(
                ast, over: formula.span, cells: cells, names: NamedRangeCollection(),
                inSheet: sheet.name))
        }
    }

    @Test func aColumnTransposedIntoARowThroughAFile() throws {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Sheet1")
        sheet.write(10, to: "A1")
        sheet.write(20, to: "A2")
        sheet.write(30, to: "A3")
        sheet.writeArrayFormula("TRANSPOSE(A1:A3)", over: CellRange(from: "C1", to: "E1"))

        try recalculate(sheet, in: workbook)

        let reread = try Workbook(xlsxData: try workbook.save())
        let reloaded = try #require(reread.sheets.first)

        for (ref, expected) in [("C1", 10.0), ("D1", 20.0), ("E1", 30.0)] {
            guard case .formula(_, let cached)? = reloaded.cell(at: ref) else {
                Issue.record("\(ref) came back as \(String(describing: reloaded.cell(at: ref)))"); return
            }
            #expect(cached == .number(expected), "\(ref)")
        }
    }

    /// The anchor keeps its formula and the members keep their marker, so the file
    /// still says how the values were produced.
    @Test func theStructureSurvivesRecalculation() throws {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Sheet1")
        sheet.write(1, to: "A1")
        sheet.write(2, to: "A2")
        sheet.writeArrayFormula("TRANSPOSE(A1:A2)", over: CellRange(from: "C1", to: "D1"))

        try recalculate(sheet, in: workbook)

        let reread = try Workbook(xlsxData: try workbook.save())
        let reloaded = try #require(reread.sheets.first)

        guard case .function(let anchor, _) = try #require(reloaded.formulaAST(at: "C1")) else {
            Issue.record("C1 lost its formula"); return
        }
        #expect(anchor == "TRANSPOSE")
        guard case .function(let marker, let args) =
            try #require(reloaded.formulaAST(at: "D1")) else {
            Issue.record("D1 lost its marker"); return
        }
        #expect(marker == "_ARRAY")
        #expect(args.first == .cellRef(CellRef("C1")))
    }

    /// A span wider than the result carries `#N/A` out to the file, which is what
    /// Excel shows for a mis-sized array formula.
    @Test func aMisSizedSpanKeepsItsNotAvailable() throws {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Sheet1")
        sheet.write(1, to: "A1")
        sheet.write(2, to: "A2")
        sheet.writeArrayFormula("TRANSPOSE(A1:A2)", over: CellRange(from: "C1", to: "E1"))

        try recalculate(sheet, in: workbook)

        let reread = try Workbook(xlsxData: try workbook.save())
        let reloaded = try #require(reread.sheets.first)
        guard case .formula(_, let cached)? = reloaded.cell(at: "E1") else {
            Issue.record("E1 is not a formula"); return
        }
        #expect(cached == .error(.na))
    }

    /// A block, so the loop is exercised on something that is not a vector.
    @Test func aBlockTransposedThroughAFile() throws {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Sheet1")
        // 1 2 3
        // 4 5 6
        for (index, value) in [1, 2, 3].enumerated() {
            sheet.write(value, to: CellRef(column: index + 1, row: 1).reference)
        }
        for (index, value) in [4, 5, 6].enumerated() {
            sheet.write(value, to: CellRef(column: index + 1, row: 2).reference)
        }
        sheet.writeArrayFormula("TRANSPOSE(A1:C2)", over: CellRange(from: "E1", to: "F3"))

        try recalculate(sheet, in: workbook)

        let reread = try Workbook(xlsxData: try workbook.save())
        let reloaded = try #require(reread.sheets.first)

        // 1 4
        // 2 5
        // 3 6
        for (ref, expected) in [("E1", 1.0), ("F1", 4.0),
                                ("E2", 2.0), ("F2", 5.0),
                                ("E3", 3.0), ("F3", 6.0)] {
            guard case .formula(_, let cached)? = reloaded.cell(at: ref) else {
                Issue.record("\(ref) came back as \(String(describing: reloaded.cell(at: ref)))"); return
            }
            #expect(cached == .number(expected), "\(ref)")
        }
    }
}
