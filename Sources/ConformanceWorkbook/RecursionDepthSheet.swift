import Foundation
import SwiftExcelCore
import SwiftXLSX

/// A workbook that asks Excel where its own limits are.
///
/// ## Why this is measured rather than chosen
///
/// `LAMBDA` can call itself, which is how a spreadsheet author writes a loop, and an
/// evaluator has to stop somewhere. Picking a number would be guessing at Excel's: too low
/// refuses formulas Excel computes, too high burns a stack on one somebody's Excel refuses.
/// Microsoft documents 64 levels of *function nesting* and says nothing about `LAMBDA`
/// recursion, so the only authority is Excel itself.
///
/// ```
/// swift run conformance-workbook depth ~/Desktop/limits.xlsx
/// # add the two names, let it calculate, save
/// swift run conformance-workbook depth-read ~/Desktop/limits.xlsx
/// ```
///
/// ## Four questions, and why each is separate
///
/// | Section | Asks |
/// |---|---|
/// | nesting | how deep an *expression* may be, with no recursion at all |
/// | thin | how deep a recursive `LAMBDA` may go |
/// | fat | the same, with three more function calls per level |
/// | iteration | whether `REDUCE` over a long sequence is bounded separately |
///
/// **`thin` against `fat` is the question that decides the implementation.** If both fail at
/// the same depth the budget is counted in *calls*, and a counter suffices. If the fat one
/// fails earlier the budget is *stack*, and a call counter would be the wrong instrument —
/// this package would need to measure something closer to the work per level.
///
/// ## The canary
///
/// Row 8 is `REDUCE` over three cells, whose answer is 6. Everything in this sheet depends
/// on the `_xlfn.` and `_xlpm.` prefixes being written the way the format wants, and a file
/// that gets them wrong shows `#NAME?` in every row — which looks exactly like Excel
/// refusing the depth. If the canary is not 6, nothing else here means anything.
enum RecursionDepthSheet {

    /// Where each section starts, so `emit` and `read` cannot disagree.
    private enum Layout {
        static let canaryRow = 8
        static let selfCanaryRow = 9
        static let nestingHeader = 11
        static let selfThinHeader = 21
        static let selfFatHeader = 44
        static let namedThinHeader = 67
        static let namedFatHeader = 90
        static let iterationHeader = 113
        /// The column holding the depth asked for, and the one holding Excel's answer.
        static let depth = "A", question = "B", answer = "C"
    }

    /// A recursive `LAMBDA` that needs no name, by passing itself to itself.
    ///
    /// **This is what removes the manual step**, and the manual step had already cost two
    /// rounds. A `LAMBDA` cannot call itself anonymously — there is nothing to call — but it
    /// can take *itself* as a parameter and invoke that:
    ///
    /// ```
    /// LAMBDA(f, n, IF(n<=0, 0, 1 + f(f, n-1)))(LAMBDA(f, n, IF(n<=0, 0, 1 + f(f, n-1))), 100)
    /// ```
    ///
    /// The immediately-invoked form is not a trick this sheet invented: `Wy Now.xlsx` in the
    /// corpus writes one, so Excel demonstrably accepts it.
    ///
    /// **Whether it is bounded the same way a named recursion is, is a separate question** —
    /// invoking a parameter and resolving a name are different mechanisms and may well have
    /// different budgets. So the named sections stay, for whoever adds the names; the
    /// self-applying ones answer even when nobody does.
    ///
    /// - Parameter step: What each level contributes, which is `1` in both bodies and
    ///   written two ways to vary the work per level rather than the answer.
    /// - Returns: The stored form of the lambda, prefixes and all.
    static func selfApplying(step: String) -> String {
        "_xlfn.LAMBDA(_xlpm.f,_xlpm.n,IF(_xlpm.n<=0,0,"
            + "\(step)+_xlpm.f(_xlpm.f,_xlpm.n-1)))"
    }

    /// The thin body contributes a literal 1 per level.
    static let thinStep = "1"

    /// The fat body contributes the same 1 through three more function calls.
    static let fatStep = "SUM(1,ABS(SIGN(_xlpm.n)))-1"

    /// The depths put to the recursive sections.
    ///
    /// Geometric, because the limit could be anywhere between a hundred and a hundred
    /// thousand and a linear ladder would either miss it or take all afternoon. `read`
    /// reports the bracket — the largest that worked and the smallest that did not — and a
    /// second round can close it if the gap matters.
    static let ladder = [1, 2, 4, 8, 16, 32, 64, 128, 192, 256, 384, 512, 768,
                         1024, 1280, 1536, 2048, 3072, 4096, 6144, 8192]

    /// The depths put to the nesting section.
    ///
    /// **Answered: 65 nested `IF`s load and 66 do not.** The first round asked up to 128 and
    /// Excel replied by refusing to open the file — *"Removed Records: Formula from
    /// /xl/worksheets/sheet1.xml"* — and stripping exactly the four cells above 65. So the
    /// limit is real, it is 65 calls deep, and **Excel enforces it when the file loads
    /// rather than when the formula runs**: an over-nested formula is not `#VALUE!`, it is a
    /// workbook Excel considers damaged.
    ///
    /// Microsoft documents "nested levels of functions: 64", which is consistent if the
    /// outermost call is not counted as nesting. Either way the measured fact is the one to
    /// key off.
    ///
    /// The ladder now stops at 65 so the sheet no longer forces a repair on open — a round
    /// that damages the file takes the other three sections down with it.
    static let nestingLadder = [2, 8, 32, 60, 62, 63, 64, 65]

    // MARK: - Emit

    /// Writes the workbook.
    ///
    /// - Parameter path: Where to write it.
    static func emit(to path: String) throws {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Limits")

        instructions(in: sheet)
        canary(in: sheet)
        nesting(in: sheet)
        selfRecursion(in: sheet, header: Layout.selfThinHeader, step: thinStep,
                      title: "recursion without a name — thin body")
        selfRecursion(in: sheet, header: Layout.selfFatHeader, step: fatStep,
                      title: "recursion without a name — fat body (three more calls per level)")
        recursion(in: sheet, header: Layout.namedThinHeader, name: "depthProbe",
                  title: "recursion by name — thin body (needs depthProbe)")
        recursion(in: sheet, header: Layout.namedFatHeader, name: "depthProbeFat",
                  title: "recursion by name — fat body (needs depthProbeFat)")
        iteration(in: sheet)

        try workbook.save(to: URL(fileURLWithPath: path))
        ConformanceWorkbook.report("wrote the limits workbook to \(path)")
        ConformanceWorkbook.report("add the two names in B4 and B5 (Name Manager → New), "
            + "let it calculate, save — then run `depth-read`")
    }

    /// The header block, including the two names the reader has to add by hand.
    ///
    /// **They are added by hand because this package cannot write them.** SwiftXLSX's
    /// writer emits no `<definedName>` elements at all — it reads them and drops them — so a
    /// workbook generated here carries no names. That is a fifth defect found in the same
    /// reader this month, and it is recorded rather than worked around: injecting XML into a
    /// saved archive to dodge it would be a second writer, which is the thing the package
    /// split exists to prevent.
    private static func instructions(in sheet: Worksheet) {
        sheet.write("Excel's own limits — nesting, recursion, iteration", to: "A1")
        sheet.write("Nothing here tests SwiftExcelFunctions. Every cell is a question for Excel.",
                    to: "A2")
        sheet.write("1. Name Manager (⌃⌘F3) → New, twice, pasting each name and formula:",
                    to: "A3")
        sheet.write("depthProbe", to: "A4")
        sheet.write("=LAMBDA(n, IF(n<=0, 0, 1 + depthProbe(n-1)))", to: "B4")
        sheet.write("depthProbeFat", to: "A5")
        sheet.write("=LAMBDA(n, IF(n<=0, 0, SUM(1, ABS(SIGN(n))) - 1 + depthProbeFat(n-1)))",
                    to: "B5")
        sheet.write("   Scope: Workbook — the default, and what makes a name usable on "
            + "every sheet of the file.", to: "A6")
        sheet.write("2. Let the sheet calculate, then save it where it is. If Excel stalls "
            + "on the largest rows, delete them.", to: "A7")
        sheet.write("Known already: 65 nested IFs load and 66 do not — Excel strips the "
            + "cell on open rather than erroring.", to: "A9")
    }

    /// One row whose answer is known, so a broken file is obvious.
    private static func canary(in sheet: Worksheet) {
        sheet.write("canary — this must be 6", to: "A\(Layout.canaryRow)")
        sheet.write(1, to: "Z1")
        sheet.write(2, to: "Z2")
        sheet.write(3, to: "Z3")
        raw("_xlfn.REDUCE(0,Z1:Z3,_xlfn.LAMBDA(_xlpm.a,_xlpm.b,_xlpm.a+_xlpm.b))",
            to: "\(Layout.answer)\(Layout.canaryRow)", in: sheet)

        // The second canary: self-application, which the sections below depend on as much
        // as every row depends on the prefixes.
        sheet.write("canary — self-applying LAMBDA, this must be 3",
                    to: "A\(Layout.selfCanaryRow)")
        let body = selfApplying(step: thinStep)
        raw("\(body)(\(body),3)", to: "\(Layout.answer)\(Layout.selfCanaryRow)", in: sheet)
    }

    /// A ladder of self-applying recursions, which need nothing added to the file.
    private static func selfRecursion(in sheet: Worksheet, header headerRow: Int,
                                      step: String, title: String) {
        header(title, at: headerRow, in: sheet)
        let body = selfApplying(step: step)
        for (offset, depth) in ladder.enumerated() {
            let row = headerRow + 1 + offset
            sheet.write(Double(depth), to: "\(Layout.depth)\(row)")
            sheet.write("LAMBDA(f,n,…)(itself, \(depth))", to: "\(Layout.question)\(row)")
            raw("IFERROR(\(body)(\(body),\(depth)),\"refused\")",
                to: "\(Layout.answer)\(row)", in: sheet)
        }
    }

    /// How deep an expression may nest, with no recursion involved.
    ///
    /// Microsoft documents 64 and the cases cluster around it. The innermost value is the
    /// depth itself, so a row that works says so in its own answer.
    private static func nesting(in sheet: Worksheet) {
        header("expression nesting (no LAMBDA) — the limit is known; this is the regression",
               at: Layout.nestingHeader, in: sheet)
        for (offset, depth) in nestingLadder.enumerated() {
            let row = Layout.nestingHeader + 1 + offset
            sheet.write(Double(depth), to: "\(Layout.depth)\(row)")
            sheet.write("IF(TRUE, … , \(depth)) nested \(depth) deep",
                        to: "\(Layout.question)\(row)")
            raw(nested(depth), to: "\(Layout.answer)\(row)", in: sheet)
        }
    }

    /// `IF(TRUE, …, d)` nested to a depth, with `d` at the centre.
    ///
    /// - Parameter depth: How many `IF`s to wrap.
    /// - Returns: The formula text.
    static func nested(_ depth: Int) -> String {
        var formula = "\(depth)"
        // Bounded by `depth`, which the caller takes from a fixed ladder.
        for _ in 0..<depth {
            formula = "IF(TRUE,\(formula),0)"
        }
        return formula
    }

    /// A ladder of calls to a recursive name.
    private static func recursion(in sheet: Worksheet, header headerRow: Int,
                                  name: String, title: String) {
        header(title, at: headerRow, in: sheet)
        for (offset, depth) in ladder.enumerated() {
            let row = headerRow + 1 + offset
            sheet.write(Double(depth), to: "\(Layout.depth)\(row)")
            sheet.write("\(name)(\(depth))", to: "\(Layout.question)\(row)")
            // Wrapped, so a refusal is a value this can read rather than an error that
            // stops the sheet. Excel's own answer to too much recursion is #NUM!.
            raw("IFERROR(\(name)(\(depth)),\"refused\")",
                to: "\(Layout.answer)\(row)", in: sheet)
        }
    }

    /// The same ladder through `REDUCE`, which iterates without recursing.
    private static func iteration(in sheet: Worksheet) {
        header("iteration — REDUCE over SEQUENCE(n), answer is n(n+1)/2",
               at: Layout.iterationHeader, in: sheet)
        for (offset, depth) in ladder.enumerated() {
            let row = Layout.iterationHeader + 1 + offset
            sheet.write(Double(depth), to: "\(Layout.depth)\(row)")
            sheet.write("REDUCE(0, SEQUENCE(\(depth)), LAMBDA(a,v,a+v))",
                        to: "\(Layout.question)\(row)")
            raw("IFERROR(_xlfn.REDUCE(0,_xlfn.SEQUENCE(\(depth)),"
                + "_xlfn.LAMBDA(_xlpm.a,_xlpm.v,_xlpm.a+_xlpm.v)),\"refused\")",
                to: "\(Layout.answer)\(row)", in: sheet)
        }
    }

    private static func header(_ title: String, at row: Int, in sheet: Worksheet) {
        sheet.write(title, to: "\(Layout.depth)\(row)")
        sheet.write("asked", to: "\(Layout.question)\(row)")
        sheet.write("Excel", to: "\(Layout.answer)\(row)")
    }

    /// Writes a formula **verbatim**, without parsing it.
    ///
    /// Every formula here needs `_xlfn.` on the function and `_xlpm.` on the parameters, and
    /// `FormulaParser` uppercases what it reads — so a tree written back out says
    /// `_XLFN.LAMBDA`, and whether Excel minds is a question nobody needs to have when the
    /// escape hatch already exists. `_RAW` is the reader's own marker for a formula it could
    /// not parse, and the writer puts its text in the file unchanged.
    private static func raw(_ formula: String, to ref: String, in sheet: Worksheet) {
        sheet.write(.function("_RAW", [.text(formula)]), to: ref)
    }

    // MARK: - Read

    /// Reads back what Excel answered.
    ///
    /// - Parameter path: The saved workbook.
    static func read(_ path: String) throws {
        let workbook = try Workbook(contentsOf: URL(fileURLWithPath: path))
        // Said up front, because it decides how to read two of the six sections.
        let defined = ["depthProbe", "depthProbeFat"]
            .filter { workbook.namedRanges.resolve($0) != nil }
        say("names in the file: \(defined.isEmpty ? "none" : defined.joined(separator: ", "))")
        guard let sheet = workbook.sheets.first(where: { $0.name == "Limits" }) else {
            throw ConformanceWorkbook.Failure.noSheet
        }

        let canaryValue = value(at: "\(Layout.answer)\(Layout.canaryRow)", in: sheet)
        say("canary: \(describe(canaryValue))   (must be 6)")
        guard case .number(let six)? = canaryValue, six == 6 else {
            say("")
            say("The canary did not answer 6, so the prefixes are wrong and every other")
            say("row below is measuring the wrong thing. Fix the emit before reading on.")
            return
        }
        say("")

        let selfCanary = value(at: "\(Layout.answer)\(Layout.selfCanaryRow)", in: sheet)
        say("self-application canary: \(describe(selfCanary))   (must be 3)")
        let selfWorks: Bool
        if case .number(let three)? = selfCanary, three == 3 { selfWorks = true } else {
            selfWorks = false
            say("   → Excel refused a self-applying LAMBDA, so the two nameless sections")
            say("     below measure that refusal and not a depth.")
        }
        say("")

        report(section: "expression nesting", header: Layout.nestingHeader,
               depths: nestingLadder, in: sheet)
        if selfWorks {
            report(section: "recursion without a name, thin", header: Layout.selfThinHeader,
                   depths: ladder, in: sheet)
            report(section: "recursion without a name, fat", header: Layout.selfFatHeader,
                   depths: ladder, in: sheet)
        }
        reportNamed(section: "recursion by name, thin", header: Layout.namedThinHeader,
                    name: "depthProbe", workbook: workbook, in: sheet)
        reportNamed(section: "recursion by name, fat", header: Layout.namedFatHeader,
                    name: "depthProbeFat", workbook: workbook, in: sheet)
        report(section: "iteration via REDUCE", header: Layout.iterationHeader,
               depths: ladder, in: sheet)
    }

    /// A named section, which says whether the name is there before saying anything else.
    ///
    /// **A section where even depth 1 refuses has not measured a limit**, it has measured a
    /// missing name: `depthProbe(1)` is `#NAME?`, `IFERROR` turns that into "refused", and
    /// the row reads exactly like a refusal at depth 1. That cost a round, and the guard is
    /// the same doctrine as the canary — a reading that cannot be told apart from a setup
    /// failure is not a reading.
    private static func reportNamed(section: String, header headerRow: Int, name: String,
                                    workbook: Workbook, in sheet: Worksheet) {
        guard workbook.namedRanges.resolve(name) != nil else {
            say("\(section):")
            say("   not measured — no name `\(name)` in this file.")
            say("   Name Manager (⌃⌘F3) → New → Scope: Workbook, and paste what B4/B5 say.")
            return
        }
        report(section: section, header: headerRow, depths: ladder, in: sheet)
    }

    /// Prints one section's bracket.
    private static func report(section: String, header headerRow: Int,
                               depths: [Int], in sheet: Worksheet) {
        var worked: [Int] = []
        var refused: [Int] = []
        var blank = 0
        for (offset, depth) in depths.enumerated() {
            let row = headerRow + 1 + offset
            switch value(at: "\(Layout.answer)\(row)", in: sheet) {
            case .number: worked.append(depth)
            case .text(let text) where text == "refused": refused.append(depth)
            case .error: refused.append(depth)
            case .none, .some(.blank): blank += 1
            case .some: blank += 1
            }
        }
        say("\(section):")
        say("   worked up to   \(worked.max().map(String.init) ?? "nothing")")
        say("   first refused  \(refused.min().map(String.init) ?? "never")")
        if blank > 0 {
            // Deleted or never calculated. Said rather than counted as a refusal, because
            // the two mean opposite things and the sheet invites deleting the slow rows.
            say("   \(blank) row(s) empty — deleted, or the sheet did not calculate them")
        }
    }

    private static func value(at ref: String, in sheet: Worksheet) -> CellValue? {
        sheet.cell(at: ref)?.resolved
    }

    private static func describe(_ value: CellValue?) -> String {
        guard let value else { return "(empty)" }
        switch value {
        case .number(let number): return "\(number)"
        case .text(let text): return "\"\(text)\""
        case .error(let error): return error.rawValue
        case .blank: return "(blank)"
        default: return "\(value)"
        }
    }

    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
