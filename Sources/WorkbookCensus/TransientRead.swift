import Foundation

/// Whether a failed read is worth trying again.
///
/// **The census file is its own resume state, so a failure recorded is a failure for ever.**
/// A workbook whose bytes could not be read gets a row, and a row means "answered" — every
/// later pass skips it. That is the right behaviour for a file that is missing or malformed
/// and the wrong behaviour entirely for one the file provider had simply not materialised
/// yet, which is a condition that clears on its own within seconds.
///
/// It is not hypothetical. One afternoon's run recorded 42 workbooks as `unreadableFile`,
/// every one of them `POSIX 60 "Operation timed out"`, and every one of them read correctly
/// minutes later — three of them had read correctly in the run *before*. Without this
/// distinction those 42 were lost from the corpus permanently, and nothing in the output
/// said so: the rows looked exactly like genuine failures.
enum TransientRead {

    /// The POSIX errors that mean "not now" rather than "not ever".
    ///
    /// Deliberately short. Every code listed here buys retries on every genuinely broken
    /// file that reports it, and a code that does not belong turns a permanent failure into
    /// an unbounded one — the census would never finish and would never say why.
    private static let retryable: Set<Int> = [
        4,   // EINTR — interrupted by a signal before any bytes moved.
        35,  // EAGAIN — resource temporarily unavailable.
        60,  // ETIMEDOUT — the observed one: a dataless file the provider could not fetch.
    ]

    /// How deep to follow `NSUnderlyingErrorKey` before giving up.
    ///
    /// A bound rather than a recursion, because an error chain is supplied by whatever
    /// framework built it and nothing here guarantees it is acyclic.
    private static let maximumDepth = 8

    /// Whether this failure is worth a second attempt.
    ///
    /// The POSIX cause is usually wrapped: `Data(contentsOf:)` reports Cocoa 256, "the file
    /// couldn't be opened", and hangs the real reason underneath it. The Cocoa code alone
    /// says nothing about why, so it is never grounds to retry on its own.
    ///
    /// - Parameter error: The failure a read reported.
    /// - Returns: `true` where the condition is expected to clear on its own.
    static func isTransient(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        var depth = 0
        while let failure = current, depth < maximumDepth {
            if failure.domain == NSPOSIXErrorDomain, retryable.contains(failure.code) {
                return true
            }
            current = failure.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return false
    }
}
