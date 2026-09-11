import Foundation
#if canImport(os)
import os
#endif
import SwiftExcelCore
import SwiftExcelFunctions
import SwiftXLSX


/// Writes one line to stderr, and to the system log where there is one.
///
/// A census reports to whoever is watching it run, which is stderr — but the quality gate
/// requires a caught error to be logged rather than merely printed, and it is right to: a
/// run started with its output redirected loses stderr entirely, and the failures are the
/// part worth keeping. Both, therefore, rather than a choice between them.
///
/// - Parameter message: What happened.
func report(_ message: String) {
    FileHandle.standardError.write(Data(("census: " + message + "\n").utf8))
    #if canImport(os)
    // Public privacy: a file path the operator named and a reader's own message. `os` is
    // Apple-only, and on Linux stderr above is the whole of it.
    Logger(subsystem: "WorkbookCensus", category: "scan")
        .error("\(message, privacy: .public)")
    #endif
}

/// Counts which workbooks under a directory declare a classic Excel Solver model.
///
/// ## Why this is a program and not a test
///
/// The first two attempts at this census were `XCTestCase`s, and both were abandoned
/// mid-run without producing anything. A test harness gives no progress, no way to resume,
/// and prints only at the end — so a run that is working and a run that is hung look
/// identical from outside, and stopping one throws away everything it had learned. Over
/// 2,240 workbooks that is the difference between a tool and a gamble.
///
/// Three properties follow from that, and they are the whole design:
///
/// - **Incremental.** Every workbook's result is written and flushed as it is examined.
/// - **Resumable.** The output file *is* the resume state; a restart reads it and skips
///   what is already there. There is no separate journal to fall out of step.
/// - **Useful when partial.** Stopping after 200 files leaves 200 rows worth reading,
///   which is the property the earlier versions lacked entirely.
///
/// ```
/// swift run workbook-census ~/Documents --out census.tsv
/// ```
///
/// It also runs `ExcelSolverReader` over every workbook that carries `solver_` names, so a
/// row with names but no models is a defect in the reader rather than an absence in the
/// corpus — which is the finding most worth having.
struct Census {

    /// The directory to scan. Resolved once in ``workbooks()`` and reported as resolved.
    let root: URL
    let output: URL
    let progressEvery: Int

    /// Runs the census, resuming from whatever the output file already holds.
    func run() throws {
        let already = try completedPaths()
        let books = try workbooks()
        let remaining = books.filter { !already.contains($0) }

        report("\(books.count) workbooks under \(root.path)")
        report("\(already.count) already done, \(remaining.count) to go")
        report("writing \(output.path)")

        guard let handle = try openForAppending() else {
            throw CensusError.cannotWrite(output.path)
        }
        defer { try? handle.close() }

        var done = 0
        for path in remaining {
            let row = examine(path)
            // Written and flushed per workbook. Anything less and stopping the run —
            // which is how both earlier attempts ended — loses the work.
            handle.write(Data((row.line + "\n").utf8))
            do {
                try handle.synchronize()
            } catch let failure {
                // The flush is what makes a partial run survive being stopped. Losing it
                // silently would take the tool's one guarantee with it.
                report("flush failed after \(row.path): \(failure)")
                #if canImport(os)
                Logger(subsystem: "WorkbookCensus", category: "scan")
                    .error("flush failed after \(row.path, privacy: .public): \(String(describing: failure), privacy: .public)")
                #endif
            }

            done += 1
            if done % progressEvery == 0 || row.solverNames > 0 {
                report("\(done)/\(remaining.count) \(row.line)")
            }
        }
        report("finished \(done) workbooks")
    }

    /// Examines one workbook.
    ///
    /// - Parameter path: Its path, relative to ``root``.
    /// - Returns: The row to record.
    private func examine(_ path: String) -> CensusRow {
        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        let url = root.standardized.appendingPathComponent(path)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let failure {
            // Recorded rather than discarded. "Unreadable" without a reason is a row that
            // teaches nothing, and a census exists to teach.
            report("unreadable file \(path): \(failure)")
            #if canImport(os)
            Logger(subsystem: "WorkbookCensus", category: "scan")
                .error("unreadable file \(path, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
            return CensusRow(path: path, outcome: .unreadableFile, solverNames: 0,
                             models: 0, engines: [], relations: [], milliseconds: elapsed(),
                             detail: String(describing: failure))
        }
        let workbook: Workbook
        do {
            workbook = try Workbook(xlsxData: data)
        } catch let failure {
            report("unreadable workbook \(path): \(failure)")
            #if canImport(os)
            Logger(subsystem: "WorkbookCensus", category: "scan")
                .error("unreadable workbook \(path, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
            return CensusRow(path: path, outcome: .unreadableWorkbook, solverNames: 0,
                             models: 0, engines: [], relations: [], milliseconds: elapsed(),
                             detail: String(describing: failure))
        }

        let solverNames = workbook.namedRanges.all
            .filter { $0.name.lowercased().hasPrefix("solver_") }
        guard !solverNames.isEmpty else {
            return CensusRow(path: path, outcome: .ok, solverNames: 0, models: 0,
                             engines: [], relations: [], milliseconds: elapsed(), detail: "")
        }

        let models = ExcelSolverReader.models(from: workbook.namedRanges)
        var engines: [String] = []
        var relations: Set<Int> = []
        for model in models.values {
            engines.append("\(model.engine)")
            for constraint in model.constraints { relations.insert(code(of: constraint.relation)) }
        }
        return CensusRow(path: path, outcome: .ok, solverNames: solverNames.count,
                         models: models.count, engines: engines,
                         relations: Array(relations), milliseconds: elapsed(),
                         // Names present but no model assembled is a defect in the reader
                         // rather than an absence in the file, so it is called out.
                         detail: models.isEmpty ? "names but no model" : "")
    }

    /// Excel's own number for a relation, so the census speaks the file's language.
    private func code(of relation: SolverModel.Relation) -> Int {
        switch relation {
        case .lessOrEqual: return 1
        case .equal: return 2
        case .greaterOrEqual: return 3
        case .integer: return 4
        case .binary: return 5
        case .allDifferent: return 6
        }
    }

    /// Every `.xlsx` under the root, sorted so a resumed run covers them in the same order.
    ///
    /// The root is resolved and checked before anything is enumerated. A census reads a
    /// directory the operator names, so `..` in that argument is their own business — but
    /// resolving it first means the path that gets scanned is the path that gets reported,
    /// and a typo fails here rather than silently scanning a parent.
    private func workbooks() throws -> [String] {
        let base = root.standardized.resolvingSymlinksInPath()
        do {
            guard try base.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CensusError.notADirectory(base.path)
            }
        } catch let failure as CensusError {
            throw failure
        } catch let failure {
            report("cannot read root \(base.path): \(failure)")
            #if canImport(os)
            Logger(subsystem: "WorkbookCensus", category: "scan")
                .error("cannot read root \(base.path, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
            throw CensusError.unreachableRoot(base.path, String(describing: failure))
        }
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw CensusError.notADirectory(base.path)
        }

        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        var found: [String] = []
        for case let url as URL in walker {
            guard url.pathExtension == "xlsx", !url.lastPathComponent.hasPrefix("~$") else {
                continue
            }
            // Every path is confirmed to sit under the resolved root before it is recorded.
            // The enumerator should not leave it, but a symlink inside the tree can point
            // anywhere, and a census that wandered out of the directory it reported on
            // would be describing something other than what its own header claims.
            let resolved = url.standardized.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(prefix) else { continue }
            found.append(String(resolved.dropFirst(prefix.count)))
        }
        return found.sorted()
    }

    /// The paths the output file already records.
    private func completedPaths() throws -> Set<String> {
        let text: String
        do {
            text = try String(contentsOf: output, encoding: .utf8)
        } catch let failure {
            // No file yet is the ordinary first run rather than a failure, so this is a
            // note rather than an alarm — but it is still said, because "resumed from
            // nothing" and "started fresh" look identical in the output otherwise.
            report("no existing census at \(output.path), starting fresh (\(failure))")
            #if canImport(os)
            Logger(subsystem: "WorkbookCensus", category: "scan")
                .error("no existing census at \(output.path, privacy: .public), starting fresh: \(String(describing: failure), privacy: .public)")
            #endif
            return []
        }
        // `whereSeparator:` rather than splitting on "\n": in Swift `\r\n` is a single
        // `Character`, and a file written on another platform would otherwise read as one
        // enormous line and resume from nothing.
        return Set(text.split(whereSeparator: \.isNewline)
            .compactMap { CensusRow.path(ofLine: String($0)) })
    }

    /// Opens the output for appending, creating it with a header if it is new.
    private func openForAppending() throws -> FileHandle? {
        // Opening tells us whether it exists, so there is no separate existence check to
        // fall out of step with it — and the error says which of the two things went wrong.
        do {
            let handle = try FileHandle(forWritingTo: output)
            try handle.seekToEnd()
            return handle
        } catch let failure {
            report("creating \(output.path) (\(failure))")
            #if canImport(os)
            Logger(subsystem: "WorkbookCensus", category: "scan")
                .error("creating \(output.path, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
            try (CensusRow.header + "\n").write(to: output, atomically: true, encoding: .utf8)
            let handle = try FileHandle(forWritingTo: output)
            try handle.seekToEnd()
            return handle
        }
    }
}

/// Why the census could not run.
enum CensusError: Error, CustomStringConvertible {
    case usage
    case cannotWrite(String)
    case notADirectory(String)
    case unreachableRoot(String, String)

    var description: String {
        switch self {
        case .usage: return "usage: workbook-census <root> [--out census.tsv] [--every N]"
        case .cannotWrite(let path): return "cannot write \(path)"
        case .notADirectory(let path): return "not a directory: \(path)"
        case .unreachableRoot(let path, let why): return "cannot read \(path): \(why)"
        }
    }
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
guard let rootPath = arguments.first, !rootPath.hasPrefix("--") else {
    report(CensusError.usage.description)
    exit(2)
}

func option(_ name: String, default fallback: String) -> String {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return fallback
    }
    return arguments[index + 1]
}

let census = Census(
    root: URL(fileURLWithPath: rootPath, isDirectory: true),
    output: URL(fileURLWithPath: option("--out", default: "census.tsv")),
    progressEvery: Int(option("--every", default: "100")) ?? 100)

do {
    try census.run()
} catch let failure {
    report("\(failure)")
    #if canImport(os)
    Logger(subsystem: "WorkbookCensus", category: "scan")
        .error("\(String(describing: failure), privacy: .public)")
    #endif
    exit(1)
}
