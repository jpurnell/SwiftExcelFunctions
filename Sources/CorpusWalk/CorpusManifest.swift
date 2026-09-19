import Foundation
#if canImport(os)
import os
#endif

/// The list of workbooks under a root, written down as it is discovered.
///
/// ## Why this exists
///
/// This project has a rule, written on `Row` and again in the census: **the output file is
/// the resume state.** It was honoured for the audit and not for the walk that feeds it, and
/// the walk turned out to be the expensive half.
///
/// On 2026-09-19 the oracle was started over `~/Documents`. It spent four minutes inside
/// `NSURLDirectoryEnumerator.nextObject` — a Dropbox-backed tree, so the enumeration was
/// I/O-bound and slow — and the machine shut down before the first workbook was audited. The
/// run had written nothing whatever, and nothing could be resumed, because the thing it had
/// spent its whole life doing was held in memory. It also could not be told apart from a hung
/// process without `sample`-ing it, which is the *other* half of the same rule: a long run
/// that says nothing is indistinguishable from a broken one.
///
/// So the enumeration gets the same treatment the audit already had:
///
/// - **A line per workbook, flushed as it is found.** The manifest is the walk's resume state.
/// - **A checkpoint per top-level directory.** The enumerator has no cursor to save, so resume
///   is at the granularity of the root's immediate children: a subtree marked done is never
///   walked again, and one interrupted halfway is walked from its start rather than the
///   corpus's.
/// - **A completion line.** A manifest without one is partial, and the difference matters:
///   trusting a truncated list would silently shrink the corpus, and a run that audits 200
///   workbooks and reports on 200 looks exactly like a correct run over a corpus of 200.
/// - **A word about each directory as it starts.** Silence is what made the lost run
///   ambiguous.
///
/// ## What is deliberately not written down
///
/// **A directory that could not be read is never checkpointed**, and a walk that hit one never
/// writes its completion line. The census learned this the expensive way: its output is its
/// resume state too, so a failure recorded is a failure for ever, and one afternoon 42
/// workbooks were written off as unreadable on a timeout that had cleared minutes later. A
/// checkpoint written over a momentary failure would do exactly that to a whole subtree, and
/// nothing afterwards would say so — the manifest would simply describe a smaller corpus.
///
/// ## The format
///
/// Tab-separated, one record per line, in the order they were learned:
///
/// ```
/// root     /Users/someone/Documents
/// file     Budgets/2025.xlsx
/// dir      Budgets
/// complete 1
/// ```
///
/// The `root` line is what makes a manifest safe to find lying about. Pointing a new corpus at
/// an old manifest would otherwise return another directory's paths, and every one of them
/// would fail to open — a confusing way to learn that two runs shared a filename.
public struct CorpusManifest {

    /// Why a corpus could not be enumerated.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// The root is not a directory, or could not be read at all.
        case unreadableRoot(String, String)
        /// The manifest could not be opened or created.
        case cannotWrite(String)

        /// What went wrong, in a line an operator can act on.
        ///
        /// Both cases carry the path, because a corpus run is started from a shell with a
        /// path in the command and the first question about any of these is *which one*.
        public var description: String {
            switch self {
            case .unreadableRoot(let path, let reason):
                return "cannot read the corpus root \(path): \(reason)"
            case .cannotWrite(let path):
                return "cannot write the manifest at \(path)"
            }
        }
    }

    /// The directory the corpus lives in.
    private let root: URL
    /// The file the enumeration is written to, which is also where it is resumed from.
    private let location: URL
    /// Where progress goes. The default discards it, which is right for a test and wrong for
    /// a four-minute walk.
    private let report: (String) -> Void

    /// The pseudo-directory standing for workbooks sitting directly in the root.
    ///
    /// It is a segment like any other so that it is checkpointed like any other; without it,
    /// a crash after the last real directory would lose the root's own files.
    private static let rootSegment = "."

    /// How deep to follow `NSUnderlyingErrorKey` before giving up.
    ///
    /// A bound rather than a recursion, because an error chain is supplied by whatever
    /// framework built it and nothing here guarantees it is acyclic. The census bounds its
    /// own chain-walking the same way and for the same reason.
    private static let maximumDepth = 8

    /// Prepares to enumerate `root`, keeping the result in `location`.
    ///
    /// - Parameters:
    ///   - root: the directory the corpus lives in.
    ///   - location: the manifest file — read for a resume, appended to as the walk proceeds.
    ///   - report: where progress goes. The default discards it, which suits a test; a caller
    ///     walking a real corpus should pass something, because a walk that says nothing for
    ///     four minutes cannot be told from one that has hung.
    public init(root: URL, location: URL, report: @escaping (String) -> Void = { _ in }) {
        self.root = root
        self.location = location
        self.report = report
    }

    /// Every `.xlsx` under the root, sorted — read from the manifest where it can be, walked
    /// where it cannot.
    ///
    /// Sorted because a resumed audit must cover the corpus in the same order as the run it
    /// continues; otherwise "already done" and "not yet reached" stop lining up.
    public func workbooks() throws -> [String] {
        let base = try resolvedRoot()
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let state = recorded(for: base)

        if state.complete {
            report("\(state.files.count) workbooks from \(location.lastPathComponent),"
                + " already enumerated — not walking \(base.path) again")
            return state.files.sorted()
        }

        let segments = try topLevelSegments(of: base)
        let remaining = segments.filter { !state.directories.contains($0) }
        if !state.directories.isEmpty {
            report("resuming: \(state.directories.count) of \(segments.count) directories done,"
                + " \(state.files.count) workbooks kept, \(remaining.count) to go")
        }

        guard let handle = try open(startingFresh: state.stale) else {
            throw Failure.cannotWrite(location.path)
        }
        defer { close(handle) }

        var found = state.files
        var everythingRead = true
        for segment in remaining {
            report("walking \(segment) — \(found.count) workbooks so far")
            guard let discovered = discover(segment, under: base, prefix: prefix) else {
                // Deliberately not checkpointed. A directory marked done is skipped by every
                // later run, so writing that line over a momentary failure would drop the
                // subtree from the corpus permanently and say nothing about it.
                everythingRead = false
                continue
            }
            for path in discovered {
                append("file\t\(path)", to: handle)
            }
            // The checkpoint goes after the files it accounts for, never before: a crash
            // between the two would otherwise mark a directory done whose contents were lost.
            append("dir\t\(segment)", to: handle)
            found.append(contentsOf: discovered)
        }

        guard everythingRead else {
            report("\(found.count) workbooks so far — some directories could not be read, so"
                + " the manifest stays open and the next run will try them again")
            return found.sorted()
        }

        append("complete\t\(found.count)", to: handle)
        report("\(found.count) workbooks under \(base.path)")
        return found.sorted()
    }

    // MARK: - Reading what is already there

    /// What a manifest on disk says, and whether it describes this corpus at all.
    private struct State {
        var files: [String] = []
        var directories: Set<String> = []
        var complete = false
        /// The manifest exists but describes another root, so it must be replaced rather
        /// than appended to.
        var stale = false
    }

    private func recorded(for base: URL) -> State {
        let text: String
        do {
            text = try String(contentsOf: location, encoding: .utf8)
        } catch let failure {
            // Said rather than swallowed. "There is no manifest" and "there is one I could
            // not read" both lead to a full walk, and only one of them is ordinary — a
            // permissions problem that silently re-walked the corpus every run would look
            // like the tool simply being slow.
            report("no manifest read at \(location.path), enumerating from scratch (\(failure))")
            #if canImport(os)
            // Public privacy: a path the operator named and this type's account of it.
            Logger(subsystem: "CorpusWalk", category: "walk")
                .error("no manifest read at \(location.path, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
            return State()
        }

        var state = State()
        var recordedRoot: String?
        // `whereSeparator:` rather than splitting on "\n": in Swift "\r\n" is a single
        // `Character`, and a manifest written on another platform would otherwise read as one
        // enormous line and resume from nothing.
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard let kind = parts.first else { continue }
            let value = parts.count > 1 ? String(parts[1]) : ""
            switch kind {
            case "root": recordedRoot = value
            case "file": state.files.append(value)
            case "dir": state.directories.insert(value)
            case "complete": state.complete = true
            default: continue
            }
        }

        guard recordedRoot == base.path else {
            report("the manifest at \(location.path) describes"
                + " \(recordedRoot ?? "no root at all") rather than \(base.path) —"
                + " starting fresh rather than reporting another corpus's paths")
            return State(stale: true)
        }
        return state
    }

    // MARK: - Walking

    private func resolvedRoot() throws -> URL {
        let base = root.standardized.resolvingSymlinksInPath()
        do {
            guard try base.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw Failure.unreadableRoot(base.path, "not a directory")
            }
        } catch let failure as Failure {
            throw failure
        } catch let failure {
            // An empty corpus and an unreachable one must not look alike. Returning no
            // workbooks here would report perfect agreement over nothing.
            throw Failure.unreadableRoot(base.path, String(describing: failure))
        }
        return base
    }

    /// The root's immediate children, plus the root itself, as the units of resume.
    private func topLevelSegments(of base: URL) throws -> [String] {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        } catch let failure {
            throw Failure.unreadableRoot(base.path, String(describing: failure))
        }

        var directories: [String] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true else { continue }
            directories.append(entry.lastPathComponent)
        }
        return [Self.rootSegment] + directories.sorted()
    }

    /// The workbooks in one segment, or `nil` where the segment could not be read.
    ///
    /// `nil` rather than an empty array, because the caller checkpoints what it is given and
    /// the two must not be confused: an empty directory is answered, an unreadable one is not.
    private func discover(_ segment: String, under base: URL, prefix: String) -> [String]? {
        guard segment != Self.rootSegment else {
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: base, includingPropertiesForKeys: [.isRegularFileKey], options: [])
            } catch let failure {
                report("cannot read the root's own files: \(failure)")
                #if canImport(os)
                // Public privacy: a path the operator named and this type's account of it.
                Logger(subsystem: "CorpusWalk", category: "walk")
                    .error("cannot read \(base.path, privacy: .public): \(String(describing: failure), privacy: .public)")
                #endif
                return nil
            }
            return entries.compactMap { relativePath(of: $0, under: prefix) }.sorted()
        }

        let directory = base.appendingPathComponent(segment, isDirectory: true)
        // **With no error handler the enumerator simply skips what it cannot open**, and an
        // unreadable subtree is then indistinguishable from an empty one — which would get a
        // checkpoint and be skipped for ever after. The handler is what turns that silence
        // into a refusal to record the directory at all.
        var unreadable: [String] = []
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [],
            errorHandler: { url, error in
                unreadable.append("\(url.lastPathComponent) (\(error))")
                // Keep going: one unreadable folder deep in a subtree should not hide the
                // rest of it from the report. The tally below is what decides the outcome.
                return true
            }) else {
            report("cannot enumerate \(segment) — leaving it for the next run")
            note("cannot enumerate \(directory.path)")
            return nil
        }

        var found: [String] = []
        for case let url as URL in walker {
            guard let path = relativePath(of: url, under: prefix) else { continue }
            found.append(path)
        }

        guard unreadable.isEmpty else {
            report("\(segment) could not be read in full — \(unreadable.count) failure(s),"
                + " first \(unreadable.first ?? "") — leaving it for the next run")
            note("\(directory.path) incomplete: \(unreadable.count) failures")
            return nil
        }
        return found.sorted()
    }

    /// A workbook's path relative to the corpus root, or `nil` if it is not one of ours.
    private func relativePath(of url: URL, under prefix: String) -> String? {
        guard url.pathExtension == "xlsx", !url.lastPathComponent.hasPrefix("~$") else {
            return nil
        }
        // Every path is confirmed to sit under the resolved root before it is recorded. The
        // enumerator should not leave it, but a symlink inside the tree can point anywhere,
        // and a corpus that wandered out of the directory it names would be describing
        // something other than what its own header claims.
        let resolved = url.standardized.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(prefix) else { return nil }
        return String(resolved.dropFirst(prefix.count))
    }

    // MARK: - Writing

    private func open(startingFresh fresh: Bool) throws -> FileHandle? {
        if !fresh {
            do {
                let handle = try FileHandle(forWritingTo: location)
                try handle.seekToEnd()
                return handle
            } catch let failure {
                // A manifest that is there but will not open must not be replaced. Starting
                // fresh would truncate a walk that may have cost minutes, over a condition —
                // a lock, a permission, a file provider mid-fetch — that the next run might
                // not meet at all.
                guard Self.isMissingFile(failure) else {
                    report("the manifest at \(location.path) cannot be opened (\(failure)) —"
                        + " refusing to truncate what it already holds")
                    #if canImport(os)
                    // Public privacy: a path the operator named and this type's account of it.
                    Logger(subsystem: "CorpusWalk", category: "walk")
                        .error("cannot open \(location.path, privacy: .public): \(String(describing: failure), privacy: .public)")
                    #endif
                    throw failure
                }
                // Not an error: no manifest yet is the ordinary first run. Said rather than
                // swallowed, because "created it" and "appended to it" look identical
                // afterwards and only one of them means the resume found nothing.
                report("creating \(location.lastPathComponent) (\(failure))")
                #if canImport(os)
                // Public privacy: a path the operator named and this type's account of it.
                Logger(subsystem: "CorpusWalk", category: "walk")
                    .error("creating \(location.path, privacy: .public): \(String(describing: failure), privacy: .public)")
                #endif
            }
        }
        let header = "root\t\(try resolvedRoot().path)\n"
        try header.write(to: location, atomically: true, encoding: .utf8)
        let handle = try FileHandle(forWritingTo: location)
        try handle.seekToEnd()
        return handle
    }

    /// Writes one line and flushes it, because a line still in a buffer is a line that a
    /// power cut takes with it — which is the failure this whole type is an answer to.
    private func append(_ line: String, to handle: FileHandle) {
        handle.write(Data((line + "\n").utf8))
        do {
            try handle.synchronize()
        } catch let failure {
            // A flush that failed means this line may not survive the thing the flush exists
            // to survive, so it is reported rather than assumed: a manifest silently missing
            // its last lines would resume from the wrong place.
            report("flush failed after \(line): \(failure)")
            #if canImport(os)
            // Public privacy: a path the operator named and this type's account of it.
            Logger(subsystem: "CorpusWalk", category: "walk")
                .error("flush failed after \(line, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
        }
    }

    private func close(_ handle: FileHandle) {
        do {
            try handle.close()
        } catch let failure {
            report("could not close \(location.lastPathComponent): \(failure)")
            #if canImport(os)
            // Public privacy: a path the operator named and this type's account of it.
            Logger(subsystem: "CorpusWalk", category: "walk")
                .error("could not close \(location.path, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
        }
    }

    /// The same account as `report`, to the system log where there is one.
    ///
    /// Public privacy: these are paths the operator named and this type's account of them.
    private func note(_ message: String) {
        #if canImport(os)
        Logger(subsystem: "CorpusWalk", category: "walk")
            .error("\(message, privacy: .public)")
        #endif
    }

    /// Whether a failure means "there is no such file" rather than "it will not open".
    ///
    /// The distinction decides whether starting fresh is safe, so it is made on the error
    /// rather than by asking whether the file exists first — which would answer a different
    /// question a moment earlier, and race with anything else touching the file.
    private static func isMissingFile(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let failure = current, depth < maximumDepth {
            if failure.domain == NSCocoaErrorDomain,
               failure.code == NSFileNoSuchFileError || failure.code == NSFileReadNoSuchFileError {
                return true
            }
            if failure.domain == NSPOSIXErrorDomain, failure.code == Int(ENOENT) {
                return true
            }
            current = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}
