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
    ///
    /// **No longer thrown by ``InterpretedRun/run(over:names:)`` or
    /// ``InterpretedRun/runConcurrently(over:names:overrides:concurrency:onProgress:)``.** A
    /// model with nothing uncertain in it is a model that evaluates to the same answer every
    /// trial, which is well defined and is the first thing a careful caller asks for: *does
    /// this reproduce the numbers the workbook already has?* Refusing it meant the only way to
    /// discover the evaluator disagreed with Excel was to vary an assumption first and then
    /// wonder which of the two had moved the answer.
    ///
    /// Kept in the enum because callers switch over it, and because a caller that wants the
    /// old rule can still ask ``ModelSurvey/isSimulable`` and raise this itself.
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
    case orderViolatesDependency(cell: CellAddress, precedent: CellAddress)

    /// A formula cell the model needs is absent from the evaluation order.
    case orderOmitsCell(CellAddress)

    /// Trials must be at least one.
    case invalidTrialCount(Int)

    /// The model is circular, so no evaluation order exists.
    ///
    /// Carries the first cycle found. A circular reference is the model's defect and Excel
    /// reports it too; this refuses rather than iterating to a fixed point, because a
    /// simulation of a model that disagrees with itself is not a simulation of anything.
    case orderHasACycle([CellAddress])
}

/// A completed simulation.
///
/// Conforms to ``SimulationResultProvider``, so handing it back to the evaluator is what
/// makes `PsiMean(B4)` answer a number instead of `#N/A`. That is the second of the two
/// passes: run the model, then evaluate the sheet with the run supplied.
public struct SimulationRun: Sendable, SimulationResultProvider {

    /// One completed run per output cell.
    ///
    /// Keyed by **sheet and cell**: a model spans tabs, and `B4` on the pricing sheet is not
    /// `B4` on the template.
    public let outputs: [CellAddress: SimulationResults]

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
    public init(outputs: [CellAddress: SimulationResults], trials: Int, seed: UInt64) {
        self.outputs = outputs
        self.trials = trials
        self.seed = seed
    }

    /// The completed run for an output cell, or `nil` if this run did not collect it.
    ///
    /// - Parameter address: the cell a statistic is asking about.
    /// - Returns: its results, or `nil` — which the statistics report as `#N/A`.
    public func results(for address: CellAddress) -> SimulationResults? {
        outputs[address.normalised]
    }

    /// The same, for a statistic that named a cell without naming a sheet.
    ///
    /// An unqualified reference means the sheet the asking formula is on, which the evaluator
    /// supplies. With nothing to go on, this matches an output on any sheet **only when there
    /// is exactly one** — answering with one of several would be picking a sheet at random and
    /// reporting it as a result.
    public func results(for ref: CellRef) -> SimulationResults? {
        if let exact = outputs[CellAddress(sheet: "", cell: ref).normalised] { return exact }
        let matches = outputs.filter { $0.key.cell == ref.absolute() }
        return matches.count == 1 ? matches.first?.value : nil
    }
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

    // `internal` rather than `private`: the concurrent form in `ParallelRun.swift` is the
    // same run by another schedule and needs the same five things. Still not public — a
    // caller configures a run through `init`, not by reading it back.
    let survey: ModelSurvey
    let evaluationOrder: [CellAddress]
    let trials: Int
    let seed: UInt64
    let registry: FunctionRegistry

    /// The sheet an address means when it does not name one.
    ///
    /// A provider that holds one sheet does not know what it is called, so its addresses come
    /// through unnamed and the caller says. Both sides have to agree about that name: the
    /// evaluation order and the survey are built separately, and when only one of them had the
    /// sheet filled in, every output was looked up under a name nothing was ever stored under
    /// and every run came back empty. Resolving both here is what keeps them from drifting.
    let homeSheet: String

    /// - Parameters:
    ///   - survey: what the recognizer found — the draws and the outputs.
    ///   - evaluationOrder: every formula cell, in topological order.
    ///   - trials: how many times to run the model.
    ///   - seed: the seed for every draw. Required, not defaulted: `RandomSource` has no
    ///     default source by construction and a run without a recorded seed cannot be
    ///     reproduced.
    ///   - registry: the functions to evaluate with.
    ///   - homeSheet: the sheet an address means when it does not name one. A provider
    ///     holding a single sheet does not know what it is called, so its survey and its
    ///     evaluation order both arrive unnamed and the caller says which sheet they are;
    ///     both sides are resolved against this, which is what stops them disagreeing. A
    ///     provider that names its own sheets never needs it.
    public init(
        survey: ModelSurvey,
        evaluationOrder: [CellAddress],
        trials: Int,
        seed: UInt64,
        registry: FunctionRegistry = .builtin,
        inSheet homeSheet: String = ""
    ) {
        self.survey = survey
        self.evaluationOrder = evaluationOrder
        self.trials = trials
        self.seed = seed
        self.registry = registry
        self.homeSheet = homeSheet
    }

    /// An address with its sheet filled in, ready to key an override or an output by.
    func resolved(_ address: CellAddress) -> CellAddress {
        Self.key(address, home: homeSheet)
    }

    /// The same, reachable from a `@Sendable` lane that cannot see `self`.
    ///
    /// **A key, and only a key.** Normalising folds the sheet name to lower case, which is
    /// right for looking an override up and wrong for anything else: hand a folded name back
    /// to a provider and it looks for a sheet called `model` in a workbook that has one called
    /// `Model`, finds nothing, and every constant on it reads blank. The original spelling is
    /// what goes to the evaluator and to the provider; the folded one never leaves this map.
    static func key(_ address: CellAddress, home: String) -> CellAddress {
        guard address.sheet.isEmpty else { return address.normalised }
        return CellAddress(sheet: home, cell: address.cell).normalised
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
        guard !survey.outputs.isEmpty else { throw TrialRunError.noOutputsToCollect }
        try validateOrder(against: cells)

        let random = SeededRandomSource(SplitMix64(seed: seed))
        var collected: [CellAddress: [Double]] = [:]
        for output in survey.outputs { collected[resolved(output)] = [] }

        for _ in 0..<trials {
            var trial = MutableCells(base: cells, homeSheet: homeSheet)
            for address in evaluationOrder {
                guard let ast = cells.value(at: address.cell,
                                            inSheet: address.sheet)?.formulaAST else { continue }
                // **Per cell, not per run.** An unqualified reference means the sheet of the
                // formula containing it, so the overlay's idea of "here" has to move with the
                // cell being evaluated. Held constant, every formula on the second sheet read
                // the first sheet's cells and the run reported a model nobody wrote.
                trial.homeSheet = address.sheet.isEmpty ? homeSheet : address.sheet
                let value = try FormulaEvaluator.evaluate(
                    ast, cells: trial, names: names, functions: registry,
                    // **The cell being evaluated, not `nil`.** Implicit intersection is
                    // measured against the formula's own position, and the evaluator says so:
                    // with no calling cell there is nothing to intersect against and the range
                    // stands. Passing `nil` here switched that rule off for the whole of every
                    // simulation, so `VLOOKUP(A1:A3, …)` answered in a run what it would never
                    // answer on its own. `inSheet` beside it is what makes an unqualified
                    // reference in this formula mean this formula's own sheet.
                    at: address, inSheet: address.sheet, random: random)
                trial.overrides[resolved(address)] = value
            }
            for output in survey.outputs {
                // A trial that produced an error contributes nothing rather than a zero.
                // Averaging a `#DIV/0!` as 0 is the plausible-wrong-number this project
                // exists to avoid; a short vector at least says something went wrong.
                if case .number(let n) = trial.overrides[resolved(output)] ?? .blank {
                    collected[resolved(output), default: []].append(n)
                }
            }
        }

        var outputs: [CellAddress: SimulationResults] = [:]
        for (address, values) in collected {
            outputs[address] = SimulationResults(values: values)
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
        // **Whatever sheets the provider holds.** `inSheet` names the one unqualified
        // references mean; a provider spanning tabs reports its own sheet per address and
        // that name is used instead, so a pricing tab feeding a template is one graph.
        let addresses = cells.populatedAddresses().map {
            $0.sheet.isEmpty ? CellAddress(sheet: sheet, cell: $0.cell) : $0
        }
        let graph = DependencyGraph(cells: addresses, provider: cells)

        guard graph.isAcyclic else {
            throw TrialRunError.orderHasACycle(graph.cycles.first ?? [])
        }

        return try InterpretedRun(
            survey: survey,
            evaluationOrder: graph.evaluationOrder,
            trials: trials, seed: seed, registry: registry, inSheet: sheet
        ).run(over: cells, names: names)
    }

    // MARK: - Validating the order

    /// Checks that every formula cell appears, and appears after everything it reads.
    ///
    /// The cost of not doing this is not a crash. A cell evaluated before its precedent
    /// reads whatever the base provider holds — a stale cached value, or nothing — and the
    /// run completes and reports statistics about it.
    private func validateOrder(against cells: any CellValueProvider) throws {
        var position: [CellAddress: Int] = [:]
        for (index, address) in evaluationOrder.enumerated() {
            position[resolved(address)] = index
        }

        for (index, address) in evaluationOrder.enumerated() {
            guard let ast = cells.value(at: address.cell,
                                        inSheet: address.sheet)?.formulaAST else { continue }
            let limit = cells.lastPopulatedCell(inSheet: address.sheet)
            for precedent in Self.referencedCells(in: ast, on: address.sheet, limit: limit) {
                // A reference to a constant or an empty cell has no position and needs
                // none — only a *computed* precedent has to come first.
                guard cells.value(at: precedent.cell,
                                  inSheet: precedent.sheet)?.formulaAST != nil else { continue }
                guard let precedentIndex = position[resolved(precedent)] else {
                    throw TrialRunError.orderOmitsCell(precedent)
                }
                guard precedentIndex < index else {
                    throw TrialRunError.orderViolatesDependency(
                        cell: address, precedent: precedent)
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
    static func referencedCells(
        in ast: FormulaAST, on sheet: String = "", limit: CellRef? = nil
    ) -> Set<CellAddress> {
        var found: Set<CellAddress> = []
        ast.walk { node in
            switch node {
            case .cellRef(let ref):
                found.insert(CellAddress(sheet: sheet, cell: ref))
            case .cellRange(let range):
                found.formUnion((range.clipped(to: limit)?.cells ?? [])
                    .map { CellAddress(sheet: sheet, cell: $0) })
            // **A reference onto another sheet is a precedent too**, and was simply not
            // looked at — survivable only while a run could not leave its sheet. Unclipped,
            // because `limit` describes the sheet being validated and says nothing about the
            // extent of another one.
            case .sheetRef(let reference):
                found.formUnion(reference.range.cells
                    .map { CellAddress(sheet: reference.sheetName, cell: $0) })
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

extension CellAddress {

    /// This address as an override key: the sheet folded, the cell's `$` markers dropped.
    ///
    /// Two normalisations for two reasons. The cell goes through ``CellRef/positionKey``, for
    /// which see the note there. The **sheet** is folded because Excel resolves a sheet name in
    /// a formula without regard to case, so `Data!B2` and `data!B2` are one cell and must be
    /// one key.
    var normalised: CellAddress {
        CellAddress(sheet: sheet.lowercased(), cell: cell.positionKey)
    }
}

/// A provider whose cells can be rewritten for the duration of one trial.
///
/// Overrides shadow the base rather than replacing it, so constants and untouched cells
/// still read through and one trial cannot leak into the next.
///
/// **Keyed by sheet as well as cell.** They were keyed by position alone, which was
/// survivable only for as long as a run could not leave its sheet: the moment one can, an
/// override computed for `Model!B4` would be handed back to a formula asking for `Data!B4`,
/// and the run would report a model that never existed. The same shape of bug as reading the
/// wrong sheet entirely, one layer further in.
struct MutableCells: CellValueProvider {
    let base: any CellValueProvider
    /// The sheet an unqualified reference means, so overrides written for it are found again.
    var homeSheet: String = ""
    var overrides: [CellAddress: CellValue] = [:]

    /// An override for a cell, if this trial has computed one.
    ///
    /// An empty sheet name means the home sheet, which is how the evaluator asks about an
    /// ordinary reference and how a single-sheet run addresses everything.
    private func override(_ ref: CellRef, _ sheet: String) -> CellValue? {
        overrides[CellAddress(sheet: sheet.isEmpty ? homeSheet : sheet, cell: ref).normalised]
    }

    /// An unqualified reference, which means the sheet of the formula asking.
    ///
    /// **The base is asked with that sheet too**, not with nothing. `value(at:)` cannot say
    /// which sheet it means, so a provider holding a workbook has to guess — and a guess of
    /// "the first sheet" answers a constant on the template with a cell from the pricing tab.
    /// Everything the overlay does not hold still has to come from the right sheet.
    func value(at ref: CellRef) -> CellValue? {
        override(ref, homeSheet) ?? base.value(at: ref, inSheet: homeSheet)
    }
    func value(at ref: CellRef, inSheet: String) -> CellValue? {
        override(ref, inSheet) ?? base.value(at: ref, inSheet: inSheet)
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
