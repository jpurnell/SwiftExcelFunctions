import XCTest
@testable import SwiftExcelFunctions

/// The coverage matrix says what this package implements. This checks that it is telling the
/// truth.
///
/// The matrix is a TSV maintained alongside the code, and a document maintained alongside code
/// drifts from it — silently, and in the direction that flatters. A row marked `have` for a
/// function nobody implemented is a claim in the README with nothing behind it.
///
/// The README says the matrix is *"reconciled against the live `FunctionRegistry` rather than
/// maintained by hand"*. That was true, then the test that made it true went missing, and the
/// sentence stayed. This is the test again.
final class CoverageReconciliationTests: XCTestCase {

    private struct Row {
        let source: String, function: String, status: String
    }

    private func matrix() throws -> [Row] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let path = root
            .appendingPathComponent("project/plans/proposals/Excel conformance")
            .appendingPathComponent("excel_function_coverage_matrix.tsv")
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            throw XCTSkip("coverage matrix not found at \(path.path)")
        }
        // `\r\n` is a single Character in Swift, so splitting on `"\n"` would return a
        // matrix written on Windows as one element holding the whole file — and the
        // reconciliation would then find nothing recorded and say so in the wrong words.
        return text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count > 3 else { return nil }
            return Row(source: String(f[0]), function: String(f[1]), status: String(f[3]))
        }
    }

    /// **Every row marked `have` is a function the registry answers to.**
    ///
    /// The direction that matters: a row claiming more than the code delivers is the one that
    /// reaches a reader. The reverse — a function implemented and not yet recorded — is
    /// untidy rather than untrue, and is reported below without failing.
    func testEveryRowMarkedHaveIsRegistered() throws {
        let registry = FunctionRegistry.builtin
        let claimed = try matrix().filter { $0.status == "have" }
        let absent = claimed.filter { registry.function(named: $0.function) == nil }

        XCTAssertTrue(absent.isEmpty, """
            \(absent.count) rows are marked `have` and are not in the registry:
            \(absent.map { "  \($0.source) \($0.function)" }.joined(separator: "\n"))
            Either implement them or change the status. A matrix that overstates is worse \
            than one that is behind.
            """)
    }

    /// A row marked `new` is one Excel documents and this package does not implement.
    ///
    /// Asserted in the other direction, because `new` is a promise *not* to have it: a `new`
    /// row that quietly became implemented is a coverage figure nobody updated.
    func testRowsMarkedNewAreNotRegistered() throws {
        let registry = FunctionRegistry.builtin
        let unexpected = try matrix()
            .filter { $0.status == "new" }
            .filter { registry.function(named: $0.function) != nil }

        XCTAssertTrue(unexpected.isEmpty, """
            \(unexpected.count) rows are marked `new` and *are* registered:
            \(unexpected.map { "  \($0.source) \($0.function)" }.joined(separator: "\n"))
            Move them to `have`; the coverage figures are derived from this column.
            """)
    }

    /// The Excel side of the matrix is Microsoft's whole published list.
    ///
    /// 519 rows, which is what makes "473 of 519" a coverage figure rather than a ratio of
    /// the rows somebody happened to type in.
    func testTheExcelSideIsTheWholeDocumentedList() throws {
        let excel = try matrix().filter { $0.source == "EXCEL" }
        XCTAssertEqual(excel.count, 519,
                       "the matrix should carry every documented worksheet function")
    }

    /// What the registry holds that the matrix does not mention.
    ///
    /// A measurement rather than an assertion — an alias or an internal helper can
    /// legitimately be registered without a row, and asserting a number here would fail the
    /// next time one is added.
    func testReportWhatIsRegisteredAndUnrecorded() throws {
        let recorded = Set(try matrix()
            .filter { $0.status == "have" }
            .map { FunctionRegistry.canonical($0.function) })
        let registry = FunctionRegistry.builtin

        print("""

        ── Coverage, reconciled ────────────────────────────────────
          registry holds        \(registry.count)
          matrix rows `have`    \(recorded.count)
        ────────────────────────────────────────────────────────────

        """)
        XCTAssertGreaterThan(recorded.count, 0, "the matrix recorded nothing")
    }
}
