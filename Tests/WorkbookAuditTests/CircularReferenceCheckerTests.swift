import XCTest
@testable import WorkbookAudit
import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// Step 1 of `PROPOSAL_workbook_validator.md` — one checker, end to end.
///
/// `recursion` is deliberately the first: `DependencyGraph.cycles` already computes the
/// answer, so this exercises the whole path from workbook to finding without any new
/// analysis to get wrong. What is being tested is the *pipeline*, not the cycle detection.
final class CircularReferenceCheckerTests: XCTestCase {

    private func sheet(_ formulas: [String: String], constants: [String: Double] = [:]) throws -> Workbook {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Model")
        for (ref, value) in constants { sheet.write(value, to: ref) }
        for (ref, formula) in formulas { sheet.writeFormula(formula, to: ref) }
        return workbook
    }

    // MARK: - Finding one

    func testAPlantedCycleIsFound() throws {
        let workbook = try sheet(["B1": "B2+1", "B2": "B1+1", "D1": "5*2"])
        let findings = WorkbookAuditor().audit(workbook)

        XCTAssertEqual(findings.count, 1)
        let finding = try XCTUnwrap(findings.first)
        XCTAssertEqual(finding.checker, "circular-reference")
        XCTAssertEqual(finding.severity, .error)
        XCTAssertTrue([CellRef("B1"), CellRef("B2")].contains(finding.address.cell))
        XCTAssertFalse(finding.related.isEmpty, "a cycle finding must name the cells it runs through")
    }

    /// A cycle across two sheets is still one cycle. `CellAddress` carries the sheet, and
    /// the graph is built over the workbook rather than a sheet at a time — the Long Acre
    /// case, where 69% of a model's formulas reference another sheet.
    func testACycleAcrossTwoSheetsIsFound() throws {
        let workbook = Workbook()
        let first = workbook.addSheet(name: "One")
        let second = workbook.addSheet(name: "Two")
        first.writeFormula("Two!A1+1", to: "A1")
        second.writeFormula("One!A1+1", to: "A1")

        let findings = WorkbookAuditor().audit(workbook)
        XCTAssertFalse(findings.isEmpty, "a cross-sheet cycle is still a cycle")
        XCTAssertEqual(findings.first?.checker, "circular-reference")
    }

    // MARK: - Not finding one

    /// **The half that matters more.** A validator that cries wolf is a validator nobody
    /// runs, so a clean model must produce nothing at all.
    func testACleanModelProducesNoFindings() throws {
        let workbook = try sheet(
            ["B3": "B1*B2", "B4": "SUM(B1:B3)"],
            constants: ["B1": 10, "B2": 20])
        XCTAssertEqual(WorkbookAuditor().audit(workbook), [])
    }

    /// A long chain is not a cycle, however long.
    func testALongChainIsNotACycle() throws {
        var formulas: [String: String] = ["A1": "1"]
        for row in 2...40 { formulas["A\(row)"] = "A\(row - 1)+1" }
        XCTAssertEqual(WorkbookAuditor().audit(try sheet(formulas)), [])
    }

    /// A cell referring to itself is the smallest cycle there is.
    func testASelfReferenceIsACycle() throws {
        let findings = WorkbookAuditor().audit(try sheet(["A1": "A1+1"]))
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?.address.cell, CellRef("A1"))
    }

    // MARK: - The shape of a run

    /// Findings are ordered, so two runs over one workbook report the same thing in the
    /// same order. A validator whose output moves between runs cannot be diffed in CI.
    func testFindingsAreDeterministicallyOrdered() throws {
        let workbook = try sheet([
            "B1": "B2+1", "B2": "B1+1",
            "D1": "D2+1", "D2": "D1+1"
        ])
        XCTAssertEqual(WorkbookAuditor().audit(workbook), WorkbookAuditor().audit(workbook))
    }

    /// A checker declares what it needs, so a run that only wants structure never pays for
    /// recomputation or a simulation.
    func testTheCheckerDeclaresItNeedsOnlyStructure() {
        XCTAssertEqual(CircularReferenceChecker.requires, .structure)
    }
}
