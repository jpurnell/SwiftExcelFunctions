import Foundation
import SwiftExcelCore

/// Everything an evaluation needs, as one value instead of nine arguments.
///
/// `evaluateNode` threaded eight collaborators plus a depth through every recursive call, and
/// every one of its thirty call sites repeated the list verbatim. That is tolerable while the
/// list is fixed and stops being tolerable the moment something has to be *added* to it —
/// which is exactly what `LET` and `LAMBDA` require, since both introduce names that are
/// visible to an inner expression and to nothing else.
///
/// Local bindings are the reason this type exists, so the shape is chosen for them: an
/// environment is a value, a child is made by copying with one thing changed, and an inner
/// expression cannot alter what encloses it. Lexical scope falls out of that rather than
/// being maintained.
///
/// It also gives the depth counters somewhere to live that is not a parameter list. See
/// ``FormulaEvaluator/Depth``.
struct EvaluationEnvironment {

    /// The cell values the formula can read.
    let cells: any CellValueProvider
    /// The workbook's defined names.
    let names: any NameResolver
    /// The functions available to dispatch through.
    let functions: FunctionRegistry
    /// The cell the formula belongs to, for functions that ask.
    let callingCell: CellAddress?
    /// The sheet unqualified references resolve against.
    let currentSheet: String
    /// The source for `RAND` and `RANDBETWEEN`, if the formula needs one.
    let random: (any RandomSource)?
    /// Simulation results, for the `PSI` family.
    let simulation: (any SimulationResultProvider)?
    /// How far in we are, against the three bounds.
    let depth: FormulaEvaluator.Depth

    /// Whether the enclosing call wants its arguments evaluated as **arrays**.
    ///
    /// **`SUMPRODUCT` forces this and `SUM` does not**, measured in round fifteen:
    /// `SUM(COLUMN($H:$M))` is 8 — the leftmost column — while
    /// `SUMPRODUCT((MOD(COLUMN($H:$M),2)=0)*1)` is 3, which only works if `COLUMN` yields
    /// all six column numbers. The difference is the caller, not `COLUMN`.
    ///
    /// It reaches through nesting, because the corpus shape it exists for wraps `COLUMN` in
    /// `MOD`, in a comparison, in a multiplication. **Whether a nested *aggregate* should
    /// stop it — `SUMPRODUCT(SUM(COLUMN(…)))` — is not measured**, and this propagates
    /// rather than guessing at a boundary nobody has asked Excel about.
    var evaluatesArrays: Bool = false

    /// Names bound by an enclosing `LET` or `LAMBDA`, innermost first.
    ///
    /// Keyed by ``key(for:)`` rather than by the spelling, because Excel's names are
    /// case-insensitive and `LET(Rate, 0.05, RATE*2)` is one name used twice.
    ///
    /// A binding **shadows** a workbook name of the same spelling, and only inside the form
    /// that made it. That falls out of the environment being a value: an inner expression gets
    /// a copy with one more entry, and nothing it does can reach what encloses it.
    let bindings: [String: CellValue]

    /// Parameters the current call left out, which `ISOMITTED` reports on.
    ///
    /// Separate from ``bindings`` rather than marked inside them, because an omitted parameter
    /// reads as blank where it is *used* — Excel's omitted argument behaves as empty — and a
    /// blank is also a perfectly ordinary thing to pass. `f(A1)` with `A1` empty supplies a
    /// value; `f()` does not. Encoding omission as a bound blank would make those two
    /// indistinguishable, and `ISOMITTED` would call an argument the author wrote absent.
    let omitted: Set<String>

    init(
        cells: any CellValueProvider,
        names: any NameResolver,
        functions: FunctionRegistry,
        callingCell: CellAddress? = nil,
        currentSheet: String = "",
        random: (any RandomSource)? = nil,
        simulation: (any SimulationResultProvider)? = nil,
        depth: FormulaEvaluator.Depth = FormulaEvaluator.Depth(),
        bindings: [String: CellValue] = [:],
        omitted: Set<String> = []
    ) {
        self.cells = cells
        self.names = names
        self.functions = functions
        self.callingCell = callingCell
        self.currentSheet = currentSheet
        self.random = random
        self.simulation = simulation
        self.depth = depth
        self.bindings = bindings
        self.omitted = omitted
    }

    /// Whether a name is a parameter the current call left out.
    ///
    /// - Parameter name: the name as the formula spells it.
    func wasOmitted(_ name: String) -> Bool { omitted.contains(Self.key(for: name)) }

    /// The value a local binding gives this name, if one does.
    ///
    /// - Parameter name: the name as the formula spells it, prefix and all.
    /// - Returns: the bound value, or `nil` to ask the workbook.
    func bound(_ name: String) -> CellValue? { bindings[Self.key(for: name)] }

    /// The same environment with more names in scope, shadowing any it already had.
    ///
    /// - Parameter newBindings: name to value, spelled as the formula spells them.
    func binding(_ newBindings: [String: CellValue]) -> EvaluationEnvironment {
        var merged = bindings
        for (name, value) in newBindings { merged[Self.key(for: name)] = value }
        return copy(depth: depth, bindings: merged, omitted: omitted)
    }

    /// How a name is looked up: case-folded, because Excel's names are.
    ///
    /// The `_xlpm.` prefix is **not** stripped. Excel writes it on a parameter's declaration
    /// and on every use, so it matches itself; stripping it would let a parameter and a
    /// workbook name that differ only by the prefix collide. It is a hint about where a name
    /// came from, and this package does not depend on it — see the `LAMBDA` proposal, §12.
    static func key(for name: String) -> String { name.lowercased() }

    /// The same environment, one level further into the tree.
    ///
    /// Descending is not calling: an operator is not a function and Excel does not count it.
    /// See ``FormulaEvaluator/maxCallDepth``.
    var descended: EvaluationEnvironment { copy(depth: depth.descended, bindings: bindings, omitted: omitted) }

    /// The same environment, one level deeper and one function call further in.
    ///
    /// - Throws: ``FormulaEvaluator/EvaluationError/callDepthExceeded`` past Excel's 65.
    func calling() throws -> EvaluationEnvironment {
        copy(depth: try depth.calling(), bindings: bindings, omitted: omitted)
    }

    /// The same environment with an entirely different set of names.
    ///
    /// Not a merge: a lambda's body sees the scope the lambda was *written* in, and the
    /// caller's names are not part of that. Adding to them instead of replacing them is how a
    /// closure stops being lexical.
    func withBindings(_ replacement: [String: CellValue]) -> EvaluationEnvironment {
        copy(depth: depth, bindings: replacement, omitted: omitted)
    }

    /// The same environment, recording which parameters this call left out.
    ///
    /// Replaces rather than adds: omission belongs to one call, and an inner call that
    /// supplies everything must not inherit the outer one's absences.
    func omitting(_ names: Set<String>) -> EvaluationEnvironment {
        copy(depth: depth, bindings: bindings,
             omitted: Set(names.map { Self.key(for: $0) }))
    }

    /// The same environment with a different set of counters.
    ///
    /// A `LAMBDA` invocation is counted here rather than by ``calling()``, because Excel keeps
    /// the two budgets apart — see ``FormulaEvaluator/maxRecursionDepth``.
    func withDepth(_ depth: FormulaEvaluator.Depth) -> EvaluationEnvironment {
        copy(depth: depth, bindings: bindings, omitted: omitted)
    }

    /// The same environment drawing from a different source of randomness.
    ///
    /// `PsiTheo*` reads a distribution's quantile by evaluating the cell's own formula with a
    /// source that returns a chosen `p`, so the theoretical statistics and the samples take
    /// the identical path and cannot disagree about what a call means. Nothing else about the
    /// environment changes — the depth counters in particular are carried, so a distribution
    /// buried in a deep formula is still bounded.
    ///
    /// - Parameter source: the randomness to draw from.
    /// - Returns: a copy reading from it.
    func drawing(from source: any RandomSource) -> EvaluationEnvironment {
        EvaluationEnvironment(
            cells: cells, names: names, functions: functions, callingCell: callingCell,
            currentSheet: currentSheet, random: source, simulation: simulation,
            depth: depth, bindings: bindings, omitted: omitted)
    }

    private func copy(
        depth: FormulaEvaluator.Depth, bindings: [String: CellValue], omitted: Set<String>
    ) -> EvaluationEnvironment {
        var next = EvaluationEnvironment(
            cells: cells, names: names, functions: functions, callingCell: callingCell,
            currentSheet: currentSheet, random: random, simulation: simulation,
            depth: depth, bindings: bindings, omitted: omitted)
        next.evaluatesArrays = evaluatesArrays
        return next
    }

    /// The same environment, evaluating arguments as arrays.
    func evaluatingArrays() -> EvaluationEnvironment {
        var next = self
        next.evaluatesArrays = true
        return next
    }
}
