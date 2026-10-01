import Foundation
import Foundation
import Testing
@testable import WorkbookCensus

/// What a census row means for a run that resumes from it.
///
/// **The output file is the resume state, and that is what makes a wrongly-recorded failure
/// permanent.** A run that recorded a workbook as unreadable because the file provider had
/// not materialised it yet will skip that workbook on every subsequent pass, for ever —
/// the row exists, so the path is done. Forty-two workbooks were lost that way in one
/// afternoon, all of them `POSIX 60 "Operation timed out"`, and all of them readable a few
/// minutes later. These tests fix the distinction between *failed* and *not yet answered*.
@Suite struct CensusResumeTests {

    /// The shape `Data(contentsOf:)` actually produced, reproduced from a recorded row:
    /// a Cocoa "couldn't be opened" wrapping a POSIX timeout.
    private func cocoaError(wrappingPOSIX code: Int) -> Error {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: code)
        return NSError(domain: NSCocoaErrorDomain, code: 256,
                       userInfo: [NSUnderlyingErrorKey: underlying])
    }

    // MARK: - Which failures are worth retrying

    @Test func aTimedOutReadIsTransient() {
        // POSIX 60, ETIMEDOUT — the one that was observed, 42 times.
        #expect(TransientRead.isTransient(cocoaError(wrappingPOSIX: 60)))
    }

    @Test func aResourceTemporarilyUnavailableReadIsTransient() {
        // POSIX 35, EAGAIN — the same condition reported by a different layer.
        #expect(TransientRead.isTransient(cocoaError(wrappingPOSIX: 35)))
    }

    @Test func aMissingFileIsNotTransient() {
        // POSIX 2, ENOENT. Retrying will not make the file exist.
        #expect(!TransientRead.isTransient(cocoaError(wrappingPOSIX: 2)))
    }

    @Test func aPermissionFailureIsNotTransient() {
        // POSIX 13, EACCES. Retrying will not grant permission.
        #expect(!TransientRead.isTransient(cocoaError(wrappingPOSIX: 13)))
    }

    @Test func aCocoaErrorWithNoUnderlyingCauseIsNotTransient() {
        // "Couldn't be opened" on its own says nothing about why, so it is not a licence
        // to retry every malformed file in the corpus for ever.
        #expect(!TransientRead.isTransient(NSError(domain: NSCocoaErrorDomain, code: 256)))
    }

    // MARK: - What a resumed run treats as answered

    @Test func aTransientRowIsNotCountedAsCompleted() {
        let row = CensusRow(path: "a/b.xlsx", outcome: .transientFailure, solverNames: 0,
                            models: 0, engines: [], relations: [], milliseconds: 1,
                            detail: "timed out")
        #expect(CensusRow.completedPath(ofLine: row.line) == nil, "a transient failure must be retried, not skipped for ever")
    }

    /// Encryption and wrong-file-type are answers, not failures to be retried.
    ///
    /// A census that re-examined every password-protected workbook on every pass would never
    /// converge, and the answer would be the same each time.
    @Test func aClassifiedContainerIsCountedAsCompleted() {
        for outcome: CensusRow.Outcome in [.encryptedWorkbook, .notAWorkbook] {
            let row = CensusRow(path: "a/b.xlsx", outcome: outcome, solverNames: 0, models: 0,
                                engines: [], relations: [], milliseconds: 1, detail: "")
            #expect(CensusRow.completedPath(ofLine: row.line) == "a/b.xlsx", "\(outcome.rawValue) is a definite answer about the file")
        }
    }

    @Test func anExaminedRowIsCountedAsCompleted() {
        for outcome: CensusRow.Outcome in [.ok, .unreadableFile, .unreadableWorkbook] {
            let row = CensusRow(path: "a/b.xlsx", outcome: outcome, solverNames: 0, models: 0,
                                engines: [], relations: [], milliseconds: 1, detail: "")
            #expect(CensusRow.completedPath(ofLine: row.line) == "a/b.xlsx", "\(outcome.rawValue) is an answer and must not be re-examined")
        }
    }

    @Test func theHeaderIsNotACompletedPath() {
        #expect(CensusRow.completedPath(ofLine: CensusRow.header) == nil)
    }

    @Test func aTruncatedLineIsNotCountedAsCompleted() {
        // A row cut off mid-write by a killed run states no outcome, so it is not an answer.
        #expect(CensusRow.completedPath(ofLine: "a/b.xlsx") == nil)
    }

    /// A transient row still has to be *recorded*, even though it is not an answer.
    ///
    /// Leaving the row out entirely would make "skipped" and "never reached" identical from
    /// outside, which is the property the census exists to avoid.
    @Test func aTransientRowIsStillWrittenAndReadable() {
        let row = CensusRow(path: "a/b.xlsx", outcome: .transientFailure, solverNames: 0,
                            models: 0, engines: [], relations: [], milliseconds: 1,
                            detail: "Operation timed out")
        #expect(row.line.contains("transientFailure"))
        #expect(row.line.contains("Operation timed out"))
    }
}
