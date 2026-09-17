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
/// beside it — one fact, one place, nothing that can drift. The cost of that choice is that
/// every rule the writer applies has to be right, and the reason to accept the cost is that
/// being right is *checkable*: read, write, read, and any name that comes back different has
/// an address.
///
/// ```
/// swift run name-round-trip ~/Documents
/// ```
///
/// Reports three numbers that matter: how many names survived exactly, how many did not, and
/// how many landed in `.unparsed` — the last being the reader's health rather than a failure,
/// since `.unparsed` round-trips by the identity function and is where anything unproven
/// belongs.
struct RoundTrip {

    let root: URL

    func run() throws {
        var books = 0, booksWithNames = 0, unreadable = 0
        var names = 0, exact = 0, unparsed = 0
        var mismatches: [String] = []

        for url in try workbooks() {
            books += 1
            let before: Workbook
            do {
                before = try Workbook(contentsOf: url)
            } catch {
                #if canImport(os)
                // Inline rather than behind a helper: the logging checker is syntactic and
                // wants the call literally here, which is also where the error is.
                Logger(subsystem: "NameRoundTrip", category: "read")
                    .error("unreadable \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                #endif
                unreadable += 1
                continue
            }
            let original = before.namedRanges.all
            guard !original.isEmpty else { continue }
            booksWithNames += 1

            let rewritten: [NamedRange]
            do {
                rewritten = try Workbook(xlsxData: try before.save()).namedRanges.all
            } catch {
                #if canImport(os)
                Logger(subsystem: "NameRoundTrip", category: "write")
                    .error("round trip failed for \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                #endif
                // The failure *is* the finding, so it is reported with the workbook's name
                // rather than only logged.
                mismatches.append("\(url.lastPathComponent): could not be written or reread "
                    + "— \(error)")
                continue
            }

            names += original.count
            if rewritten.count != original.count {
                mismatches.append("\(url.lastPathComponent): \(original.count) names in, "
                    + "\(rewritten.count) out")
                continue
            }
            for (was, now) in zip(original, rewritten) {
                if case .unparsed = was.reference { unparsed += 1 }
                if was == now {
                    exact += 1
                } else if mismatches.count < 40 {
                    mismatches.append("\(url.lastPathComponent) · \(was.name)\n"
                        + "      was \(was.reference)\n      now \(now.reference)")
                }
            }
        }

        say("workbooks read          \(books)   (\(unreadable) unreadable)")
        say("with defined names      \(booksWithNames)")
        say("names compared          \(names)")
        say("came back identical     \(exact)")
        say("differed                \(names - exact)")
        say("of which .unparsed      \(unparsed)   — the identity path, and the reader's health")
        if !mismatches.isEmpty {
            say("")
            say("first \(min(mismatches.count, 40)):")
            for line in mismatches.prefix(40) { say("   \(line)") }
        }
    }

    private func workbooks() throws -> [URL] {
        let base = root.standardized.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker
        where url.pathExtension == "xlsx" && !url.lastPathComponent.hasPrefix("~$") {
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }

    private func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let path = arguments.first else {
    FileHandle.standardError.write(Data("usage: name-round-trip <corpus-root>\n".utf8))
    exit(2)
}
try RoundTrip(root: URL(fileURLWithPath: path)).run()
