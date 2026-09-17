import Foundation
#if canImport(os)
import os
#endif

/// The one place this tool starts a subprocess.
///
/// `Process` plus `waitUntilExit()` waits for the child to exit **or forever**, and there is
/// no third case. That is the wrong shape for a supervisor whose whole reason to exist is
/// that the thing it supervises sometimes does not come back.
///
/// The morning this was written, a corpus pass had already been lost twice to a run that
/// produced nothing and once to a workbook that trapped. A workbook that *hangs* — a
/// pathological file the reader spins on rather than crashing on — is the same failure with
/// no crash report, and an unbounded wait would hold the whole corpus behind it. So the
/// deadline is a parameter and not an option.
enum ProcessRunner {

    /// What became of a child.
    struct Completion {
        let status: Int32
        let reason: Process.TerminationReason
        /// Whether the deadline ended the run rather than the child doing so.
        let timedOut: Bool

        var succeeded: Bool { reason == .exit && status == 0 && !timedOut }
    }

    enum Failure: Error {
        case couldNotStart(String)
    }

    /// Runs a child to completion or to the deadline, whichever comes first.
    ///
    /// The child inherits this process's standard output and error rather than being read
    /// through pipes. That is deliberate: what it prints is progress, and progress held in a
    /// pipe until the child exits is the exact failure this tool exists to avoid. There are
    /// no pipes, so there is nothing to drain and nothing that can fill and deadlock.
    ///
    /// - Parameters:
    ///   - executable: The program to run.
    ///   - arguments: Its arguments.
    ///   - timeout: How long the child may take before it is ended.
    /// - Returns: How it ended.
    /// - Throws: ``Failure/couldNotStart(_:)`` if the child never began.
    static func run(
        _ executable: URL, arguments: [String], timeout: Duration
    ) throws -> Completion {
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments

        let finished = DispatchSemaphore(value: 0)
        child.terminationHandler = { _ in finished.signal() }

        do {
            try child.run()
        } catch {
            #if canImport(os)
            Logger(subsystem: "NameRoundTrip", category: "process")
                .error("could not start \(executable.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            #endif
            throw Failure.couldNotStart("\(error)")
        }

        guard finished.wait(timeout: .now() + seconds(timeout)) != .success else {
            return Completion(status: child.terminationStatus,
                              reason: child.terminationReason, timedOut: false)
        }

        // Past the deadline: ask, then insist. A child that ignores SIGTERM gets a grace
        // period and then the signal it cannot ignore, so this function itself is bounded.
        child.terminate()
        if finished.wait(timeout: .now() + 10) != .success {
            kill(child.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + 5)
        }
        return Completion(status: child.terminationStatus,
                          reason: child.terminationReason, timedOut: true)
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
