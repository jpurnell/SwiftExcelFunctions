import Foundation
import XCTest
@testable import WorkbookCensus

/// What a census row means for a run that resumes from it.
///
/// **The output file is the resume state, and that is what makes a wrongly-recorded failure
/// permanent.** A run that recorded a workbook as unreadable because the file provider had
/// not materialised it yet will skip that workbook on every subsequent pass, for ever —
/// the row exists, so the path is done. Forty-two workbooks were lost that way in one
/// afternoon, all of them `POSIX 60 "Operation timed out"`, and all of them readable a few
/// minutes later. These tests fix the distinction between *failed* and *not yet answered*.
final class CensusResumeTests: XCTestCase {

    /// The shape `Data(contentsOf:)` actually produced, reproduced from a recorded row:
    /// a Cocoa "couldn't be opened" wrapping a POSIX timeout.
    private func cocoaError(wrappingPOSIX code: Int) -> Error {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: code)
        return NSError(domain: NSCocoaErrorDomain, code: 256,
                       userInfo: [NSUnderlyingErrorKey: underlying])
    }

    // MARK: - Which failures are worth retrying

    func testATimedOutReadIsTransient() {
        // POSIX 60, ETIMEDOUT — the one that was observed, 42 times.
        XCTAssertTrue(TransientRead.isTransient(cocoaError(wrappingPOSIX: 60)))
    }

    func testAResourceTemporarilyUnavailableReadIsTransient() {
        // POSIX 35, EAGAIN — the same condition reported by a different layer.
        XCTAssertTrue(TransientRead.isTransient(cocoaError(wrappingPOSIX: 35)))
    }

    func testAMissingFileIsNotTransient() {
        // POSIX 2, ENOENT. Retrying will not make the file exist.
        XCTAssertFalse(TransientRead.isTransient(cocoaError(wrappingPOSIX: 2)))
    }

    func testAPermissionFailureIsNotTransient() {
        // POSIX 13, EACCES. Retrying will not grant permission.
        XCTAssertFalse(TransientRead.isTransient(cocoaError(wrappingPOSIX: 13)))
    }

    func testACocoaErrorWithNoUnderlyingCauseIsNotTransient() {
        // "Couldn't be opened" on its own says nothing about why, so it is not a licence
        // to retry every malformed file in the corpus for ever.
        XCTAssertFalse(TransientRead.isTransient(NSError(domain: NSCocoaErrorDomain, code: 256)))
    }

    // MARK: - What a resumed run treats as answered

    func testATransientRowIsNotCountedAsCompleted() {
        let row = CensusRow(path: "a/b.xlsx", outcome: .transientFailure, solverNames: 0,
                            models: 0, engines: [], relations: [], milliseconds: 1,
                            detail: "timed out")
        XCTAssertNil(CensusRow.completedPath(ofLine: row.line),
                     "a transient failure must be retried, not skipped for ever")
    }

    func testAnExaminedRowIsCountedAsCompleted() {
        for outcome: CensusRow.Outcome in [.ok, .unreadableFile, .unreadableWorkbook] {
            let row = CensusRow(path: "a/b.xlsx", outcome: outcome, solverNames: 0, models: 0,
                                engines: [], relations: [], milliseconds: 1, detail: "")
            XCTAssertEqual(CensusRow.completedPath(ofLine: row.line), "a/b.xlsx",
                           "\(outcome.rawValue) is an answer and must not be re-examined")
        }
    }

    func testTheHeaderIsNotACompletedPath() {
        XCTAssertNil(CensusRow.completedPath(ofLine: CensusRow.header))
    }

    func testATruncatedLineIsNotCountedAsCompleted() {
        // A row cut off mid-write by a killed run states no outcome, so it is not an answer.
        XCTAssertNil(CensusRow.completedPath(ofLine: "a/b.xlsx"))
    }

    /// A transient row still has to be *recorded*, even though it is not an answer.
    ///
    /// Leaving the row out entirely would make "skipped" and "never reached" identical from
    /// outside, which is the property the census exists to avoid.
    func testATransientRowIsStillWrittenAndReadable() {
        let row = CensusRow(path: "a/b.xlsx", outcome: .transientFailure, solverNames: 0,
                            models: 0, engines: [], relations: [], milliseconds: 1,
                            detail: "Operation timed out")
        XCTAssertTrue(row.line.contains("transientFailure"))
        XCTAssertTrue(row.line.contains("Operation timed out"))
    }
}
