import Foundation
#if canImport(os)
import os
#endif
import SwiftExcelCore
import SwiftXLSX

/// Reads every workbook in a corpus, writes it back, reads it again, and compares the name
/// tables.
///
/// **The measurement that licenses reconstruction.** `PROPOSAL_defined_names.md` chose to
/// derive a name's refers-to text from its target rather than keep a copy of the original
/// beside it — one fact, one place, nothing that can drift. The cost is that every rule the
/// writer applies has to be right, and the reason to accept it is that being right is
/// *checkable*: read, write, read, and any name that comes back different has an address.
///
/// ```
/// swift run name-round-trip ~/Documents --out names.tsv --until-done
/// ```
///
/// ## A row per workbook, flushed, and the file is the resume state
///
/// **The first version of this printed only at the end.** It was killed after an hour having
/// produced nothing at all — the same failure the workbook census was abandoned for twice and
/// the Excel oracle was rewritten to escape, committed here a third time by the person who
/// wrote up the other two.
///
/// So: a row per workbook as it goes, flushed, and a re-run skips what the file already
/// holds. A run that is interrupted has still measured everything it reached, and a run in
/// progress can be read.
///
/// ## A workbook that kills the process is a finding, not an obstacle
///
/// The corpus contains files that do not merely fail to convert — they take the process down
/// with a Swift runtime trap, which is not an error any `catch` can see. The first one found
/// held a number near 1e19 and trapped in the writer.
///
/// A row cannot be written for a workbook that killed the run before the row existed, so the
/// path is written to a marker file *before* it is opened and cleared after. A run that finds
/// a stale marker knows exactly which workbook killed its predecessor, records it as that,
/// and moves past it. Run under `--until-done` the tool relaunches itself until the corpus is
/// exhausted, so one fatal workbook costs one workbook rather than the remainder of the run.
struct RoundTrip {

    let root: URL
    let output: URL
    let progressEvery: Int

    /// What one workbook came to.
    struct Row {
        let path: String
        let names: Int
        let exact: Int
        let unparsed: Int
        /// Why this workbook produced nothing comparable, if it did not.
        let note: String

        static let header = ["path", "names", "exact", "unparsed", "note"]
            .joined(separator: "\t")

        var line: String {
            [path, "\(names)", "\(exact)", "\(unparsed)", note]
                .map { $0.replacingOccurrences(of: "\t", with: " ") }
                .joined(separator: "\t")
        }

        /// The path a row records, for the resume.
        static func path(ofLine line: String) -> String? {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 2, fields[0] != "path" else { return nil }
            return String(fields[0])
        }
    }

    /// - Returns: `true` when the corpus is exhausted, `false` when work remains — which,
    ///   since the only way to leave work behind is to have been killed, cannot be returned
    ///   by the run it describes. It is what a relaunch reports about its predecessor.
    @discardableResult
    func run() throws -> Bool {
        var done = completed()
        let all = try workbooks()
        complain("\(all.count) workbooks under \(root.path)")

        let handle = try open()
        defer { try? handle.close() }

        // Whatever the last run was holding when it died.
        if let victim = abandoned(), !done.contains(victim) {
            complain("\(victim) killed the previous run; recording and skipping it")
            write(Row(path: victim, names: 0, exact: 0, unparsed: 0,
                      note: "killed the process").line, to: handle)
            done.insert(victim)
        }

        let remaining = all.filter { !done.contains($0) }
        complain("\(done.count) already measured, \(remaining.count) to go")

        var books = 0, names = 0, exact = 0, unparsed = 0, mismatched = 0
        for path in remaining {
            attempting(path)
            let row = measure(path)
            write(row.line, to: handle)
            attempting(nil)
            books += 1
            names += row.names
            exact += row.exact
            unparsed += row.unparsed
            mismatched += row.names - row.exact
            if books % progressEvery == 0 {
                complain("\(books)/\(remaining.count) · \(names) names · "
                    + "\(mismatched) differed · \(unparsed) unparsed")
            }
        }
        complain("done: \(names) names, \(exact) identical, \(mismatched) differed, "
            + "\(unparsed) via .unparsed")
        complain("every row is in \(output.path)")
        return true
    }

    // MARK: - The workbook in hand

    /// Where the path of the workbook being measured is kept, so that a run which does not
    /// survive it still says which one it was.
    private var marker: URL {
        output.deletingLastPathComponent()
            .appendingPathComponent(output.lastPathComponent + ".attempting")
    }

    private func attempting(_ path: String?) {
        do {
            guard let path else {
                try? FileManager.default.removeItem(at: marker)
                return
            }
            try path.write(to: marker, atomically: true, encoding: .utf8)
        } catch {
            #if canImport(os)
            Logger(subsystem: "NameRoundTrip", category: "marker")
                .error("could not mark \(path ?? "-", privacy: .public): \(String(describing: error), privacy: .public)")
            #endif
            complain("could not write the marker: \(error)")
        }
    }

    /// The workbook the previous run was holding when it died, if it died.
    private func abandoned() -> String? {
        let path: String
        do {
            path = try String(contentsOf: marker, encoding: .utf8)
        } catch {
            // The ordinary case: the last run cleared its marker, or there was no last run.
            #if canImport(os)
            Logger(subsystem: "NameRoundTrip", category: "marker")
                .error("no marker: \(String(describing: error), privacy: .public)")
            #endif
            return nil
        }
        attempting(nil)
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - One workbook

    private func measure(_ path: String) -> Row {
        let url = root.standardized.appendingPathComponent(path)
        let before: Workbook
        do {
            before = try Workbook(contentsOf: url)
        } catch {
            #if canImport(os)
            Logger(subsystem: "NameRoundTrip", category: "read")
                .error("unreadable \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            #endif
            return Row(path: path, names: 0, exact: 0, unparsed: 0, note: "unreadable")
        }

        let original = before.namedRanges.all
        guard !original.isEmpty else {
            return Row(path: path, names: 0, exact: 0, unparsed: 0, note: "no names")
        }

        let rewritten: [NamedRange]
        do {
            rewritten = try Workbook(xlsxData: try before.save()).namedRanges.all
        } catch {
            #if canImport(os)
            Logger(subsystem: "NameRoundTrip", category: "write")
                .error("round trip failed for \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            #endif
            return Row(path: path, names: original.count, exact: 0, unparsed: 0,
                       note: "could not be written or reread: \(error)")
        }

        guard rewritten.count == original.count else {
            return Row(path: path, names: original.count, exact: 0, unparsed: 0,
                       note: "\(original.count) names in, \(rewritten.count) out")
        }

        var exact = 0, unparsed = 0
        var firstDifference = ""
        for (was, now) in zip(original, rewritten) {
            if case .unparsed = was.reference { unparsed += 1 }
            if was == now {
                exact += 1
            } else if firstDifference.isEmpty {
                firstDifference = "\(was.name): was \(was.reference) · now \(now.reference)"
            }
        }
        return Row(path: path, names: original.count, exact: exact, unparsed: unparsed,
                   note: firstDifference)
    }

    // MARK: - The file

    private func open() throws -> FileHandle {
        do {
            let handle = try FileHandle(forWritingTo: output)
            try handle.seekToEnd()
            return handle
        } catch {
            // Not an error: a file that does not exist yet is the ordinary first run. Said
            // rather than swallowed, because "created it" and "appended to it" look identical
            // afterwards and only one of them means the resume found nothing.
            complain("creating \(output.lastPathComponent) (\(error))")
            #if canImport(os)
            Logger(subsystem: "NameRoundTrip", category: "output")
                .error("creating \(output.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            #endif
            try (Row.header + "\n").write(to: output, atomically: true, encoding: .utf8)
            let handle = try FileHandle(forWritingTo: output)
            try handle.seekToEnd()
            return handle
        }
    }

    private func write(_ line: String, to handle: FileHandle) {
        handle.write(Data((line + "\n").utf8))
        do {
            try handle.synchronize()
        } catch {
            #if canImport(os)
            Logger(subsystem: "NameRoundTrip", category: "output")
                .error("flush failed: \(String(describing: error), privacy: .public)")
            #endif
            complain("flush failed: \(error)")
        }
    }

    private func completed() -> Set<String> {
        let text: String
        do {
            text = try String(contentsOf: output, encoding: .utf8)
        } catch {
            complain("no existing run at \(output.path), starting fresh (\(error))")
            #if canImport(os)
            Logger(subsystem: "NameRoundTrip", category: "resume")
                .error("starting fresh: \(String(describing: error), privacy: .public)")
            #endif
            return []
        }
        return Set(text.split(whereSeparator: \.isNewline).compactMap {
            Row.path(ofLine: String($0))
        })
    }

    /// Every workbook under the root, **smallest first**.
    ///
    /// The order is not cosmetic. Sorted by path, the run reached its 55th workbook — a 40 MB
    /// file — and sat on it at 4 GB resident while 2,185 files it could have measured in
    /// minutes waited behind it. The corpus is 2,240 workbooks whose median is 29 KB and whose
    /// largest eighteen carry a third of the bytes, so path order hands the expensive tail to
    /// the part of the run most likely to be interrupted.
    ///
    /// Smallest first inverts that: an interrupted run has measured the most workbooks it
    /// could have, and what is left unmeasured is the handful that were always going to be
    /// slow. The resume set is keyed by path, so the order costs nothing.
    private func workbooks() throws -> [String] {
        let base = root.standardized.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: keys) else { return [] }
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        var found: [(path: String, size: Int)] = []
        for case let url as URL in walker
        where url.pathExtension == "xlsx" && !url.lastPathComponent.hasPrefix("~$") {
            let resolved = url.standardized.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(prefix) else { continue }
            // A file whose size will not answer sorts last, with the ones that are genuinely big.
            let size = (try? url.resourceValues(forKeys: Set(keys)))?.fileSize ?? .max
            found.append((String(resolved.dropFirst(prefix.count)), size))
        }
        return found.sorted { ($0.size, $0.path) < ($1.size, $1.path) }.map(\.path)
    }
}

/// A line about the run, which is not its result.
func complain(_ message: String) {
    FileHandle.standardError.write(Data(("round-trip: " + message + "\n").utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
func value(after name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

/// Runs the measurement again until it finishes.
///
/// A workbook that trapped took the process with it, and no amount of care inside the process
/// can change that — so the loop lives outside one. Each child records the workbook that
/// killed its predecessor before going on, which is what makes this terminate: every crash
/// costs exactly one workbook, and the remainder strictly shrinks.
///
/// - Parameter arguments: The run's own arguments, minus the flag that brought us here.
/// - Returns: The number of times the measurement died, which is the number of workbooks that
///   cannot be measured at all.
func untilDone(_ arguments: [String]) throws -> Int {
    let me = URL(fileURLWithPath: CommandLine.arguments.first ?? "name-round-trip")
    var deaths = 0
    // A backstop, not a bound: each death is recorded and skipped, so the work shrinks either
    // way. If this is ever reached, something is wrong with the recording rather than the data.
    for attempt in 1...10_000 {
        // Six hours is far past a whole corpus pass and far short of forever, which is the
        // only other thing an unbounded wait can mean. A child still running at the deadline
        // is stuck on one workbook, and is ended so the marker can name it.
        let ended = try ProcessRunner.run(me, arguments: arguments, timeout: .seconds(6 * 3600))
        if ended.succeeded {
            if deaths > 0 { complain("\(deaths) workbook(s) could not be measured at all") }
            return deaths
        }
        deaths += 1
        complain("run \(attempt) \(ended.timedOut ? "hit the deadline" : "died") "
            + "(\(ended.reason.rawValue)/\(ended.status)); starting again")
    }
    complain("gave up after 10,000 relaunches")
    return deaths
}

do {
    guard let path = arguments.first, !path.hasPrefix("--") else {
        complain("usage: name-round-trip <corpus-root> [--out names.tsv] [--every N] [--until-done]")
        exit(2)
    }
    if arguments.contains("--until-done") {
        exit(try untilDone(arguments.filter { $0 != "--until-done" }) == 0 ? 0 : 3)
    }
    try RoundTrip(
        root: URL(fileURLWithPath: path, isDirectory: true),
        output: URL(fileURLWithPath: value(after: "--out") ?? "names.tsv"),
        progressEvery: value(after: "--every").flatMap(Int.init) ?? 100
    ).run()
} catch {
    complain("\(error)")
    #if canImport(os)
    Logger(subsystem: "NameRoundTrip", category: "run")
        .error("\(String(describing: error), privacy: .public)")
    #endif
    exit(1)
}
