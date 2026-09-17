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
            // The same string as a formula, for Excel to answer — with the prefix the
            // file format requires for anything newer than Excel 2007.
            writeQuestion(testCase.formula, to: "\(Column.excel)\(row)", in: sheet)
            writeOurAnswer(for: testCase, to: "\(Column.ours)\(row)", in: sheet)
            sheet.writeFormula(agreementFormula(row: row), to: "\(Column.agree)\(row)")
            sheet.write(testCase.note, to: "\(Column.note)\(row)")
        }

        try workbook.save(to: URL(fileURLWithPath: path))
        report("wrote \(ConformanceCases.all.count) cases to \(path)")
        report("open it in Excel, let it calculate, and save — then run `check`")
    }

    /// Functions that postdate Excel 2007 and must be stored with an `_xlfn.` prefix.
    ///
    /// **This cost the first conformance round eight of its rows.** Every one came back
    /// `#NAME?`, and the correlation was exact: the eight were the only post-2007 names
    /// among the cases. A workbook stores `BETA.DIST` as `_xlfn.BETA.DIST`, and a file that
    /// spells it plainly is asking for a function Excel does not have — so the answer says
    /// nothing whatever about whether this package computes `BETA.DIST` correctly.
    ///
    /// The legacy spellings were unaffected, which is what made the pattern visible: the
    /// pre-2007 `BETADIST` answered while the 2010 `BETA.DIST` beside it did not.
    private static let requiringPrefix: Set<String> = [
        "BETA.DIST", "BETA.INV", "BINOM.DIST", "BINOM.INV", "CHISQ.DIST", "CHISQ.DIST.RT",
        "CHISQ.INV", "CHISQ.INV.RT", "CHISQ.TEST", "CONFIDENCE.NORM", "CONFIDENCE.T",
        "EXPON.DIST", "F.DIST", "F.DIST.RT", "F.INV", "F.INV.RT", "F.TEST", "GAMMA.DIST",
        "GAMMA.INV", "HYPGEOM.DIST", "LOGNORM.DIST", "LOGNORM.INV", "NEGBINOM.DIST",
        "NORM.DIST", "NORM.INV", "NORM.S.DIST", "NORM.S.INV", "PERCENTRANK.EXC",
        "PERCENTRANK.INC", "POISSON.DIST", "QUARTILE.EXC", "QUARTILE.INC", "T.DIST",
        "T.DIST.2T", "T.DIST.RT", "T.INV", "T.INV.2T", "T.TEST", "WEIBULL.DIST", "Z.TEST",
        "IMSEC", "IMSECH", "IMCSC", "IMCSCH", "IMCOT", "IMTAN",
    ]

    /// Writes the question for Excel, prefixed where the file format requires it.
    ///
    /// The prefix has to be applied to the **parsed tree** rather than to the text, because
    /// `FormulaParser` uppercases every function name it reads — so a formula written as
    /// `_xlfn.BETA.DIST(…)` is stored as `_XLFN.BETA.DIST(…)`, and whether Excel accepts
    /// that is a question nobody needs to have. Naming the function in the tree keeps the
    /// spelling the format documents.
    private static func writeQuestion(_ formula: String, to ref: String, in sheet: Worksheet) {
        let ast: FormulaAST
        do {
            ast = try FormulaParser.parse(formula)
        } catch let failure {
            // A case this package cannot even parse is a case it cannot answer, so the
            // cell becomes text and the row will read as a disagreement — which is the
            // honest outcome rather than a silently missing question.
            report("could not parse \(formula) — writing it as text instead: \(failure)")
            #if canImport(os)
            Logger(subsystem: "ConformanceWorkbook", category: "emit")
                .error("could not parse \(formula, privacy: .public): \(String(describing: failure), privacy: .public)")
            #endif
            sheet.write(formula, to: ref)
            return
        }
        guard case .function(let name, let arguments) = ast,
              requiringPrefix.contains(name) else {
            sheet.writeFormula(formula, to: ref)
            return
        }
        sheet.write(FormulaAST.function("_xlfn." + name, arguments), to: ref)
    }

    /// Writes this package's answer as a value Excel will not recompute.
    ///
    /// An error is written as a formula that *produces* that error rather than as the text
    /// `"#NUM!"`. A cell holding that text is a string, and `ISERROR` is false for it, so the
    /// agreement column would call every error a disagreement.
    private static func writeOurAnswer(for testCase: ConformanceCase, to ref: String,
                                       in sheet: Worksheet) {
        writeOurAnswer(forFormula: testCase.formula, to: ref, in: sheet)
    }

    /// Writes this package's answer to one formula as a value Excel will not recompute.
    private static func writeOurAnswer(forFormula formula: String, to ref: String,
                                       in sheet: Worksheet) {
        let answer: CellValue
        do {
            answer = try FormulaEvaluator.evaluate(
                try FormulaParser.parse(formula),
                cells: NoCells(), names: NoNames())
        } catch let failure {
            report("could not evaluate \(formula): \(failure)")
            #if canImport(os)
            Logger(subsystem: "ConformanceWorkbook", category: "emit")
                .error("could not evaluate \(formula, privacy: .public): \(String(describing: failure), privacy: .public)")
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
        case .calc:
            // A lambda nobody called is a function sitting where a value belongs, which is
            // what `#CALC!` means and the shortest way to produce one. The `_xlfn.`/`_xlpm.`
            // prefixes are the file format's, not Excel's UI — a file that writes them wrong
            // shows `#NAME?` here instead, which the sheet's canaries exist to catch.
            return "_xlfn.LAMBDA(_xlpm.x,_xlpm.x)"
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

    // MARK: - Divergences

    /// Emits a sheet showing every point where this package and Excel disagree, with an
    /// independent reference so Excel can compute its own error.
    ///
    /// The error columns are **formulas**, not values. Excel works out how far it is from
    /// scipy's answer itself, in front of whoever opens the file, which is a different kind
    /// of evidence from being told the number.
    static func divergences(to path: String) throws {
        let workbook = Workbook()
        try writeBesselSheet(workbook.addSheet(name: "Bessel"))
        try writeExactSheet(workbook.addSheet(name: "Exact values"))
        try workbook.save(to: URL(fileURLWithPath: path))
        say("wrote \(DivergenceCases.bessel.count) Bessel points and "
            + "\(DivergenceCases.exact.count) exact cases to \(path)")
        say("open it in Excel — the error columns are formulas, so Excel computes its own.")
    }

    private static func writeBesselSheet(_ sheet: Worksheet) throws {
        sheet.write("Excel's Bessel functions against an independent reference", to: "A1")
        sheet.write("reference values: scipy 1.18.1. error columns are relative, "
                    + "and Excel computes them.", to: "A2")

        let headers = ["formula", "Excel", "this package", "scipy (reference)",
                       "Excel's error", "our error", "closer to the reference"]
        for (index, title) in headers.enumerated() {
            sheet.write(title, to: "\(columnLetter(index))4")
        }

        for (offset, point) in DivergenceCases.bessel.enumerated() {
            let row = 5 + offset
            sheet.write(point.formula, to: "A\(row)")
            writeQuestion(point.formula, to: "B\(row)", in: sheet)
            writeOurAnswer(forFormula: point.formula, to: "C\(row)", in: sheet)
            sheet.write(point.reference, to: "D\(row)")
            // Relative error, guarded so a reference of zero does not divide by it.
            sheet.writeFormula("IF(D\(row)=0,ABS(B\(row)),ABS(B\(row)-D\(row))/ABS(D\(row)))",
                               to: "E\(row)")
            sheet.writeFormula("IF(D\(row)=0,ABS(C\(row)),ABS(C\(row)-D\(row))/ABS(D\(row)))",
                               to: "F\(row)")
            sheet.writeFormula("IF(E\(row)<F\(row),\"Excel\",IF(F\(row)<E\(row),\"this package\",\"tie\"))",
                               to: "G\(row)")
        }

        let last = 4 + DivergenceCases.bessel.count
        let summary = last + 2
        sheet.write("how many points each is closer on", to: "A\(summary)")
        sheet.write("Excel", to: "A\(summary + 1)")
        sheet.writeFormula("COUNTIF(G5:G\(last),\"Excel\")", to: "B\(summary + 1)")
        sheet.write("this package", to: "A\(summary + 2)")
        sheet.writeFormula("COUNTIF(G5:G\(last),\"this package\")", to: "B\(summary + 2)")
        sheet.write("tie", to: "A\(summary + 3)")
        sheet.writeFormula("COUNTIF(G5:G\(last),\"tie\")", to: "B\(summary + 3)")
        sheet.write("Excel's worst relative error", to: "A\(summary + 5)")
        sheet.writeFormula("MAX(E5:E\(last))", to: "B\(summary + 5)")
        sheet.write("ours, worst", to: "A\(summary + 6)")
        sheet.writeFormula("MAX(F5:F\(last))", to: "B\(summary + 6)")
    }

    private static func writeExactSheet(_ sheet: Worksheet) throws {
        sheet.write("Values that are exact by definition, where no reference is needed", to: "A1")
        sheet.write("each of these has an exactly known answer, so no reference is needed.",
                    to: "A2")

        for (index, title) in ["formula", "Excel", "this package", "the exact answer",
                               "what it shows"].enumerated() {
            sheet.write(title, to: "\(columnLetter(index))4")
        }
        for (offset, item) in DivergenceCases.exact.enumerated() {
            let row = 5 + offset
            sheet.write(item.formula, to: "A\(row)")
            writeQuestion(item.formula, to: "B\(row)", in: sheet)
            writeOurAnswer(forFormula: item.formula, to: "C\(row)", in: sheet)
            sheet.write(item.truth, to: "D\(row)")
            sheet.write(item.note, to: "E\(row)")
        }
    }

    /// `A`, `B`, `C`… for a zero-based column index. Seven columns; no need for `AA`.
    private static func columnLetter(_ index: Int) -> String {
        String(UnicodeScalar(UInt8(65 + index)))
    }

    // MARK: - Check

    static func check(_ path: String) throws {
        let workbook = try Workbook(xlsxData: try Data(contentsOf: URL(fileURLWithPath: path)))
        guard let sheet = workbook.sheets.first(where: { $0.name == "Conformance" }) else {
            throw Failure.noConformanceSheet
        }

        var agreed = 0, differed = 0, uncalculated = 0, diverged = 0
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
            } else if let why = ConformanceCases.knownDivergences[testCase.formula] {
                // A disagreement that has already been chased down and attributed. Counted
                // and named, never silently skipped: a divergence that quietly stopped
                // happening would be worth knowing about too.
                diverged += 1
                say("KNOWN   [\(testCase.family)]  \(testCase.formula)")
                say("        excel: \(describe(excel))")
                say("        ours:  \(ours.map(describe) ?? "—")")
                say("        \(why)")
            } else {
                differed += 1
                say("DIFFER  [\(testCase.family)]  \(testCase.formula)")
                say("        excel: \(describe(excel))")
                say("        ours:  \(ours.map(describe) ?? "—")")
                say("        why it is here: \(testCase.note)")
            }
        }

        say("")
        say("agreed \(agreed), known divergence \(diverged), differed \(differed), "
            + "not calculated \(uncalculated)")
        if uncalculated > 0 {
            say("`not calculated` means Excel has not opened and saved this file yet —")
            say("those rows are unanswered, not agreed.")
        }
        if differed > 0 || uncalculated > 0 {
            // The exit code is what makes this runnable as a check rather than read as a
            // report. A known divergence is not a failure; anything else is.
            throw Failure.disagreed(differed: differed, uncalculated: uncalculated)
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
        case noSheet
        case disagreed(differed: Int, uncalculated: Int)

        var description: String {
            switch self {
            case .usage:
                return "usage: conformance-workbook "
                    + "<emit|check|divergences|depth|depth-read> <path.xlsx>"
            case .noConformanceSheet: return "no sheet named Conformance in that file"
            case .noSheet: return "no sheet named Limits in that file"
            case .disagreed(let differed, let uncalculated):
                var reasons: [String] = []
                if differed > 0 { reasons.append("\(differed) unexplained disagreement(s)") }
                if uncalculated > 0 { reasons.append("\(uncalculated) row(s) Excel never answered") }
                return reasons.joined(separator: ", ")
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
    case "divergences": try ConformanceWorkbook.divergences(to: arguments[1])
    case "depth": try RecursionDepthSheet.emit(to: arguments[1])
    case "depth-read": try RecursionDepthSheet.read(arguments[1])
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
