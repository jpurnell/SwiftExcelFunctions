import XCTest
@testable import CorpusWalk

/// The enumeration of a corpus, and whether it survives being interrupted.
///
/// **These tests exist because a run was lost to exactly this.** On 2026-09-19 the oracle was
/// started over `~/Documents`, spent its first four minutes inside
/// `NSURLDirectoryEnumerator.nextObject` walking a Dropbox-backed tree, and the machine shut
/// down. It had written nothing at all, because the walk happened *before* the first row —
/// so the restart had to redo every second of it.
///
/// The project's rule was already written down, in `WorkbookCensus/main.swift` and again on
/// `Row`: *the output file is the resume state.* It was honoured for the audit and not for the
/// walk, and the walk was the expensive half. A rule applied to the cheap half of a program is
/// not a rule, it is a coincidence.
///
/// So the manifest is the walk's own resume state, and these tests hold it to the two things
/// that matter: a finished walk is never repeated, and an unfinished one keeps what it got.
final class CorpusManifestTests: XCTestCase {

    // MARK: - Fixtures

    private var root: URL!
    private var manifest: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("corpus-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manifest = root.appendingPathComponent("manifest.tsv")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        try super.tearDownWithError()
    }

    /// Why a fixture could not be laid down.
    private enum FixtureFailure: Error, CustomStringConvertible {
        case outsideRoot(String)

        var description: String {
            switch self {
            case .outsideRoot(let path):
                return "\(path) would land outside the fixture root"
            }
        }
    }

    /// A URL inside the fixture root, standardized and checked to be under it.
    ///
    /// These are test fixtures and the arguments are literals a few lines away — but a helper
    /// that takes a path and acts on wherever it points is one `..` from touching the machine
    /// outside its own temporary tree, and a test that damages its host is a worse failure
    /// than any it could detect.
    private func fixtureURL(_ relative: String) throws -> URL {
        let base = root.standardized
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        let url = base.appendingPathComponent(relative).standardized
        guard url.path.hasPrefix(prefix) else {
            throw FixtureFailure.outsideRoot(relative)
        }
        return url
    }

    /// Writes an empty file at a path relative to the corpus root, making directories as needed.
    private func put(_ relative: String) throws {
        let url = try fixtureURL(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Written through the URL rather than `createFile(atPath:)`: the corpus these tests
        // describe is addressed by URL throughout, and a string path here would be the one
        // place a `..` could be reintroduced after the check above.
        try Data().write(to: url, options: .atomic)
    }

    private func subject(reporting lines: ReportSpy? = nil) -> CorpusManifest {
        CorpusManifest(root: root, location: manifest, report: { lines?.record($0) })
    }

    /// Collects what the walk said, so "it said nothing" is a thing a test can assert.
    final class ReportSpy {
        private(set) var lines: [String] = []
        func record(_ line: String) { lines.append(line) }
    }

    // MARK: - The walk itself

    func testAFreshWalkFindsEveryWorkbookBeneathTheRoot() throws {
        try put("alpha/one.xlsx")
        try put("alpha/nested/two.xlsx")
        try put("beta/three.xlsx")
        try put("top.xlsx")

        let found = try subject().workbooks()

        XCTAssertEqual(found, ["alpha/nested/two.xlsx", "alpha/one.xlsx",
                               "beta/three.xlsx", "top.xlsx"],
                       "sorted, and relative to the root")
    }

    func testWhatIsNotAWorkbookIsNotCounted() throws {
        try put("alpha/one.xlsx")
        try put("alpha/notes.txt")
        try put("alpha/~$one.xlsx")
        try put("alpha/book.xls")

        XCTAssertEqual(try subject().workbooks(), ["alpha/one.xlsx"],
                       "an Excel lock file is not a workbook, and neither is a .txt or a .xls")
    }

    // MARK: - The resume, which is the point

    func testAFinishedWalkIsReadRatherThanWalkedAgain() throws {
        try put("alpha/one.xlsx")
        let first = try subject().workbooks()
        XCTAssertEqual(first, ["alpha/one.xlsx"])

        // Put a second workbook on disk *after* the manifest says the walk finished. A run
        // that returns it has walked the tree again, which is the cost this whole mechanism
        // exists to avoid — so its absence is the assertion.
        try put("alpha/two.xlsx")

        XCTAssertEqual(try subject().workbooks(), ["alpha/one.xlsx"],
                       "a complete manifest is the answer; the tree is not consulted")
    }

    func testAnUnfinishedWalkKeepsTheDirectoriesItFinished() throws {
        try put("alpha/one.xlsx")
        try put("beta/two.xlsx")

        // A manifest as a crash would leave it: `alpha` walked and marked done, `beta` never
        // reached, and no completion line.
        try [
            "root\t\(root.resolvingSymlinksInPath().path)",
            "file\talpha/one.xlsx",
            "dir\talpha",
            "",
        ].joined(separator: "\n").write(to: manifest, atomically: true, encoding: .utf8)

        let spy = ReportSpy()
        let found = try subject(reporting: spy).workbooks()

        XCTAssertEqual(found, ["alpha/one.xlsx", "beta/two.xlsx"],
                       "the finished directory is trusted, the unfinished one is walked")
        XCTAssertFalse(spy.lines.contains { $0.contains("alpha") && $0.contains("walking") },
                       "alpha was already done and must not be walked a second time")
    }

    func testAResumedWalkFinishesTheManifest() throws {
        try put("alpha/one.xlsx")
        try put("beta/two.xlsx")
        try [
            "root\t\(root.resolvingSymlinksInPath().path)",
            "file\talpha/one.xlsx",
            "dir\talpha",
            "",
        ].joined(separator: "\n").write(to: manifest, atomically: true, encoding: .utf8)

        _ = try subject().workbooks()

        // Having finished, the next run must take the cheap path — the same assertion as
        // above, reached by resuming rather than by starting clean.
        try put("beta/three.xlsx")
        XCTAssertEqual(try subject().workbooks(), ["alpha/one.xlsx", "beta/two.xlsx"],
                       "the resumed run wrote its own completion line")
    }

    func testAManifestWrittenForAnotherRootIsNotBelieved() throws {
        try put("alpha/one.xlsx")
        try [
            "root\t/somewhere/else",
            "file\tghost/absent.xlsx",
            "complete\t1",
            "",
        ].joined(separator: "\n").write(to: manifest, atomically: true, encoding: .utf8)

        let found = try subject().workbooks()

        XCTAssertEqual(found, ["alpha/one.xlsx"],
                       "a manifest names the root it describes, and a mismatch starts fresh")
        XCTAssertFalse(try String(contentsOf: manifest, encoding: .utf8).contains("absent.xlsx"),
                       "and the stale contents are gone rather than appended to")
    }

    func testADirectoryThatCannotBeReadIsNeitherCheckpointedNorCompleted() throws {
        try put("alpha/one.xlsx")
        try put("sealed/two.xlsx")

        // With no error handler the enumerator skips what it cannot open, so an unreadable
        // subtree reads as an empty one — and an empty one gets a checkpoint and is never
        // visited again. That is how a corpus silently shrinks, and this is the test of it.
        let sealed = try fixtureURL("sealed")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: sealed.path)
        let found = try subject().workbooks()
        // Restored immediately rather than in a teardown: a directory with no permissions
        // cannot be removed, so a failure between here and the end would leak the tree.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: sealed.path)

        XCTAssertEqual(found, ["alpha/one.xlsx"], "what could be read is still reported")

        let written = try String(contentsOf: manifest, encoding: .utf8)
        XCTAssertFalse(written.contains("dir\tsealed"),
                       "a directory that could not be read must not be marked done")
        XCTAssertFalse(written.contains("complete"),
                       "and a walk that missed one has not completed")

        // The point of all of it: the next run tries again rather than skipping for ever.
        XCTAssertEqual(try subject().workbooks(), ["alpha/one.xlsx", "sealed/two.xlsx"],
                       "the retry finds what the sealed run could not")
    }

    // MARK: - Saying what it is doing

    func testTheWalkSaysWhatItIsDoingWhileItDoesIt() throws {
        try put("alpha/one.xlsx")
        try put("beta/two.xlsx")

        let spy = ReportSpy()
        _ = try subject(reporting: spy).workbooks()

        // The last run could not be told apart from a hung one without `sample`-ing the
        // process. A walk that names each directory as it starts it cannot go silent for
        // four minutes with nothing to show.
        XCTAssertTrue(spy.lines.contains { $0.contains("alpha") },
                      "it named the directory it was walking: \(spy.lines)")
        XCTAssertTrue(spy.lines.contains { $0.contains("beta") },
                      "and the next one: \(spy.lines)")
    }

    func testAnUnreadableRootIsRefusedRatherThanReportedEmpty() throws {
        let missing = root.appendingPathComponent("no-such-directory", isDirectory: true)
        let subject = CorpusManifest(root: missing, location: manifest, report: { _ in })

        XCTAssertThrowsError(try subject.workbooks(),
                             "an empty corpus and an unreadable one must not look alike")
    }
}
