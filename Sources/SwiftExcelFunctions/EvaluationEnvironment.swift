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

    /// Names bound by an enclosing `LET` or `LAMBDA`, innermost first.
    ///
    /// Keyed by ``key(for:)`` rather than by the spelling, because Excel's names are
    /// case-insensitive and `LET(Rate, 0.05, RATE*2)` is one name used twice.
    ///
    /// A binding **shadows** a workbook name of the same spelling, and only inside the form
    /// that made it. That falls out of the environment being a value: an inner expression gets
    /// a copy with one more entry, and nothing it does can reach what encloses it.
    let bindings: [String: CellValue]

    init(
        cells: any CellValueProvider,
        names: any NameResolver,
        functions: FunctionRegistry,
        callingCell: CellAddress? = nil,
        currentSheet: String = "",
        random: (any RandomSource)? = nil,
        simulation: (any SimulationResultProvider)? = nil,
        depth: FormulaEvaluator.Depth = FormulaEvaluator.Depth(),
        bindings: [String: CellValue] = [:]
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
    }

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
        return copy(depth: depth, bindings: merged)
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
    var descended: EvaluationEnvironment { copy(depth: depth.descended, bindings: bindings) }

    /// The same environment, one level deeper and one function call further in.
    ///
    /// - Throws: ``FormulaEvaluator/EvaluationError/callDepthExceeded`` past Excel's 65.
    func calling() throws -> EvaluationEnvironment {
        copy(depth: try depth.calling(), bindings: bindings)
    }

    /// The same environment with an entirely different set of names.
    ///
    /// Not a merge: a lambda's body sees the scope the lambda was *written* in, and the
    /// caller's names are not part of that. Adding to them instead of replacing them is how a
    /// closure stops being lexical.
    func withBindings(_ replacement: [String: CellValue]) -> EvaluationEnvironment {
        copy(depth: depth, bindings: replacement)
    }

    /// The same environment with a different set of counters.
    ///
    /// A `LAMBDA` invocation is counted here rather than by ``calling()``, because Excel keeps
    /// the two budgets apart — see ``FormulaEvaluator/maxRecursionDepth``.
    func withDepth(_ depth: FormulaEvaluator.Depth) -> EvaluationEnvironment {
        copy(depth: depth, bindings: bindings)
    }

    private func copy(
        depth: FormulaEvaluator.Depth, bindings: [String: CellValue]
    ) -> EvaluationEnvironment {
        EvaluationEnvironment(
            cells: cells, names: names, functions: functions, callingCell: callingCell,
            currentSheet: currentSheet, random: random, simulation: simulation,
            depth: depth, bindings: bindings)
    }
}
