import Foundation
import Testing
@testable import WorkbookAudit
import SwiftExcelCore
import SwiftXLSX

/// The inconsistent formula in a row — the classic spreadsheet defect.
///
/// One cell in a range differing from its neighbours: the copy that stopped short, the
/// hand-edit nobody noticed. Excel flags a weak version of it. Detecting it properly means
/// comparing formulas **modulo relative offset**, so `=B2*C2` in row 2 and `=B3*C3` in
/// row 3 are the *same* formula and only a genuine difference stands out.
///
/// This is the checker that catches real financial-model errors, and it evaluates nothing.
@Suite struct ConsistencyCheckerTests {

    private func book(_ formulas: [String: String], constants: [String: Double] = [:]) -> Workbook {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Model")
        for (ref, value) in constants { sheet.write(value, to: ref) }
        for (ref, formula) in formulas { sheet.writeFormula(formula, to: ref) }
        return workbook
    }

    private func findings(_ workbook: Workbook) -> [Finding] {
        WorkbookAuditor(checkers: [ConsistencyChecker()]).audit(workbook)
    }

    /// It is not on by default, and that is a decision the census made rather than a
    /// doubt about the logic. See ``WorkbookAuditor/experimental``.
    @Test func itIsNotEnabledByDefaultYet() {
        #expect(!(WorkbookAuditor.standard.contains { type(of: $0).name == "consistency" }))
        #expect(WorkbookAuditor.experimental.contains { type(of: $0).name == "consistency" })
    }

    /// **The defect it found in a real model, kept as a fixture.**
    ///
    /// Genzyme's row 19: every cell multiplies three factors from its own column, and one
    /// reaches into the column before it. A person reading the sheet sees a number in a row
    /// of numbers; the shape signature sees `R[-6]C[-1]` where its neighbours have
    /// `R[-6]C[0]`.
    ///
    /// This is the evidence that the checker is worth tuning rather than dropping, so it
    /// lives in the suite rather than in a commit message.
    @Test func theRealDefectItFoundStaysFound() {
        let findings = findings(book([
            "B19": "B17*B18*B13", "C19": "C17*C18*C13", "D19": "D17*D18*D13",
            "E19": "E17*E18*D13", "F19": "F17*F18*F13"
        ]))
        #expect(findings.map(\.address.cell) == [CellRef("E19")])
    }

    // MARK: - The shape signature

    /// Two formulas one row apart, referring one row apart, are the same shape.
    @Test func relativeReferencesNormaliseToTheSameShape() throws {
        let a = try FormulaParser.parse("B2*C2")
        let b = try FormulaParser.parse("B3*C3")
        #expect(ConsistencyChecker.shapeSignature(of: a, at: CellRef("D2")) == ConsistencyChecker.shapeSignature(of: b, at: CellRef("D3")))
    }

    /// A genuinely different formula has a different shape, however similar it looks.
    @Test func aDifferentOperatorIsADifferentShape() throws {
        let a = try FormulaParser.parse("B2*C2")
        let b = try FormulaParser.parse("B2+C2")
        #expect(ConsistencyChecker.shapeSignature(of: a, at: CellRef("D2")) != ConsistencyChecker.shapeSignature(of: b, at: CellRef("D2")))
    }

    /// A pinned reference is a different intent from one that moves, and stays different.
    ///
    /// `$B$1` deliberately anchored is not the same formula as `B1` that happened not to
    /// move, and collapsing them would hide the copy that lost its anchor — which is one
    /// of the defects this checker exists to find.
    @Test func anAbsoluteReferenceIsADifferentShapeFromARelativeOne() throws {
        let a = try FormulaParser.parse("$B$1*C2")
        let b = try FormulaParser.parse("B1*C2")
        #expect(ConsistencyChecker.shapeSignature(of: a, at: CellRef("D2")) != ConsistencyChecker.shapeSignature(of: b, at: CellRef("D2")))
    }

    // MARK: - Finding the odd one out

    /// The defect, planted: five cells copied across, one hand-edited.
    @Test func theOddCellInARowIsFound() throws {
        let findings = findings(book([
            "B5": "B4*2", "C5": "C4*2", "D5": "D4*3", "E5": "E4*2", "F5": "F4*2"
        ]))

        #expect(findings.count == 1)
        #expect(findings.first?.checker == "consistency")
        #expect(findings.first?.address.cell == CellRef("D5"))
        let finding = try #require(findings.first)
        #expect(finding.related.count >= 3, "the finding must name the run it broke")
    }

    /// The same defect down a column.
    @Test func theOddCellInAColumnIsFound() {
        let findings = findings(book([
            "B2": "A2*2", "B3": "A3*2", "B4": "A4*2", "B5": "A5+2", "B6": "A6*2"
        ]))
        #expect(findings.first?.address.cell == CellRef("B5"))
    }

    // MARK: - Not crying wolf

    /// A run where every cell agrees is not a finding.
    @Test func aConsistentRowIsClean() {
        #expect(findings(book([
            "B5": "B4*2", "C5": "C4*2", "D5": "D4*2", "E5": "E4*2"
        ])) == [])
    }

    /// **Two against two is not an odd one out.** Half a row differing from the other half
    /// is a model with two sections, not a mistake — and reporting it would be the noise
    /// that gets a checker switched off.
    @Test func anEvenSplitIsNotReported() {
        #expect(findings(book([
            "B5": "B4*2", "C5": "C4*2", "D5": "D4*3", "E5": "E4*3"
        ])) == [])
    }

    /// A run too short to have a majority says nothing.
    @Test func aTwoCellRunIsNotEnoughToJudge() {
        #expect(findings(book(["B5": "B4*2", "C5": "C4*3"])) == [])
    }

    /// Cells that are not adjacent are not a run. A formula at B5 and another at Z5 are
    /// unrelated however similar they look.
    @Test func nonAdjacentCellsAreNotARun() {
        #expect(findings(book([
            "B5": "B4*2", "C5": "C4*2", "D5": "D4*2", "Z5": "Z4*3"
        ])) == [])
    }

    /// Constants are not formulas and never take part.
    @Test func constantsAreNotComparedAgainstFormulas() {
        #expect(findings(book(
            ["B5": "B4*2", "C5": "C4*2", "D5": "D4*2"],
            constants: ["E5": 99])) == [])
    }
}
