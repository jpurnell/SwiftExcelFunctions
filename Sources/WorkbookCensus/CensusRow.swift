import Foundation

/// One workbook's result, as a line of the census file.
///
/// **The output file is also the resume state.** There is no separate journal: a row exists
/// exactly when that workbook has been examined, so restarting reads what is there and
/// skips it. That is what makes a partial run worth having rather than worth repeating.
struct CensusRow {

    /// How the workbook was read.
    enum Outcome: String {
        /// Opened and examined.
        case ok
        /// The bytes could not be read from disk.
        case unreadableFile
        /// Opened by the reader and refused — a malformed or unsupported workbook.
        case unreadableWorkbook
        /// The bytes could not be read *yet* — a condition expected to clear on its own.
        ///
        /// **Recorded, but not an answer.** ``completedPath(ofLine:)`` returns `nil` for
        /// this outcome, so a resumed run examines the workbook again instead of skipping
        /// it for ever. Writing the row anyway is what keeps "tried and deferred" legible
        /// from outside; leaving it out would make that identical to "never reached".
        case transientFailure
    }

    /// Path, relative to the root being scanned.
    let path: String

    /// What happened.
    let outcome: Outcome

    /// How many `solver_` defined names the workbook carries.
    let solverNames: Int

    /// How many models `ExcelSolverReader` made of them — one per sheet.
    ///
    /// **Names without models is the interesting row.** It means the workbook declares a
    /// Solver model that this reader could not assemble, which is a defect rather than an
    /// absence, and it is the finding the census exists to surface.
    let models: Int

    /// The engines those models nominate, as read.
    let engines: [String]

    /// The relation codes their constraints use.
    let relations: [Int]

    /// How long reading it took, in milliseconds — so a later run can say which workbooks
    /// are worth the time and which dominate it.
    let milliseconds: Int

    /// Why it failed, where it did.
    ///
    /// **A census that discards the reason is a census that reports "unreadable" 40 times
    /// and teaches nothing.** The failure is the finding — it was a census that turned up
    /// the lexer crash and the furigana corruption — so the reader's own account of it goes
    /// in the row.
    let detail: String

    /// The tab-separated line, without a trailing newline.
    var line: String {
        [
            path.replacingOccurrences(of: "\t", with: " "),
            outcome.rawValue,
            String(solverNames),
            String(models),
            engines.sorted().joined(separator: ","),
            relations.sorted().map(String.init).joined(separator: ","),
            String(milliseconds),
            detail.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " "),
        ].joined(separator: "\t")
    }

    /// The header, written once when a census file is created.
    static let header = "path\toutcome\tsolver_names\tmodels\tengines\trelations\tms\tdetail"

    /// The path a line refers to, whatever it says happened.
    ///
    /// - Parameter line: A line previously written by ``line``.
    /// - Returns: The path, or `nil` for the header or a truncated line.
    static func path(ofLine line: String) -> String? {
        guard let first = line.split(separator: "\t", maxSplits: 1).first else { return nil }
        let path = String(first)
        return path == "path" ? nil : path
    }

    /// The path a line *answers*, for resuming.
    ///
    /// **Not every row is an answer.** A ``Outcome/transientFailure`` row records an attempt
    /// that deserves another one, so it is excluded here and the workbook is examined again.
    /// Reading the path alone — which is what resuming used to do — made a file provider's
    /// momentary timeout into a permanent hole in the corpus.
    ///
    /// - Parameter line: A line previously written by ``line``.
    /// - Returns: The path, or `nil` for the header, a truncated line, an unrecognised
    ///   outcome, or an attempt that should be repeated.
    static func completedPath(ofLine line: String) -> String? {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2, let path = path(ofLine: line) else { return nil }
        // An outcome this build does not recognise is not treated as an answer: a row
        // written by a newer census should be re-examined rather than trusted blindly.
        guard let outcome = Outcome(rawValue: String(fields[1])) else { return nil }
        return outcome == .transientFailure ? nil : path
    }
}
