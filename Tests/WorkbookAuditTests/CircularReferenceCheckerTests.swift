import Foundation
import Testing
@testable import WorkbookAudit
import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// Step 1 of `PROPOSAL_workbook_validator.md` — one checker, end to end.
///
/// `recursion` is deliberately the first: `DependencyGraph.cycles` already computes the
/// answer, so this exercises the whole path from workbook to finding without any new
/// analysis to get wrong. What is being tested is the *pipeline*, not the cycle detection.
@Suite struct CircularReferenceCheckerTests {

    private func sheet(_ formulas: [String: String], constants: [String: Double] = [:]) throws -> Workbook {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Model")
        for (ref, value) in constants { sheet.write(value, to: ref) }
        for (ref, formula) in formulas { sheet.writeFormula(formula, to: ref) }
        return workbook
    }

    // MARK: - Finding one

    @Test func aPlantedCycleIsFound() throws {
        let workbook = try sheet(["B1": "B2+1", "B2": "B1+1", "D1": "5*2"])
        let findings = WorkbookAuditor().audit(workbook)

        #expect(findings.count == 1)
        let finding = try #require(findings.first)
        #expect(finding.checker == "circular-reference")
        #expect(finding.severity == .error)
        #expect([CellRef("B1"), CellRef("B2")].contains(finding.address.cell))
        #expect(!finding.related.isEmpty, "a cycle finding must name the cells it runs through")
    }

    /// A cycle across two sheets is still one cycle. `CellAddress` carries the sheet, and
    /// the graph is built over the workbook rather than a sheet at a time — the Long Acre
    /// case, where 69% of a model's formulas reference another sheet.
    @Test func aCycleAcrossTwoSheetsIsFound() throws {
        let workbook = Workbook()
        let first = workbook.addSheet(name: "One")
        let second = workbook.addSheet(name: "Two")
        first.writeFormula("Two!A1+1", to: "A1")
        second.writeFormula("One!A1+1", to: "A1")

        let findings = WorkbookAuditor().audit(workbook)
        #expect(!findings.isEmpty, "a cross-sheet cycle is still a cycle")
        #expect(findings.first?.checker == "circular-reference")
    }

    // MARK: - Not finding one

    /// **The half that matters more.** A validator that cries wolf is a validator nobody
    /// runs, so a clean model must produce nothing at all.
    @Test func aCleanModelProducesNoFindings() throws {
        let workbook = try sheet(
            ["B3": "B1*B2", "B4": "SUM(B1:B3)"],
            constants: ["B1": 10, "B2": 20])
        #expect(WorkbookAuditor().audit(workbook) == [])
    }

    /// A long chain is not a cycle, however long.
    @Test func aLongChainIsNotACycle() throws {
        var formulas: [String: String] = ["A1": "1"]
        for row in 2...40 { formulas["A\(row)"] = "A\(row - 1)+1" }
        #expect(WorkbookAuditor().audit(try sheet(formulas)) == [])
    }

    /// A cell referring to itself is the smallest cycle there is.
    @Test func aSelfReferenceIsACycle() throws {
        let findings = WorkbookAuditor().audit(try sheet(["A1": "A1+1"]))
        #expect(findings.count == 1)
        #expect(findings.first?.address.cell == CellRef("A1"))
    }

    // MARK: - The shape of a run

    /// Findings are ordered, so two runs over one workbook report the same thing in the
    /// same order. A validator whose output moves between runs cannot be diffed in CI.
    @Test func findingsAreDeterministicallyOrdered() throws {
        let workbook = try sheet([
            "B1": "B2+1", "B2": "B1+1",
            "D1": "D2+1", "D2": "D1+1"
        ])
        #expect(WorkbookAuditor().audit(workbook) == WorkbookAuditor().audit(workbook))
    }

    /// A checker declares what it needs, so a run that only wants structure never pays for
    /// recomputation or a simulation.
    @Test func theCheckerDeclaresItNeedsOnlyStructure() {
        #expect(CircularReferenceChecker.requires == .structure)
    }
}
