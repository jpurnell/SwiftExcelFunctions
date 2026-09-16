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
/// Microsoft documents 64 levels of *function nesting* and says nothing whatever about
/// `LAMBDA` recursion, so the only authority is Excel itself.
///
/// ```
/// swift run conformance-workbook depth ~/Desktop/limits.xlsx
/// # open it, let it calculate, save it
/// swift run conformance-workbook depth-read ~/Desktop/limits.xlsx
/// ```
///
/// ## What it found — the programme is complete
///
/// | Question | Answer | Round |
/// |---|---|---|
/// | expression nesting | **65 calls load, 66 do not** | 1 |
/// | how nesting is enforced | **when the file loads** — Excel deletes the cell and calls the file damaged | 1 |
/// | `REDUCE` over `SEQUENCE(n)` | no limit found to **8,192** | 2 |
/// | recursion depth | **4,095 invocations succeed; the 4,096th is `#NUM!`** | 4 |
/// | calls or stack? | **calls** — three more function calls per level refuses at the *same* depth, confirmed at the boundary | 3, 5 |
/// | is the refusal catchable? | **no** — `IFERROR` does not trap it; the cell caches `#NUM!` | 3 |
/// | one budget or two? | **two** — a 4,090-deep recursion works from inside 60 nested `IF`s, and 4,150 is well past the limit | 5 |
///
/// **What this package should build, then:** two counters, not one. An expression-nesting
/// bound of 65 and a call bound of 4,096, kept apart because Excel keeps them apart.
/// `FormulaEvaluator.maxDepth` is a single counter at 256 incremented once per *AST node*,
/// which is wrong three ways over — too small, counting the wrong thing, and conflating two
/// budgets Excel measures separately.
///
/// The uncatchable refusal is the subtle one. `IFERROR` sits on the same stack that ran out,
/// so an evaluator returning `#NUM!` through its own error-handling path would be *more
/// forgiving than Excel*, and a formula would recover here where the real thing does not.
///
/// ## The sheet from here
///
/// Every section is now a control with a known answer, so the file is a **regression check**:
/// emit it against a new Excel, read it, and anything that moved is news. The programme it
/// was built to run is finished.
///
/// ## The two canaries
///
/// `REDUCE` over three cells, answer 6, proves the `_xlfn.`/`_xlpm.` prefixes are written the
/// way the format wants. A self-applying `LAMBDA` at depth 3, answer 3, proves Excel accepts
/// the nameless recursion the ladders are built from. A sheet whose canaries are wrong is
/// measuring its own defects, so ``read(_:)`` reports them first and stops if either fails.
enum RecursionDepthSheet {

    /// Which layout this version of the tool writes and expects.
    ///
    /// **Stamped into the file, because a round read with the wrong map is worse than no
    /// reading at all.** Round three was emitted over a path whose round-two copy was open
    /// in Excel; saving from Excel put round two back, and `read` — mapping round three's
    /// rows — reported an empty canary, a ladder one row short and twenty-one missing rows.
    /// Every one of those was a layout mismatch wearing the costume of a measurement.
    static let round = 5

    /// The column holding what was asked, the question in words, and Excel's answer.
    private enum Column {
        static let depth = "A", question = "B", answer = "C"
        /// Where the round number sits.
        static let round = "E1"
        /// The two canary rows.
        static let prefixCanary = "C9", selfCanary = "C10"
    }

    // MARK: - The plan
    //
    // Emit and read walk the *same* list, so they cannot disagree about where a section
    // begins — which is the bug the round stamp exists to catch, removed outright.

    /// What a section asks Excel.
    enum Kind {
        /// `IF(TRUE, … , d)` nested `d` deep. No `LAMBDA` involved.
        case nesting
        /// A self-applying recursive `LAMBDA`, counting down from `d`.
        case recursion(step: String)
        /// The same, reached from inside `nested` layers of `IF`.
        case recursionUnderNesting(step: String, nested: Int)
        /// A recursion of fixed depth, wrapped in a *varying* number of `IF` layers —
        /// so the ladder counts the nesting rather than the recursion.
        case nestingLadderAroundRecursion(step: String, depth: Int)
        /// `REDUCE` over `SEQUENCE(d)`, which iterates rather than recursing.
        case iteration
    }

    /// One block of rows.
    struct Section {
        let title: String
        let kind: Kind
        let depths: [Int]
        /// The row its header sits on; the questions follow it.
        var headerRow = 0
    }

    /// The thin body contributes a literal 1 per level.
    static let thinStep = "1"

    /// The fat body contributes the same 1 through three more function calls.
    static let fatStep = "SUM(1,ABS(SIGN(_xlpm.n)))-1"

    /// Every section, in order, with its rows assigned.
    ///
    /// - Returns: The sections, each knowing where it begins.
    static func plan() -> [Section] {
        var sections = [
            // 4090 is five short of the limit, so 4090 + 8 is over it. A shared counter
            // must refuse from 8 layers up; a separate one cannot refuse at any of these.
            Section(title: "one budget or two — a 4090-deep recursion, from inside N IFs",
                    kind: .nestingLadderAroundRecursion(step: thinStep, depth: 4090),
                    depths: [0, 2, 4, 8, 32, 60]),
            // Controls, so a round that goes wrong says so rather than looking like news.
            Section(title: "control — the limit itself, known to be 4094 / 4095",
                    kind: .recursion(step: thinStep), depths: [4093, 4094, 4095]),
            Section(title: "control — expression nesting, known to be 65",
                    kind: .nesting, depths: [64, 65]),
            Section(title: "control — REDUCE, known to reach 8192",
                    kind: .iteration, depths: [8192]),
            // Sharper than round 3's control, which checked the fat body at 3072 and 4096.
            // At the exact boundary, an identical answer confirms "calls, not stack" where
            // it matters rather than a thousand levels short of it.
            Section(title: "control — the fat body at the boundary",
                    kind: .recursion(step: fatStep), depths: [4094, 4095]),
        ]
        var row = 12
        for index in sections.indices {
            sections[index].headerRow = row
            row += sections[index].depths.count + 2
        }
        return sections
    }

    // MARK: - Emit

    /// Writes the workbook.
    ///
    /// - Parameter path: Where to write it.
    static func emit(to path: String) throws {
        let workbook = Workbook()
        let sheet = workbook.addSheet(name: "Limits")

        instructions(in: sheet)
        canaries(in: sheet)
        for section in plan() { write(section, in: sheet) }

        // Asked before the save, or the answer is always yes. Asked of the resolved URL
        // rather than of the path string, which is what the safety checker wants and is the
        // more precise question — a path with a `..` in it names a file somewhere other
        // than where it reads.
        let url = URL(fileURLWithPath: path).standardized
        let replacing = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
            .isRegularFile ?? false
        try workbook.save(to: url)
        if replacing {
            ConformanceWorkbook.report("note: \(path) already existed and was replaced — "
                + "close any copy open in Excel, or it will save itself back over this one")
        }
        ConformanceWorkbook.report("wrote round \(round) of the limits workbook to \(path)")
        ConformanceWorkbook.report("open it, let it calculate, save — then run `depth-read`")
    }

    private static func instructions(in sheet: Worksheet) {
        sheet.write("Excel's own limits — round \(round)", to: "A1")
        sheet.write("round", to: "D1")
        sheet.write(Double(round), to: Column.round)
        sheet.write("Nothing here tests SwiftExcelFunctions. Every cell is a question for Excel.",
                    to: "A2")
        sheet.write("Open, let it calculate, save where it is. Nothing to add by hand.",
                    to: "A3")
        sheet.write("Settled: 65 nested calls load and 66 do not; 4095 LAMBDA invocations "
            + "succeed and the 4096th is #NUM!;", to: "A4")
        sheet.write("a body with three more calls per level refuses at exactly the same "
            + "depth, so the budget is counted in calls.", to: "A5")
        sheet.write("This round asks one question: do nesting and recursion draw on one "
            + "budget or two?", to: "A6")
        sheet.write("If a row stalls, delete it — a deleted row reads as deleted rather than "
            + "as a refusal.", to: "A7")
    }

    /// The two rows whose answers are known, so a broken sheet is obvious.
    private static func canaries(in sheet: Worksheet) {
        sheet.write("canary — prefixes; this must be 6", to: "A9")
        sheet.write(1, to: "Z1")
        sheet.write(2, to: "Z2")
        sheet.write(3, to: "Z3")
        raw("_xlfn.REDUCE(0,Z1:Z3,_xlfn.LAMBDA(_xlpm.a,_xlpm.b,_xlpm.a+_xlpm.b))",
            to: Column.prefixCanary, in: sheet)

        sheet.write("canary — self-applying LAMBDA; this must be 3", to: "A10")
        let body = selfApplying(step: thinStep)
        raw("\(body)(\(body),3)", to: Column.selfCanary, in: sheet)
    }

    /// Writes one section's header and questions.
    private static func write(_ section: Section, in sheet: Worksheet) {
        sheet.write(section.title, to: "\(Column.depth)\(section.headerRow)")
        sheet.write("asked", to: "\(Column.question)\(section.headerRow)")
        sheet.write("Excel", to: "\(Column.answer)\(section.headerRow)")

        for (offset, depth) in section.depths.enumerated() {
            let row = section.headerRow + 1 + offset
            sheet.write(Double(depth), to: "\(Column.depth)\(row)")
            sheet.write(description(of: section.kind, depth: depth),
                        to: "\(Column.question)\(row)")
            raw(formula(for: section.kind, depth: depth),
                to: "\(Column.answer)\(row)", in: sheet)
        }
    }

    /// The formula a row puts to Excel.
    ///
    /// **Not wrapped in `IFERROR` any more.** Round three wrapped them and Excel cached
    /// `#NUM!` regardless: the recursion-limit error is *not* trappable — `IFERROR` sits on
    /// the same stack that ran out, so it never gets the chance. Leaving the error bare is
    /// therefore both simpler and more informative, since the error code is itself a
    /// measurement.
    static func formula(for kind: Kind, depth: Int) -> String {
        switch kind {
        case .nesting:
            return nested(depth, around: "\(depth)")
        case .recursion(let step):
            let body = selfApplying(step: step)
            return "\(body)(\(body),\(depth))"
        case .recursionUnderNesting(let step, let layers):
            let body = selfApplying(step: step)
            return nested(layers, around: "\(body)(\(body),\(depth))")
        case .nestingLadderAroundRecursion(let step, let fixed):
            // Here the ladder's value is the *nesting*, and the recursion is fixed.
            let body = selfApplying(step: step)
            return nested(depth, around: "\(body)(\(body),\(fixed))")
        case .iteration:
            return "_xlfn.REDUCE(0,_xlfn.SEQUENCE(\(depth)),"
                + "_xlfn.LAMBDA(_xlpm.a,_xlpm.v,_xlpm.a+_xlpm.v))"
        }
    }

    private static func description(of kind: Kind, depth: Int) -> String {
        switch kind {
        case .nesting: return "IF(TRUE, … , \(depth)) nested \(depth) deep"
        case .recursion: return "LAMBDA(f,n,…)(itself, \(depth))"
        case .recursionUnderNesting(_, let layers):
            return "\(layers) nested IFs around a \(depth)-deep recursion"
        case .nestingLadderAroundRecursion(_, let fixed):
            return "\(depth) nested IFs around a \(fixed)-deep recursion"
        case .iteration: return "REDUCE(0, SEQUENCE(\(depth)), LAMBDA(a,v,a+v))"
        }
    }

    /// A recursive `LAMBDA` that needs no name, by passing itself to itself.
    ///
    /// **This is what removed the manual step**, which had already cost two rounds. A
    /// `LAMBDA` cannot call itself anonymously — there is nothing to call — but it can take
    /// *itself* as a parameter and invoke that:
    ///
    /// ```
    /// LAMBDA(f, n, IF(n<=0, 0, 1 + f(f, n-1)))(LAMBDA(f, n, IF(n<=0, 0, 1 + f(f, n-1))), 100)
    /// ```
    ///
    /// Not a trick this sheet invented: `Wy Now.xlsx` in the corpus writes an
    /// immediately-invoked `LAMBDA`, so Excel demonstrably accepts the form — and the canary
    /// proves it each round rather than trusting that.
    ///
    /// - Parameter step: What each level contributes — `1`, written two ways, so the *work*
    ///   per level varies and the answer does not.
    /// - Returns: The stored form, prefixes and all.
    static func selfApplying(step: String) -> String {
        "_xlfn.LAMBDA(_xlpm.f,_xlpm.n,IF(_xlpm.n<=0,0,\(step)+_xlpm.f(_xlpm.f,_xlpm.n-1)))"
    }

    /// Wraps an expression in `IF(TRUE, …, 0)` to a depth.
    ///
    /// - Parameters:
    ///   - depth: How many `IF`s to wrap.
    ///   - inner: What sits at the centre.
    /// - Returns: The formula text.
    static func nested(_ depth: Int, around inner: String) -> String {
        var formula = inner
        // Bounded by `depth`, which comes from a fixed plan.
        for _ in 0..<depth {
            formula = "IF(TRUE,\(formula),0)"
        }
        return formula
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
        guard let sheet = workbook.sheets.first(where: { $0.name == "Limits" }) else {
            throw ConformanceWorkbook.Failure.noSheet
        }

        let stamped = value(at: Column.round, in: sheet)
        guard case .number(let found)? = stamped, Int(found) == round else {
            say("This file is round \(describe(stamped)) and the tool writes round \(round).")
            say("Reading it with this layout would report layout mismatches as measurements.")
            say("Emit a fresh one — to a path nothing has open — and save that instead.")
            return
        }

        let prefixes = value(at: Column.prefixCanary, in: sheet)
        let selfApplication = value(at: Column.selfCanary, in: sheet)
        say("canary, prefixes:         \(describe(prefixes))   (must be 6)")
        say("canary, self-application: \(describe(selfApplication))   (must be 3)")
        guard case .number(let six)? = prefixes, six == 6,
              case .number(let three)? = selfApplication, three == 3 else {
            say("")
            say("A canary is wrong, so every row below is measuring this sheet's own defect")
            say("rather than Excel's limits. Fix the emit before reading on.")
            return
        }
        say("")

        for section in plan() { report(section, in: sheet) }
    }

    /// Prints one section's answers.
    private static func report(_ section: Section, in sheet: Worksheet) {
        say("\(section.title):")
        var worked: [Int] = []
        var refused: [Int] = []
        var empty = 0
        for (offset, depth) in section.depths.enumerated() {
            let row = section.headerRow + 1 + offset
            let answer = value(at: "\(Column.answer)\(row)", in: sheet)
            switch answer {
            case .number: worked.append(depth)
            case .none, .some(.blank): empty += 1
            default: refused.append(depth)
            }
            // A one-row section is a question rather than a ladder, so it shows its answer.
            if section.depths.count == 1 {
                say("   \(depth) → \(describe(answer))")
            }
        }
        guard section.depths.count > 1 else { return }
        say("   worked up to   \(worked.max().map(String.init) ?? "nothing")")
        say("   first refused  \(refused.min().map(String.init) ?? "never")")
        if empty > 0 {
            say("   \(empty) row(s) empty — deleted, or never calculated")
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
