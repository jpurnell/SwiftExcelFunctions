import Foundation
import SwiftExcelCore
import BusinessMath

/// Why a model could not be run.
///
/// Named `TrialRunError` rather than `SimulationError` because BusinessMath already has a
/// `SimulationError`, and this package's callers import both. A collision there would make
/// every downstream user write the module name to disambiguate an error they did not
/// choose to be ambiguous.
///
/// Every case is a refusal *before* any trial, deliberately. A simulation that runs on a
/// bad model does not fail — it produces numbers, and numbers are what the caller came
/// for, so nothing about the output says it should not be trusted.
public enum TrialRunError: Error, Sendable, Equatable {

    /// The model has no uncertain cell, so there is nothing to vary.
    case notSimulable

    /// Nothing to collect: the model declares no outputs and the caller named none.
    ///
    /// Separate from ``notSimulable`` because it is the caller's to fix rather than the
    /// model's — a workbook may legitimately leave the choice open. See
    /// ``ModelSurvey/declaresItsOwnOutputs``.
    case noOutputsToCollect

    /// The evaluation order places a cell before something it reads.
    ///
    /// Carries both so the message can name them: `cell` would have read `precedent`
    /// before `precedent` was computed.
    case orderViolatesDependency(cell: CellRef, precedent: CellRef)

    /// A formula cell the model needs is absent from the evaluation order.
    case orderOmitsCell(CellRef)

    /// Trials must be at least one.
    case invalidTrialCount(Int)

    /// The model is circular, so no evaluation order exists.
    ///
    /// Carries the first cycle found. A circular reference is the model's defect and Excel
    /// reports it too; this refuses rather than iterating to a fixed point, because a
    /// simulation of a model that disagrees with itself is not a simulation of anything.
    case orderHasACycle([CellRef])
}

/// A completed simulation.
///
/// Conforms to ``SimulationResultProvider``, so handing it back to the evaluator is what
/// makes `PsiMean(B4)` answer a number instead of `#N/A`. That is the second of the two
/// passes: run the model, then evaluate the sheet with the run supplied.
public struct SimulationRun: Sendable, SimulationResultProvider {

    /// One completed run per output cell.
    public let outputs: [CellRef: SimulationResults]

    /// How many trials produced it.
    public let trials: Int

    /// The seed that produced it — recorded, because a run nobody can reproduce is an
    /// anecdote rather than a result.
    public let seed: UInt64

    /// Creates a completed run.
    ///
    /// - Parameters:
    ///   - outputs: the collected results, by output cell.
    ///   - trials: how many trials were run.
    ///   - seed: the seed the run used.
    public init(outputs: [CellRef: SimulationResults], trials: Int, seed: UInt64) {
        self.outputs = outputs
        self.trials = trials
        self.seed = seed
    }

    /// The completed run for an output cell, or `nil` if this run did not collect it.
    ///
    /// - Parameter ref: the cell a statistic is asking about.
    /// - Returns: its results, or `nil` — which the statistics report as `#N/A`.
    public func results(for ref: CellRef) -> SimulationResults? { outputs[ref] }
}

/// Runs a model by re-evaluating it, once per trial.
///
/// This is the **correctness baseline** of the two-path design in
/// `PROPOSAL_model_graph_simulation.md` §3.1. It handles every formula the registry can
/// evaluate — text, errors, lookups, all 160 functions — and it is always right. A
/// compiled path handles a subset and must agree with this one bit-for-bit, which is what
/// makes it safe to add later.
///
/// It is also slower by a measured **118×** per propagation operation in a release build
/// (§9.1), so a large model will want the compiled path. It will not need a different
/// answer.
///
/// ## The evaluation order
///
/// A trial loop needs a topological order. When this was written, `DependencyGraph` lived
/// in SwiftXLSX and took a `Worksheet`, so reaching it here would have cost this package
/// its one promise — and writing a second topological sort would have been worse, since
/// two orders that could disagree is exactly what the evaluator already relies on not
/// happening. The order was therefore a parameter.
///
/// **`DependencyGraph` now lives in SwiftExcelCore** and takes a `CellValueProvider`, so
/// the static `run(survey:over:names:inSheet:trials:seed:registry:)` computes it, and
/// ``run(over:names:)`` still accepts one.
/// Both validate rather than trust, because a wrong order does not fail — it reads a cell
/// before that cell has been computed and reports the result as a simulation.
public struct InterpretedRun: Sendable {

    private let survey: ModelSurvey
    private let evaluationOrder: [CellRef]
    private let trials: Int
    private let seed: UInt64
    private let registry: FunctionRegistry

    /// - Parameters:
    ///   - survey: what the recognizer found — the draws and the outputs.
    ///   - evaluationOrder: every formula cell, in topological order.
    ///   - trials: how many times to run the model.
    ///   - seed: the seed for every draw. Required, not defaulted: `RandomSource` has no
    ///     default source by construction and a run without a recorded seed cannot be
    ///     reproduced.
    ///   - registry: the functions to evaluate with.
    public init(
        survey: ModelSurvey,
        evaluationOrder: [CellRef],
        trials: Int,
        seed: UInt64,
        registry: FunctionRegistry = .builtin
    ) {
        self.survey = survey
        self.evaluationOrder = evaluationOrder
        self.trials = trials
        self.seed = seed
        self.registry = registry
    }

    /// Runs the model and collects every output.
    ///
    /// - Parameters:
    ///   - cells: the model's cells. Constants are read from here; formula cells are
    ///     recomputed each trial.
    ///   - names: the named-range resolver.
    /// - Returns: a completed run, ready to hand back to the evaluator.
    /// - Throws: ``TrialRunError`` if the model or the order cannot support a run, or
    ///   whatever evaluating a formula throws.
    public func run(
        over cells: any CellValueProvider,
        names: any NameResolver
    ) throws -> SimulationRun {
        guard trials > 0 else { throw TrialRunError.invalidTrialCount(trials) }
        guard survey.isSimulable else { throw TrialRunError.notSimulable }
        guard !survey.outputs.isEmpty else { throw TrialRunError.noOutputsToCollect }
        try validateOrder(against: cells)

        let random = SeededRandomSource(SplitMix64(seed: seed))
        var collected: [CellRef: [Double]] = [:]
        for output in survey.outputs { collected[output] = [] }

        for _ in 0..<trials {
            var trial = MutableCells(base: cells)
            for ref in evaluationOrder {
                guard let ast = cells.value(at: ref)?.formulaAST else { continue }
                let value = try FormulaEvaluator.evaluate(
                    ast, cells: trial, names: names, functions: registry,
                    at: nil, inSheet: "", random: random)
                trial.overrides[ref.positionKey] = value
            }
            for output in survey.outputs {
                // A trial that produced an error contributes nothing rather than a zero.
                // Averaging a `#DIV/0!` as 0 is the plausible-wrong-number this project
                // exists to avoid; a short vector at least says something went wrong.
                if case .number(let n) = trial.overrides[output.positionKey] ?? .blank {
                    collected[output, default: []].append(n)
                }
            }
        }

        var outputs: [CellRef: SimulationResults] = [:]
        for (ref, values) in collected {
            outputs[ref] = SimulationResults(values: values)
        }
        return SimulationRun(outputs: outputs, trials: trials, seed: seed)
    }

    /// Runs the model, computing the evaluation order from the cells themselves.
    ///
    /// The convenience the parameter form existed to avoid needing. `DependencyGraph` is
    /// in SwiftExcelCore now, so this package can reach it without a file-format
    /// dependency and without a second topological sort.
    ///
    /// - Parameters:
    ///   - survey: what the recognizer found — the draws and the outputs.
    ///   - cells: the model's cells, able to enumerate themselves.
    ///   - names: the named-range resolver.
    ///   - sheet: the sheet name the addresses belong to.
    ///   - trials: how many times to run the model.
    ///   - seed: the seed for every draw.
    ///   - registry: the functions to evaluate with.
    /// - Returns: a completed run.
    /// - Throws: ``TrialRunError/orderHasACycle(_:)`` if the model is circular, or
    ///   whatever ``run(over:names:)`` throws.
    public static func run(
        survey: ModelSurvey,
        over cells: any CellValueProvider & PopulatedCellProvider,
        names: any NameResolver,
        inSheet sheet: String = "",
        trials: Int,
        seed: UInt64,
        registry: FunctionRegistry = .builtin
    ) throws -> SimulationRun {
        let addresses = cells.populatedCells().map { CellAddress(sheet: sheet, cell: $0) }
        let graph = DependencyGraph(cells: addresses, provider: cells)

        guard graph.isAcyclic else {
            throw TrialRunError.orderHasACycle(graph.cycles.first?.map(\.cell) ?? [])
        }

        return try InterpretedRun(
            survey: survey,
            evaluationOrder: graph.evaluationOrder.map(\.cell),
            trials: trials, seed: seed, registry: registry
        ).run(over: cells, names: names)
    }

    // MARK: - Validating the order

    /// Checks that every formula cell appears, and appears after everything it reads.
    ///
    /// The cost of not doing this is not a crash. A cell evaluated before its precedent
    /// reads whatever the base provider holds — a stale cached value, or nothing — and the
    /// run completes and reports statistics about it.
    private func validateOrder(against cells: any CellValueProvider) throws {
        var position: [CellRef: Int] = [:]
        for (index, ref) in evaluationOrder.enumerated() { position[ref.positionKey] = index }

        for (index, ref) in evaluationOrder.enumerated() {
            guard let ast = cells.value(at: ref)?.formulaAST else { continue }
            let limit = cells.lastPopulatedCell()
            for precedent in Self.referencedCells(in: ast, limit: limit) {
                // A reference to a constant or an empty cell has no position and needs
                // none — only a *computed* precedent has to come first.
                guard cells.value(at: precedent)?.formulaAST != nil else { continue }
                guard let precedentIndex = position[precedent.positionKey] else {
                    throw TrialRunError.orderOmitsCell(precedent)
                }
                guard precedentIndex < index else {
                    throw TrialRunError.orderViolatesDependency(cell: ref, precedent: precedent)
                }
            }
        }
    }

    /// Every cell a formula reads directly.
    ///
    /// Ranges are expanded, because `SUM(A1:A3)` depends on all three.
    ///
    /// **Clipped first, and this matters.** `SUM($A:$A)` is a whole-column reference — the
    /// corpus's most common range notation, and 87,773 `VLOOKUP` calls' worth of it —
    /// which names a million cells. Expanding one to validate an order would cost more
    /// than the simulation it was guarding. `clipped(to:)` cuts it to what the sheet
    /// actually holds, which is the only part that can be a precedent anyway.
    ///
    /// - Parameters:
    ///   - ast: the formula to read.
    ///   - limit: the sheet's last populated cell, to clip open ranges against.
    /// - Returns: the cells it reads.
    static func referencedCells(in ast: FormulaAST, limit: CellRef? = nil) -> Set<CellRef> {
        var found: Set<CellRef> = []
        ast.walk { node in
            switch node {
            case .cellRef(let ref):
                found.insert(ref)
            case .cellRange(let range):
                found.formUnion(range.clipped(to: limit)?.cells ?? [])
            default:
                break
            }
        }
        return found
    }
}

extension CellRef {
    /// This reference, with the `$` markers removed from its identity.
    ///
    /// `CellRef` synthesises `Hashable` over all four fields, so `$B$8` and `B8` are
    /// different keys — and they are the same cell. Absoluteness says what happens when a
    /// formula is *copied*; it says nothing about which cell is being read.
    ///
    /// Without this, a trial computing `B8` stores it under `B8`, a formula reading `$B$8`
    /// misses the override, falls through to the base provider, and reads the value Excel
    /// cached before the simulation began. The run completes. It reports statistics about
    /// a model that never propagated. SwiftXLSX hit the same thing — *"an absolute
    /// reference is the same cell"* — and fixed it by normalising its keys.
    ///
    /// Normalising *to* absolute rather than away from it, because `absolute()` exists and
    /// its inverse does not.
    var positionKey: CellRef { absolute() }
}

/// A provider whose cells can be rewritten for the duration of one trial.
///
/// Overrides shadow the base rather than replacing it, so constants and untouched cells
/// still read through and one trial cannot leak into the next.
struct MutableCells: CellValueProvider {
    let base: any CellValueProvider
    var overrides: [CellRef: CellValue] = [:]

    func value(at ref: CellRef) -> CellValue? { overrides[ref.positionKey] ?? base.value(at: ref) }
    func value(at ref: CellRef, inSheet: String) -> CellValue? {
        overrides[ref.positionKey] ?? base.value(at: ref, inSheet: inSheet)
    }
    func values(in range: CellRange) -> [CellValue] {
        range.cells.map { value(at: $0) ?? .blank }
    }
    func values(in range: CellRange, inSheet: String) -> [CellValue] {
        range.cells.map { value(at: $0, inSheet: inSheet) ?? .blank }
    }
    func lastPopulatedCell() -> CellRef? { base.lastPopulatedCell() }
    func lastPopulatedCell(inSheet: String) -> CellRef? { base.lastPopulatedCell(inSheet: inSheet) }
}
