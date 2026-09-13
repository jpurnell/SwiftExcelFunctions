import Foundation
#if canImport(os)
import os
#endif
import SwiftExcelCore
import SwiftExcelFunctions
import SwiftXLSX

/// Builds a workbook that asks Excel the questions this package has answered on its own, and
/// reads back what Excel said.
///
/// ## Why a workbook rather than a test
///
/// A test compares this package against a value somebody typed in, which proves that two
/// readings of a document agree. Documentation has been wrong four times in this project's
/// life. The only authority on what Excel does is Excel, and the only way to ask it is to
/// hand it a formula and look at the answer.
///
/// ```
/// swift run conformance-workbook emit ~/Desktop/conformance.xlsx
/// # open it in Excel, let it calculate, save it
/// swift run conformance-workbook check ~/Desktop/conformance.xlsx
/// ```
///
/// ## The workbook is the whole record
///
/// This package's answer travels in the file beside the formula, so `check` needs nothing
/// but the file — no manifest, no ordering assumption, nothing to fall out of step. A
/// workbook someone mailed back a month later still checks.
enum ConformanceWorkbook {

    /// Columns, once, so `emit` and `check` cannot disagree about them.
    private enum Column {
        static let family = "A", formula = "B", excel = "C", ours = "D"
        static let agree = "E", note = "F"
    }

    /// The row the cases start on.
    private static let firstRow = 2

    // MARK: - Emit

    static func emit(to path: String) throws {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Conformance")

        sheet.write("family", to: "A1")
        sheet.write("formula", to: "B1")
        sheet.write("excel", to: "C1")
        sheet.write("ours", to: "D1")
        sheet.write("agree", to: "E1")
        sheet.write("note", to: "F1")

        for (offset, testCase) in ConformanceCases.all.enumerated() {
            let row = firstRow + offset
            sheet.write(testCase.family, to: "\(Column.family)\(row)")
            // The formula as text, so it is readable without clicking into a cell.
            sheet.write(testCase.formula, to: "\(Column.formula)\(row)")
            // The same string as a formula, for Excel to answer.
            sheet.writeFormula(testCase.formula, to: "\(Column.excel)\(row)")
            writeOurAnswer(for: testCase, to: "\(Column.ours)\(row)", in: sheet)
            sheet.writeFormula(agreementFormula(row: row), to: "\(Column.agree)\(row)")
            sheet.write(testCase.note, to: "\(Column.note)\(row)")
        }

        try workbook.save(to: URL(fileURLWithPath: path))
        report("wrote \(ConformanceCases.all.count) cases to \(path)")
        report("open it in Excel, let it calculate, and save — then run `check`")
    }

    /// Writes this package's answer as a value Excel will not recompute.
    ///
    /// An error is written as a formula that *produces* that error rather than as the text
    /// `"#NUM!"`. A cell holding that text is a string, and `ISERROR` is false for it, so the
    /// agreement column would call every error a disagreement.
    private static func writeOurAnswer(for testCase: ConformanceCase, to ref: String,
                                       in sheet: Worksheet) {
        let answer: CellValue
        do {
            answer = try FormulaEvaluator.evaluate(
                try FormulaParser.parse(testCase.formula),
                cells: NoCells(), names: NoNames())
        } catch let failure {
            report("could not evaluate \(testCase.formula): \(failure)")
            #if canImport(os)
            Logger(subsystem: "ConformanceWorkbook", category: "emit")
                .error("could not evaluate \(testCase.formula, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
            sheet.write("!evaluation failed", to: ref)
            return
        }
        switch answer {
        case .number(let value): sheet.write(value, to: ref)
        case .text(let value): sheet.write(value, to: ref)
        case .bool(let value): sheet.writeFormula(value ? "TRUE()" : "FALSE()", to: ref)
        case .error(let code): sheet.writeFormula(producing(code), to: ref)
        default: sheet.write(String(describing: answer), to: ref)
        }
    }

    /// A formula that raises a given error, so the cell is an error rather than text about one.
    private static func producing(_ error: ExcelError) -> String {
        switch error {
        case .na: return "NA()"
        case .div0: return "1/0"
        case .value: return "VALUE(\"!\")"
        case .num: return "SQRT(-1)"
        case .ref: return "INDEX(A1:A1, 2)"
        case .name: return "NOTAFUNCTION()"
        case .null: return "SUM(A1:A1 B1:B1)"
        }
    }

    /// The human-readable flag, so the file is useful before `check` ever runs.
    ///
    /// Numbers are compared with a relative tolerance, because two correct implementations
    /// of a Bessel function do not agree to the last bit and never will. Text is compared
    /// exactly, because for the complex family the exact string *is* the answer.
    private static func agreementFormula(row: Int) -> String {
        let excel = "\(Column.excel)\(row)", ours = "\(Column.ours)\(row)"
        return """
        IF(ISERROR(\(excel))<>ISERROR(\(ours)), "DIFFER", \
        IF(ISERROR(\(excel)), "both error", \
        IF(ISNUMBER(\(excel)), \
        IF(ABS(\(excel)-\(ours))<=0.000000001*MAX(1,ABS(\(ours))), "ok", "DIFFER"), \
        IF(EXACT(\(excel),\(ours)), "ok", "DIFFER"))))
        """
    }

    // MARK: - Check

    static func check(_ path: String) throws {
        let workbook = try Workbook(xlsxData: try Data(contentsOf: URL(fileURLWithPath: path)))
        guard let sheet = workbook.sheets.first(where: { $0.name == "Conformance" }) else {
            throw Failure.noConformanceSheet
        }

        var agreed = 0, differed = 0, uncalculated = 0
        for (offset, testCase) in ConformanceCases.all.enumerated() {
            let row = firstRow + offset
            let excel = cached(sheet.cell(at: "\(Column.excel)\(row)"))
            let ours = cached(sheet.cell(at: "\(Column.ours)\(row)"))

            guard let excel else {
                // Excel writes a cached value for every formula it calculates. Its absence
                // means the file was never opened, not that the answers matched.
                uncalculated += 1
                continue
            }
            if let ours, agree(excel, ours) {
                agreed += 1
            } else {
                differed += 1
                say("DIFFER  [\(testCase.family)]  \(testCase.formula)")
                say("        excel: \(describe(excel))")
                say("        ours:  \(ours.map(describe) ?? "—")")
                say("        why it is here: \(testCase.note)")
            }
        }

        say("")
        say("agreed \(agreed), differed \(differed), not calculated \(uncalculated)")
        if uncalculated > 0 {
            say("`not calculated` means Excel has not opened and saved this file yet —")
            say("those rows are unanswered, not agreed.")
        }
    }

    /// A formula cell's cached value, or a literal's own value.
    private static func cached(_ value: CellValue?) -> CellValue? {
        guard let value else { return nil }
        if case .formula(_, let cached) = value { return cached }
        return value
    }

    /// Whether two answers are the same answer.
    private static func agree(_ excel: CellValue, _ ours: CellValue) -> Bool {
        switch (excel, ours) {
        case (.number(let a), .number(let b)):
            // Relative, with an absolute floor: two correct implementations of a
            // transcendental function agree to about this and no further.
            return abs(a - b) <= 1e-9 * max(1, abs(b))
        case (.text(let a), .text(let b)): return a == b
        case (.bool(let a), .bool(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }

    private static func describe(_ value: CellValue) -> String {
        switch value {
        case .number(let v): return "\(v)"
        case .text(let v): return "\"\(v)\""
        case .bool(let v): return v ? "TRUE" : "FALSE"
        case .error(let v): return v.rawValue
        default: return String(describing: value)
        }
    }

    // MARK: - Plumbing

    /// No cells: every case is a self-contained formula over literals.
    ///
    /// An empty sheet rather than a stub — a case that reached for a cell would get the same
    /// `nil` a genuinely empty workbook gives, so a formula that needs one fails here in the
    /// way it would fail there rather than in some way of this type's invention.
    private struct NoCells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }

    /// No defined names either.
    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    enum Failure: Error, CustomStringConvertible {
        case usage
        case noConformanceSheet

        var description: String {
            switch self {
            case .usage: return "usage: conformance-workbook <emit|check> <path.xlsx>"
            case .noConformanceSheet: return "no sheet named Conformance in that file"
            }
        }
    }

    /// A line of the report.
    ///
    /// Standard output, because for this program the report *is* the output — it is meant to
    /// be read, redirected and diffed. That is a different thing from logging, which is what
    /// ``report(_:)`` does and where the system log belongs.
    static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// A diagnostic about the run rather than a result of it.
    static func report(_ message: String) {
        FileHandle.standardError.write(Data(("conformance: " + message + "\n").utf8))
        #if canImport(os)
        // Public privacy: a formula the operator wrote and this program's own account of it.
        Logger(subsystem: "ConformanceWorkbook", category: "check")
            .error("\(message, privacy: .public)")
        #endif
    }
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
do {
    guard arguments.count == 2 else { throw ConformanceWorkbook.Failure.usage }
    switch arguments[0] {
    case "emit": try ConformanceWorkbook.emit(to: arguments[1])
    case "check": try ConformanceWorkbook.check(arguments[1])
    default: throw ConformanceWorkbook.Failure.usage
    }
} catch let failure {
    ConformanceWorkbook.report("\(failure)")
    #if canImport(os)
    Logger(subsystem: "ConformanceWorkbook", category: "run")
        .error("\(String(describing: failure), privacy: .public)")
    #endif
    exit(1)
}
