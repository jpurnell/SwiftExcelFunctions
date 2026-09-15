import Foundation
#if canImport(os)
import os
#endif
import SwiftExcelCore
import SwiftXLSX
import WorkbookAudit

/// Audits workbooks and says what is wrong with them.
///
/// ```
/// swift run xlsx-audit Model.xlsx
/// swift run xlsx-audit ~/Documents/models --experimental --tsv findings.tsv
/// ```
///
/// ## What it is for
///
/// A spreadsheet is a program that nobody reviews. This runs the checks a reviewer would:
/// circular references, cells whose cached value no longer follows from their formula, and
/// — opt-in — the one formula in a column that differs from its neighbours.
///
/// ## Exit codes, so CI can use it
///
/// `0` clean, `1` at least one finding of `error` severity, `2` nothing could be read. A
/// warning or a note does not fail the run: those are for a person to judge, and a check
/// that fails a build on a judgement call is a check that gets switched off.
struct Audit {

    /// The files and directories named on the command line.
    let inputs: [URL]

    /// Whether to run the checkers that have not earned a default.
    let experimental: Bool

    /// Where to write findings as TSV, if anywhere.
    let tsv: URL?

    /// Whether to print only the per-file summary lines.
    let quiet: Bool

    /// Run only the checker with this name, if given.
    ///
    /// What a census needs: a checker's false-positive rate is measured one checker at a
    /// time, and paying for the others on every workbook of a corpus is how a measurement
    /// becomes too slow to repeat.
    let only: String?

    func run() throws {
        let files = try workbooks()
        guard !files.isEmpty else { throw Failure.nothingToRead }

        let available = WorkbookAuditor.standard + WorkbookAuditor.experimental
        let chosen: [any WorkbookChecker]
        if let only {
            chosen = available.filter { type(of: $0).name == only }
            guard !chosen.isEmpty else {
                throw Failure.noSuchChecker(only, available.map { type(of: $0).name })
            }
        } else {
            chosen = experimental ? available : WorkbookAuditor.standard
        }
        let auditor = WorkbookAuditor(checkers: chosen)

        // Opened before the first workbook rather than written after the last. A run over
        // a corpus takes tens of minutes, and this project has three times killed a long
        // run that had produced nothing because its output came at the end.
        let sink = try tsv.map { try RowSink(url: $0) }
        defer { sink?.close() }

        var totals = Totals()
        for file in files {
            let workbook: Workbook
            do {
                workbook = try Workbook(contentsOf: file)
            } catch let failure {
                // Said, not skipped. A file that could not be opened is not a file that
                // passed, and a run that quietly drops three of thirty looks identical to
                // one that checked all thirty.
                complain("unreadable \(file.lastPathComponent): \(failure)")
                #if canImport(os)
                // Inline rather than inside `complain`: the logging checker is syntactic
                // and wants the call literally here, which is also where the error is.
                Logger(subsystem: "XlsxAudit", category: "run")
                    .error("unreadable \(file.lastPathComponent, privacy: .public): \(String(describing: failure), privacy: .public)")
                #endif
                totals.unreadable += 1
                continue
            }

            let findings = auditor.audit(workbook)
            totals.absorb(findings)
            totals.workbooks += 1
            if !findings.isEmpty { totals.workbooksWithFindings += 1 }

            say(header(for: file, findings: findings, of: files.count))
            if !quiet {
                for finding in findings { say(render(finding)) }
            }
            sink?.write(findings.map { row(for: $0, file: file) })
        }

        if let sink {
            say("")
            say("\(sink.written) findings written to \(sink.url.path)")
        }
        say("")
        say(totals.summary)
        if totals.workbooks == 0 { throw Failure.nothingToRead }
        if totals.errors > 0 { exit(1) }
    }

    // MARK: - Saying it

    /// The line that stands for one workbook.
    private func header(for file: URL, findings: [Finding], of count: Int) -> String {
        let name = count == 1 ? file.path : file.lastPathComponent
        guard !findings.isEmpty else { return "✓ \(name)" }
        let counts = Totals(findings)
        return "\(name) — \(counts.line)"
    }

    /// One finding, indented under its workbook.
    ///
    /// The detail is printed rather than summarised. A finding that says "inconsistent" and
    /// stops is a finding nobody acts on; what makes this worth reading is the two values
    /// and the formula that separates them.
    private func render(_ finding: Finding) -> String {
        let place = "\(finding.address.sheet)!\(finding.address.cell.reference)"
        var lines = ["  \(pad(finding.severity.rawValue))\(pad(finding.checker, 18))\(place)",
                     "      \(finding.summary)"]
        if let detail = finding.detail {
            lines.append(contentsOf: detail.split(whereSeparator: \.isNewline).map { "      \($0)" })
        }
        if !finding.related.isEmpty {
            let others = finding.related.prefix(8)
                .map { "\($0.sheet)!\($0.cell.reference)" }
                .joined(separator: ", ")
            let more = finding.related.count > 8 ? " (+\(finding.related.count - 8) more)" : ""
            lines.append("      related: \(others)\(more)")
        }
        return lines.joined(separator: "\n")
    }

    private func pad(_ text: String, _ width: Int = 9) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    // MARK: - Writing it down

    /// One finding as a row, for a spreadsheet or a diff.
    private func row(for finding: Finding, file: URL) -> String {
        [file.path, finding.address.sheet, finding.address.cell.reference,
         finding.checker, finding.severity.rawValue, finding.summary,
         (finding.detail ?? "").replacingOccurrences(of: "\n", with: " · "),
         finding.related.map { "\($0.sheet)!\($0.cell.reference)" }.joined(separator: " ")]
            .map { $0.replacingOccurrences(of: "\t", with: " ") }
            .joined(separator: "\t")
    }

    // MARK: - Finding the files

    /// Every workbook named, directories walked.
    ///
    /// Excel's lock files begin `~$` and are not workbooks; reading one reports corruption
    /// for a file that is working exactly as intended.
    private func workbooks() throws -> [URL] {
        var found: [URL] = []
        for named in inputs {
            // Standardized and resolved before anything reads it: `a/../b` and a symlink
            // are both paths that mean somewhere other than where they read, and a tool
            // that reports findings against a path had better report the real one.
            let input = named.standardized.resolvingSymlinksInPath()
            // `resourceValues` rather than `fileExists(atPath:)`: it asks the resolved URL
            // rather than a string, so the question is about the file this names and not
            // about whatever a path with a `..` in it might reach.
            let isDirectory: Bool
            do {
                isDirectory = try input.resourceValues(forKeys: [.isDirectoryKey])
                    .isDirectory ?? false
            } catch {
                throw Failure.noSuchPath(named.path)
            }

            guard isDirectory else {
                found.append(input)
                continue
            }
            guard let walker = FileManager.default.enumerator(
                at: input, includingPropertiesForKeys: [.isRegularFileKey]) else {
                throw Failure.noSuchPath(named.path)
            }
            // A symlink inside the tree can point outside it. Walking out of the directory
            // the operator named would audit files they did not ask about and report them
            // under a path that does not lead there.
            let prefix = input.path.hasSuffix("/") ? input.path : input.path + "/"
            for case let url as URL in walker
            where url.pathExtension == "xlsx" && !url.lastPathComponent.hasPrefix("~$") {
                let resolved = url.standardized.resolvingSymlinksInPath()
                guard resolved.path.hasPrefix(prefix) else { continue }
                found.append(resolved)
            }
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: - Counting

    /// What a run, or one workbook, came to.
    struct Totals {
        var workbooks = 0
        var workbooksWithFindings = 0
        var unreadable = 0
        var errors = 0
        var warnings = 0
        var notes = 0

        init() {}

        init(_ findings: [Finding]) {
            absorb(findings)
        }

        mutating func absorb(_ findings: [Finding]) {
            for finding in findings {
                switch finding.severity {
                case .error: errors += 1
                case .warning: warnings += 1
                case .note: notes += 1
                }
            }
        }

        /// The counts, in the order a reader cares about them.
        var line: String {
            [(errors, "error"), (warnings, "warning"), (notes, "note")]
                .filter { $0.0 > 0 }
                .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
                .joined(separator: ", ")
        }

        /// The last line of the run.
        var summary: String {
            guard workbooks > 0 else {
                return "nothing read\(unreadable > 0 ? " — \(unreadable) unreadable" : "")"
            }
            let clean = workbooks - workbooksWithFindings
            var text = "\(workbooks) workbook\(workbooks == 1 ? "" : "s"): "
                + "\(clean) clean, \(workbooksWithFindings) with findings"
            if unreadable > 0 { text += ", \(unreadable) unreadable" }
            if errors + warnings + notes > 0 { text += " — \(line)" }
            return text
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case usage
        case noSuchPath(String)
        case noSuchChecker(String, [String])
        case nothingToRead

        var description: String {
            switch self {
            case .usage:
                return """
                    usage: xlsx-audit <file-or-directory>… [--experimental] [--tsv FILE] [--quiet]

                      --experimental  also run checkers that have not earned a default
                      --only NAME     run one checker, named
                      --tsv FILE      write every finding as a row
                      --quiet         per-workbook summary lines only

                    exit 0 clean · 1 at least one error · 2 nothing could be read
                    """
            case .noSuchPath(let path): return "no such file or directory: \(path)"
            case .noSuchChecker(let name, let available):
                return "no checker called \(name) — try one of: \(available.joined(separator: ", "))"
            case .nothingToRead: return "no .xlsx files found"
            }
        }
    }
}

/// A TSV file written as the run goes, not after it.
///
/// Flushed per workbook, so a run that is interrupted — or watched — has told the truth up
/// to the moment it stopped. The same reason the census and the oracle are programs rather
/// than tests.
final class RowSink {

    /// Where the rows are going.
    let url: URL

    /// How many have been written.
    private(set) var written = 0

    private let handle: FileHandle

    /// Creates the file and writes its header.
    ///
    /// - Parameter url: where to write.
    init(url: URL) throws {
        let header = ["path", "sheet", "cell", "checker", "severity", "summary",
                      "detail", "related"].joined(separator: "\t")
        try (header + "\n").write(to: url, atomically: true, encoding: .utf8)
        self.handle = try FileHandle(forWritingTo: url)
        try self.handle.seekToEnd()
        self.url = url
    }

    /// Appends rows and flushes them.
    ///
    /// - Parameter rows: the rows, without trailing newlines.
    func write(_ rows: [String]) {
        guard !rows.isEmpty else { return }
        handle.write(Data((rows.joined(separator: "\n") + "\n").utf8))
        written += rows.count
        do {
            try handle.synchronize()
        } catch let failure {
            complain("flush failed: \(failure)")
            #if canImport(os)
            Logger(subsystem: "XlsxAudit", category: "output")
                .error("flush failed: \(String(describing: failure), privacy: .public)")
            #endif
        }
    }

    /// Closes the file.
    func close() {
        do {
            try handle.close()
        } catch let failure {
            complain("close failed: \(failure)")
            #if canImport(os)
            Logger(subsystem: "XlsxAudit", category: "output")
                .error("close failed: \(String(describing: failure), privacy: .public)")
            #endif
        }
    }
}

// MARK: - Output

/// A line of the report, which is this program's output.
func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// A line about the run itself, which is not.
func complain(_ message: String) {
    FileHandle.standardError.write(Data(("xlsx-audit: " + message + "\n").utf8))
    #if canImport(os)
    // Public privacy: a path the operator named and this program's account of it.
    Logger(subsystem: "XlsxAudit", category: "run")
        .error("\(message, privacy: .public)")
    #endif
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
let flags: Set<String> = ["--experimental", "--quiet", "--help", "-h"]

func value(after name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

do {
    let tsvPath = value(after: "--tsv")
    let onlyChecker = value(after: "--only")
    let paths = arguments.enumerated().filter { index, argument in
        guard !flags.contains(argument), !argument.hasPrefix("--") else { return false }
        // The value of an option is not a path.
        return index == 0 || !["--tsv", "--only"].contains(arguments[index - 1])
    }.map(\.element)

    guard !paths.isEmpty, !arguments.contains("--help"), !arguments.contains("-h") else {
        throw Audit.Failure.usage
    }
    try Audit(
        inputs: paths.map { URL(fileURLWithPath: $0) },
        experimental: arguments.contains("--experimental"),
        tsv: tsvPath.map { URL(fileURLWithPath: $0) },
        quiet: arguments.contains("--quiet"),
        only: onlyChecker
    ).run()
} catch let failure {
    complain("\(failure)")
    #if canImport(os)
    Logger(subsystem: "XlsxAudit", category: "run")
        .error("\(String(describing: failure), privacy: .public)")
    #endif
    exit(2)
}
