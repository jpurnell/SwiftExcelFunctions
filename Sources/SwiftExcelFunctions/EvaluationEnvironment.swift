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

    init(
        cells: any CellValueProvider,
        names: any NameResolver,
        functions: FunctionRegistry,
        callingCell: CellAddress? = nil,
        currentSheet: String = "",
        random: (any RandomSource)? = nil,
        simulation: (any SimulationResultProvider)? = nil,
        depth: FormulaEvaluator.Depth = FormulaEvaluator.Depth()
    ) {
        self.cells = cells
        self.names = names
        self.functions = functions
        self.callingCell = callingCell
        self.currentSheet = currentSheet
        self.random = random
        self.simulation = simulation
        self.depth = depth
    }

    /// The same environment, one level further into the tree.
    ///
    /// Descending is not calling: an operator is not a function and Excel does not count it.
    /// See ``FormulaEvaluator/maxCallDepth``.
    var descended: EvaluationEnvironment { withDepth(depth.descended) }

    /// The same environment, one level deeper and one function call further in.
    ///
    /// - Throws: ``FormulaEvaluator/EvaluationError/callDepthExceeded`` past Excel's 65.
    func calling() throws -> EvaluationEnvironment { withDepth(try depth.calling()) }

    private func withDepth(_ depth: FormulaEvaluator.Depth) -> EvaluationEnvironment {
        EvaluationEnvironment(
            cells: cells, names: names, functions: functions, callingCell: callingCell,
            currentSheet: currentSheet, random: random, simulation: simulation, depth: depth)
    }
}
