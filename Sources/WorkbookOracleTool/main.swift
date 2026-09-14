import Foundation
#if canImport(os)
import os
#endif
import SwiftExcelCore
import SwiftExcelFunctions
import SwiftXLSX
import WorkbookAudit

/// Writes one line to stderr, and to the system log where there is one.
func report(_ message: String) {
    FileHandle.standardError.write(Data(("oracle: " + message + "\n").utf8))
    #if canImport(os)
    // Public privacy: a path the operator named and this program's account of it.
    Logger(subsystem: "WorkbookOracle", category: "run")
        .error("\(message, privacy: .public)")
    #endif
}

/// A line of the report, which is this program's output rather than its logging.
func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// Runs the Excel oracle over a corpus, and writes down what disagreed.
///
/// ## Why this is a program and not a test
///
/// It was a test, and a run of it against 2,240 workbooks was killed at two and a half
/// minutes having produced nothing whatever. That is the third time this project has learned
/// the same thing: an `XCTestCase` over a large corpus prints only at the end, cannot resume,
/// and gives no way to tell a working run from a hung one. The workbook census was abandoned
/// twice before being rewritten this way.
///
/// So: a row per workbook, flushed as it goes, with the output file as the resume state —
/// and a second file naming every cell that disagreed, because a tally says *how many* and
/// triage needs *which*.
///
/// ```
/// swift run workbook-oracle ~/Documents --out oracle.tsv --findings findings.tsv
/// ```
struct OracleRun {

    let root: URL
    let output: URL
    let findings: URL
    let progressEvery: Int
    let limit: Int?

    func run() throws {
        let already = try completedPaths()
        let books = try workbooks()
        let remaining = books.filter { !already.contains($0) }
        let batch = limit.map { Array(remaining.prefix($0)) } ?? remaining

        report("\(books.count) workbooks under \(root.path)")
        report("\(already.count) already done, \(remaining.count) to go")
        if batch.count < remaining.count {
            report("limited to \(batch.count) this run; \(remaining.count - batch.count) left")
        }

        guard let summary = try open(output, header: Row.header),
              let detail = try open(findings, header: Finding.header) else {
            throw Failure.cannotWrite
        }
        defer {
            try? summary.close()
            try? detail.close()
        }

        var done = 0
        var total = Tally()
        for path in batch {
            let (row, cells) = examine(path)
            write(row.line, to: summary, what: path)
            for cell in cells {
                write(cell.line, to: detail, what: path)
                total.count(cell)
            }
            total.add(row)
            done += 1
            if done % progressEvery == 0 {
                report("\(done)/\(batch.count)  running agreement \(total.agreementText)")
            }
        }

        say("")
        say("workbooks \(done)   comparable \(total.comparable)   agreement \(total.agreementText)")
        say("  agreed \(total.agreed)  agreedOnError \(total.agreedOnError)")
        say("  differed \(total.differed)  refused \(total.refused)  threw \(total.threw)")
        say("  notComparable \(total.notComparable)")
        say("")
        say("disagreements by function:")
        for (name, count) in total.byFunction.sorted(by: { $0.value > $1.value }).prefix(25) {
            // Padded by hand: `String(format:)` bridges to the C printf ABI, where `%@`
            // expects an object pointer and a Swift `String` is not one.
            let figure = String(count)
            let padding = String(repeating: " ", count: max(0, 6 - figure.count))
            say("  \(padding)\(figure)  \(name)")
        }
        say("")
        say("every disagreeing cell is in \(findings.path)")
    }

    // MARK: - One workbook

    private func examine(_ path: String) -> (Row, [Finding]) {
        let url = root.standardized.appendingPathComponent(path)
        let workbook: Workbook
        do {
            workbook = try Workbook(contentsOf: url)
        } catch let failure {
            report("unreadable \(path): \(failure)")
            #if canImport(os)
            Logger(subsystem: "WorkbookOracle", category: "run")
                .error("unreadable \(path, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
            return (Row(path: path, unreadable: String(describing: failure)), [])
        }

        let report = WorkbookOracle.audit(workbook)
        let tally = report.tally
        let row = Row(path: path, tally: tally, comparable: report.comparable,
                      agreement: report.agreement)
        // Only the cells worth looking at. An agreement needs no evidence kept.
        let interesting = report.findings.filter {
            switch $0.outcome {
            case .differed, .refused, .threw: return true
            case .agreed, .agreedOnError, .notComparable: return false
            }
        }
        return (row, interesting.map { Finding(path: path, finding: $0) })
    }

    // MARK: - Files

    private func write(_ line: String, to handle: FileHandle, what path: String) {
        handle.write(Data((line + "\n").utf8))
        do {
            try handle.synchronize()
        } catch let failure {
            report("flush failed after \(path): \(failure)")
            #if canImport(os)
            Logger(subsystem: "WorkbookOracle", category: "run")
                .error("flush failed after \(path, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
        }
    }

    private func completedPaths() throws -> Set<String> {
        let text: String
        do {
            text = try String(contentsOf: output, encoding: .utf8)
        } catch let failure {
            report("no existing run at \(output.path), starting fresh (\(failure))")
            #if canImport(os)
            Logger(subsystem: "WorkbookOracle", category: "run")
                .error("starting fresh: \(String(describing: failure), privacy: .public)")
            #endif
            return []
        }
        return Set(text.split(whereSeparator: \.isNewline)
            .compactMap { Row.path(ofLine: String($0)) })
    }

    private func open(_ url: URL, header: String) throws -> FileHandle? {
        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return handle
        } catch let failure {
            // Not an error: a file that does not exist yet is the ordinary first run. Said
            // rather than swallowed, because "created it" and "appended to it" look
            // identical afterwards and only one of them means the resume found nothing.
            report("creating \(url.lastPathComponent) (\(failure))")
            #if canImport(os)
            Logger(subsystem: "WorkbookOracle", category: "run")
                .error("creating \(url.lastPathComponent, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
            try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            return handle
        }
    }

    private func workbooks() throws -> [String] {
        let base = root.standardized.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw Failure.notADirectory(base.path)
        }
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        var found: [String] = []
        for case let url as URL in walker {
            guard url.pathExtension == "xlsx", !url.lastPathComponent.hasPrefix("~$") else {
                continue
            }
            let resolved = url.standardized.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(prefix) else { continue }
            found.append(String(resolved.dropFirst(prefix.count)))
        }
        return found.sorted()
    }

    enum Failure: Error, CustomStringConvertible {
        case usage
        case cannotWrite
        case notADirectory(String)

        var description: String {
            switch self {
            case .usage:
                return "usage: workbook-oracle <root> [--out oracle.tsv] "
                    + "[--findings findings.tsv] [--every N] [--limit N]"
            case .cannotWrite: return "cannot open the output files"
            case .notADirectory(let path): return "not a directory: \(path)"
            }
        }
    }
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, default fallback: String) -> String {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return fallback
    }
    return arguments[index + 1]
}

do {
    guard let rootPath = arguments.first, !rootPath.hasPrefix("--") else {
        throw OracleRun.Failure.usage
    }
    try OracleRun(
        root: URL(fileURLWithPath: rootPath, isDirectory: true),
        output: URL(fileURLWithPath: option("--out", default: "oracle.tsv")),
        findings: URL(fileURLWithPath: option("--findings", default: "findings.tsv")),
        progressEvery: Int(option("--every", default: "50")) ?? 50,
        limit: arguments.firstIndex(of: "--limit")
            .flatMap { _ in Int(option("--limit", default: "")) }
    ).run()
} catch let failure {
    report("\(failure)")
    #if canImport(os)
    Logger(subsystem: "WorkbookOracle", category: "run")
        .error("\(String(describing: failure), privacy: .public)")
    #endif
    exit(1)
}
