import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// Master plan priority 4 — *"Review the unreviewed before treating any of it as new
/// work."*
///
/// `unreviewed` means no evidence either way, which is **not** the same as absent. The
/// matrix's `have` column is reconciled against the live registry, but nothing has ever
/// asked the registry about the rows marked `unreviewed` — so some of them may already
/// answer, through a binding added for another reason or through the alias table.
///
/// This asks. It is a measurement rather than an assertion: what the registry answers is
/// a fact to discover, and asserting a particular count would fail the moment someone
/// binds one more function.
final class UnreviewedCoverageTests: XCTestCase {

    /// The matrix, as rows of `(source, function, category, status)`.
    private func matrix() throws -> [(source: String, function: String, category: String, status: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SwiftExcelFunctionsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
        let path = root
            .appendingPathComponent("project/plans/proposals/Excel conformance")
            .appendingPathComponent("excel_function_coverage_matrix.tsv")

        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            throw XCTSkip("coverage matrix not found at \(path.path)")
        }

        // `whereSeparator:` rather than `split(separator: "\n")`. In Swift `\r\n` is a
        // single `Character`, so splitting on the newline literal does not match it and a
        // file written on Windows comes back as one element holding the whole document —
        // which would read as "the matrix has no rows" rather than as an error.
        return text.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 4 else { return nil }
            return (String(fields[0]), String(fields[1]), String(fields[2]), String(fields[3]))
        }
    }

    /// How much of the unreviewed bucket the registry already answers.
    ///
    /// The master plan's expectation is that *"most is math, engineering and text —
    /// largely Foundation, libm and swift-numerics — so a large share should resolve to
    /// near-free."* This is the number that says whether that is true, and where the
    /// remaining work actually is.
    func testHowMuchOfTheUnreviewedBucketAlreadyAnswers() throws {
        let registry = FunctionRegistry.builtin
        let unreviewed = try matrix().filter { $0.source == "EXCEL" && $0.status == "unreviewed" }

        var answered: [String: [String]] = [:]     // category -> functions
        var absent: [String: [String]] = [:]

        for row in unreviewed {
            let name = FunctionRegistry.canonical(row.function)
            if registry.function(named: name) != nil {
                answered[row.category, default: []].append(row.function)
            } else {
                absent[row.category, default: []].append(row.function)
            }
        }

        let answeredCount = answered.values.map(\.count).reduce(0, +)
        let total = unreviewed.count
        let share = total > 0 ? Double(answeredCount) / Double(total) * 100 : 0

        var table = ""
        for category in Set(answered.keys).union(absent.keys).sorted() {
            let yes = answered[category]?.count ?? 0
            let no = absent[category]?.count ?? 0
            table += "  \(category.padding(toLength: 16, withPad: " ", startingAt: 0))"
                + "\(yes) answer, \(no) absent\n"
        }

        let readyToBind = absent
            .sorted { $0.value.count > $1.value.count }
            .prefix(4)
            .map { "    \($0.key): \($0.value.prefix(12).joined(separator: " "))" }
            .joined(separator: "\n")

        print("""

        ── The unreviewed bucket, asked ────────────────────────────
          unreviewed (EXCEL)   \(total)
          already answer       \(answeredCount)  (\(Int(share.rounded()))%)
          still absent         \(total - answeredCount)

        \(table)
          the largest absent categories
        \(readyToBind)
        ────────────────────────────────────────────────────────────

        """)

        XCTAssertGreaterThan(total, 0, "the matrix had no unreviewed EXCEL rows")
    }
}
