import Foundation
import SwiftExcelCore
import SwiftXLSX
import WorkbookAudit

/// One workbook's result, as a line of the summary file.
///
/// **The summary file is the resume state.** A row exists exactly when that workbook has
/// been audited, so a restart reads what is there and skips it — the same arrangement the
/// workbook census uses, and for the same reason.
struct Row {
    let path: String
    var comparable = 0
    var agreed = 0, agreedOnError = 0, differed = 0, refused = 0, threw = 0, notComparable = 0
    var agreement = 0.0
    var unreadable = ""

    init(path: String, unreadable: String) {
        self.path = path
        self.unreadable = unreadable
    }

    init(path: String,
         tally: (agreed: Int, agreedOnError: Int, differed: Int,
                 refused: Int, threw: Int, notComparable: Int),
         comparable: Int, agreement: Double) {
        self.path = path
        self.agreed = tally.agreed
        self.agreedOnError = tally.agreedOnError
        self.differed = tally.differed
        self.refused = tally.refused
        self.threw = tally.threw
        self.notComparable = tally.notComparable
        self.comparable = comparable
        self.agreement = agreement
    }

    static let header = ["path", "comparable", "agreed", "agreedOnError", "differed",
                         "refused", "threw", "notComparable", "agreement", "unreadable"]
        .joined(separator: "\t")

    var line: String {
        [
            path.replacingOccurrences(of: "\t", with: " "),
            String(comparable), String(agreed), String(agreedOnError), String(differed),
            String(refused), String(threw), String(notComparable),
            Row.fixed(agreement),
            unreadable.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " "),
        ].joined(separator: "\t")
    }

    /// A share written to six places, in a fixed locale.
    ///
    /// This lands in a TSV that other programs read, so a decimal comma would make the
    /// column unparseable in about half the world. Not `String(format:)`, which bridges to
    /// the C printf ABI for no benefit here.
    static func fixed(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(6)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }

    static func path(ofLine line: String) -> String? {
        guard let first = line.split(separator: "\t", maxSplits: 1).first else { return nil }
        let path = String(first)
        return path == "path" ? nil : path
    }
}

/// One cell that did not agree.
///
/// A tally says *how many*; triage needs *which*, with enough beside it to act. The function
/// list is what turns a list of cells into a list of things to fix — twenty failures in one
/// function is one defect, twenty failures in twenty functions is twenty.
struct Finding {
    let path: String
    let sheet: String
    let cell: String
    let outcome: String
    let ours: String
    let excel: String
    let functions: String
    /// The formula itself, written back out.
    ///
    /// Without it a row says a cell disagreed and not what it was trying to do, which is
    /// most of what triage needs — the first pass at these findings had to open the
    /// workbooks by hand to learn that four hundred of them were one formula shape.
    let formula: String

    init(path: String, finding: OracleFinding) {
        self.formula = FormulaSerializer.serialize(finding.formula)
        self.path = path
        self.sheet = finding.sheet
        self.cell = finding.cell.reference
        self.functions = finding.functions.sorted().joined(separator: "+")
        switch finding.outcome {
        case .differed(let ours, let excel):
            self.outcome = "differed"
            self.ours = Finding.describe(ours)
            self.excel = Finding.describe(excel)
        case .refused(let error, let excel):
            self.outcome = "refused"
            self.ours = error.rawValue
            self.excel = Finding.describe(excel)
        case .threw(let message, let excel):
            self.outcome = "threw"
            self.ours = message
            self.excel = Finding.describe(excel)
        case .agreed, .agreedOnError, .notComparable:
            self.outcome = "agreed"
            self.ours = ""
            self.excel = ""
        }
    }

    private static func describe(_ value: CellValue) -> String {
        switch value {
        case .number(let v): return "\(v)"
        case .text(let v): return "\"\(v)\""
        case .bool(let v): return v ? "TRUE" : "FALSE"
        case .error(let v): return v.rawValue
        case .blank: return "(blank)"
        default: return String(describing: value)
        }
    }

    static let header = ["path", "sheet", "cell", "outcome", "ours", "excel", "functions",
                         "formula"].joined(separator: "\t")

    var line: String {
        [path, sheet, cell, outcome, ours, excel, functions, formula]
            .map { $0.replacingOccurrences(of: "\t", with: " ")
                     .replacingOccurrences(of: "\n", with: " ") }
            .joined(separator: "\t")
    }
}

/// The running totals across a run.
struct Tally {
    var comparable = 0
    var agreed = 0, agreedOnError = 0, differed = 0, refused = 0, threw = 0, notComparable = 0
    var byFunction: [String: Int] = [:]

    mutating func add(_ row: Row) {
        comparable += row.comparable
        agreed += row.agreed
        agreedOnError += row.agreedOnError
        differed += row.differed
        refused += row.refused
        threw += row.threw
        notComparable += row.notComparable
    }

    mutating func count(_ finding: Finding) {
        guard finding.outcome != "agreed", !finding.functions.isEmpty else { return }
        byFunction[finding.functions, default: 0] += 1
    }

    var agreementText: String {
        guard comparable > 0 else { return "—" }
        let share = Double(agreed + agreedOnError) / Double(comparable) * 100
        return share.formatted(.number.precision(.fractionLength(2)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX"))) + "%"
    }
}
