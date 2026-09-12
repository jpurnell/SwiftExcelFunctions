import Foundation
#if canImport(os)
import os
#endif
import SwiftExcelCore
import SwiftExcelFunctions
import SwiftXLSX
import WorkbookContainer


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

    /// How many workbooks to examine this run, or `nil` for all of them.
    ///
    /// **Batching needs no state of its own.** The file is the resume state, so a limited
    /// run is simply a run that stops early and a later one continues — which is also what
    /// stopping it by hand has always done. The option exists so a batch can be *chosen*
    /// rather than guessed at with a stopwatch.
    let limit: Int?

    /// A password to try on encrypted workbooks, or `nil` to record them as locked.
    ///
    /// One password for a whole corpus is a blunt instrument, and deliberately so: the
    /// census is not a cracker. It exists so a scan of a directory whose files share a
    /// known password can report what is *in* them rather than only that they are shut.
    let password: String?

    /// How many extra attempts a transient read failure is worth.
    private static let retries = 3

    /// Seconds to wait before the first retry, multiplied by the attempt number.
    ///
    /// A dataless file takes a moment to fetch and the request is already in flight by the
    /// time the first attempt fails, so this backs off rather than hammering.
    private static let backoff = 0.75

    /// Runs the census, resuming from whatever the output file already holds.
    func run() throws {
        let already = try completedPaths()
        let books = try workbooks()
        let remaining = books.filter { !already.contains($0) }

        // A limited run is never a silent truncation: what it left behind is stated, so a
        // partial census cannot be mistaken for a complete one by whoever reads the file.
        let batch = limit.map { Array(remaining.prefix($0)) } ?? remaining

        report("\(books.count) workbooks under \(root.path)")
        report("\(already.count) already answered, \(remaining.count) to go")
        if batch.count < remaining.count {
            report("limited to \(batch.count) this run; \(remaining.count - batch.count) left for the next")
        }
        report("writing \(output.path)")

        guard let handle = try openForAppending() else {
            throw CensusError.cannotWrite(output.path)
        }
        defer { try? handle.close() }

        var done = 0
        for path in batch {
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
                report("\(done)/\(batch.count) \(row.line)")
            }
        }
        let deferred = remaining.count - batch.count
        report("finished \(done) workbooks" + (deferred > 0 ? ", \(deferred) left for the next run" : ""))
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
        switch readBytes(at: url, path: path) {
        case .success(let bytes):
            data = bytes
        case .failure(let failure):
            // Recorded rather than discarded. "Unreadable" without a reason is a row that
            // teaches nothing, and a census exists to teach. But a failure that will clear
            // on its own is recorded as *deferred*, so resuming retries it rather than
            // writing it off — see `TransientRead`.
            let deferrable = TransientRead.isTransient(failure)
            report("\(deferrable ? "deferring" : "unreadable file") \(path): \(failure)")
            #if canImport(os)
            Logger(subsystem: "WorkbookCensus", category: "scan")
                .error("\(deferrable ? "deferring" : "unreadable file", privacy: .public) \(path, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
            return CensusRow(path: path, outcome: deferrable ? .transientFailure : .unreadableFile,
                             solverNames: 0, models: 0, engines: [], relations: [],
                             milliseconds: elapsed(), detail: String(describing: failure))
        }
        // What the bytes *are*, before asking a ZIP reader to make sense of them. An
        // encrypted workbook and a mislabelled text file both fail as "damaged" otherwise,
        // and neither is damaged.
        let kind = ContainerKind(of: data)
        var payload = data
        switch kind {
        case .compoundFile:
            // With a password, an encrypted workbook is just a workbook. Without one, being
            // locked is the finding — and a password that does not fit says so plainly,
            // rather than being reported as damage.
            guard let password else {
                return CensusRow(path: path, outcome: .encryptedWorkbook, solverNames: 0,
                                 models: 0, engines: [], relations: [], milliseconds: elapsed(),
                                 detail: "ECMA-376 encrypted; a password would be needed")
            }
            do {
                payload = try WorkbookDecryptor.decrypt(data, password: password)
            } catch let failure {
                report("locked \(path): \(failure)")
                #if canImport(os)
                Logger(subsystem: "WorkbookCensus", category: "scan")
                    .error("locked \(path, privacy: .public): \(String(describing: failure), privacy: .public)")
                #endif
                return CensusRow(path: path, outcome: .encryptedWorkbook, solverNames: 0,
                                 models: 0, engines: [], relations: [], milliseconds: elapsed(),
                                 detail: String(describing: failure))
            }
        case .unrecognised:
            return CensusRow(path: path, outcome: .notAWorkbook, solverNames: 0, models: 0,
                             engines: [], relations: [], milliseconds: elapsed(),
                             detail: "not a ZIP or compound file — the extension is wrong")
        case .zip:
            break
        }

        let workbook: Workbook
        do {
            workbook = try Workbook(xlsxData: payload)
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

    /// Reads a workbook's bytes, trying again where the failure is one that clears.
    ///
    /// A dataless file — one the provider holds in the cloud and materialises on demand —
    /// fails with `ETIMEDOUT` while the fetch is still in flight, and succeeds seconds
    /// later. Retrying here is what keeps that out of the census file, and
    /// ``TransientRead`` is what decides which failures qualify.
    ///
    /// - Parameters:
    ///   - url: The workbook.
    ///   - path: Its path relative to the root, for reporting.
    /// - Returns: The bytes, or the last failure if every attempt failed.
    private func readBytes(at url: URL, path: String) -> Result<Data, Error> {
        // Bounded by construction: `retries` extra attempts, then one final attempt whose
        // failure is the one reported. A count that cannot be exceeded is worth more here
        // than a tidier loop — this runs unattended over thousands of files.
        for attempt in 0..<Census.retries {
            do {
                return .success(try Data(contentsOf: url))
            } catch let failure {
                // A permanent failure ends it immediately; there is nothing to wait for.
                guard TransientRead.isTransient(failure) else { return .failure(failure) }
                report("retry \(attempt + 1)/\(Census.retries) for \(path): \(failure)")
                #if canImport(os)
                Logger(subsystem: "WorkbookCensus", category: "scan")
                    .error("retry \(attempt + 1, privacy: .public) for \(path, privacy: .public): \(String(describing: failure), privacy: .public)")
                #endif
                Thread.sleep(forTimeInterval: Census.backoff * Double(attempt + 1))
            }
        }
        do {
            return .success(try Data(contentsOf: url))
        } catch let failure {
            report("giving up on \(path) after \(Census.retries) retries: \(failure)")
            #if canImport(os)
            Logger(subsystem: "WorkbookCensus", category: "scan")
                .error("giving up on \(path, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
            return .failure(failure)
        }
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
        // `completedPath` rather than `path`: a deferred row is a row, but it is not an
        // answer, and resuming past it would make a momentary timeout permanent.
        return Set(text.split(whereSeparator: \.isNewline)
            .compactMap { CensusRow.completedPath(ofLine: String($0)) })
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
        case .usage:
            return "usage: workbook-census <root> [--out census.tsv] [--every N] [--limit N] [--password P]"
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
    progressEvery: Int(option("--every", default: "100")) ?? 100,
    limit: arguments.firstIndex(of: "--limit").flatMap { _ in Int(option("--limit", default: "")) },
    password: arguments.firstIndex(of: "--password").map { _ in option("--password", default: "") })

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
