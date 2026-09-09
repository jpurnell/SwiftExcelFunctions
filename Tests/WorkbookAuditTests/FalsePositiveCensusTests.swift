import XCTest
@testable import WorkbookAudit
import SwiftExcelCore
import SwiftXLSX

/// Step 2 of `PROPOSAL_workbook_validator.md` — the number that gates every checker after
/// the first.
///
/// A checker firing on most real models is wrong about what it measures, whatever its
/// logic says, and one shipped without this number ships noisy and gets switched off. So
/// the rule is that no second checker lands until it has a count here.
///
/// This is not a pass/fail on any workbook. It is a census, and what a real corpus
/// contains is a fact to discover rather than assert.
///
/// ```
/// RISK_SOLVER_WORKBOOKS=<dir> swift test --filter FalsePositiveCensus
/// ```
final class FalsePositiveCensusTests: XCTestCase {

    private func workbooks() throws -> [(name: String, workbook: Workbook)] {
        guard let root = ProcessInfo.processInfo.environment["RISK_SOLVER_WORKBOOKS"],
              !root.isEmpty else {
            throw XCTSkip("Set RISK_SOLVER_WORKBOOKS to a directory of real models.")
        }
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let paths = ((try? FileManager.default.subpathsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.hasSuffix(".xlsx") && !$0.hasPrefix("~$") }
            .sorted()

        return paths.compactMap { path in
            guard let data = try? Data(contentsOf: url.appendingPathComponent(path)),
                  let workbook = try? Workbook(xlsxData: data) else { return nil }
            return (path, workbook)
        }
    }

    func testCensusAcrossRealWorkbooks() throws {
        let auditor = WorkbookAuditor()
        var byChecker: [String: Int] = [:]
        var workbooksWithFindings = 0
        var examined = 0
        var report = ""

        for (name, workbook) in try workbooks() {
            examined += 1
            let findings = auditor.audit(workbook)
            guard !findings.isEmpty else { continue }
            workbooksWithFindings += 1
            for finding in findings { byChecker[finding.checker, default: 0] += 1 }
            report += "  \(name)\n"
            for finding in findings.prefix(4) {
                report += "    \(finding.severity.rawValue) \(finding.checker) "
                    + "\(finding.address.sheet)!\(finding.address.cell.reference) — \(finding.summary)\n"
            }
        }

        let rate = examined > 0 ? Double(workbooksWithFindings) / Double(examined) * 100 : 0
        print("""

        ── False-positive census ───────────────────────────────────
          workbooks examined   \(examined)
          with findings        \(workbooksWithFindings)  (\(Int(rate.rounded()))%)
          findings by checker  \(byChecker.isEmpty ? "none" : "\(byChecker)")

        \(report.isEmpty ? "  (clean)" : report)
          A checker firing on most real models is measuring the wrong
          thing. This number gates the next one.
        ────────────────────────────────────────────────────────────

        """)

        XCTAssertGreaterThan(examined, 0, "no workbooks were examined")
    }
}
