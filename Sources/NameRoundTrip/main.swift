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
/// swift run name-round-trip ~/Documents --out names.tsv
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

    func run() throws {
        let done = completed()
        let all = try workbooks()
        let remaining = all.filter { !done.contains($0) }
        complain("\(all.count) workbooks under \(root.path)")
        complain("\(done.count) already measured, \(remaining.count) to go")

        let handle = try open()
        defer { try? handle.close() }

        var books = 0, names = 0, exact = 0, unparsed = 0, mismatched = 0
        for path in remaining {
            let row = measure(path)
            write(row.line, to: handle)
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

do {
    guard let path = arguments.first, !path.hasPrefix("--") else {
        complain("usage: name-round-trip <corpus-root> [--out names.tsv] [--every N]")
        exit(2)
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
