import Foundation
import SwiftExcelCore
import BusinessMath

/// A change to one distribution's parameters, applied without touching the workbook.
///
/// ## Why an override rather than a formula rewrite
///
/// A user interface that lets someone edit σ has two ways to apply it: rewrite the cell's
/// formula text, or substitute the value at run time. The first is the obvious one and it is
/// **unsafe**, because a distribution call carries more than its parameters:
///
/// ```
/// PsiNormal(47.5, 6.25, PsiTruncate(35, 60), PsiName("Price"))
/// ```
///
/// ``DistributionCall`` reports `unhandledProperties` as a list of *names* — enough to know a
/// `PsiTruncate` was there, not enough to put it back. Rebuilding the call from what the
/// recognizer kept would drop it, and the recognizer's own note says what that costs: the
/// distribution "would still compute — returning a number that is wrong in a way nothing
/// reports."
///
/// So an override edits the **existing tree**: it finds the *n*th positional argument and
/// replaces that node. Every property stays exactly where it was, because nothing else is
/// touched. The workbook on disk is never modified at all.
public struct DistributionOverride: Sendable, Equatable {

    /// The cell whose distribution is being changed.
    public let cell: CellRef

    /// Which positional parameter, counting from zero and **ignoring properties**.
    ///
    /// The same index ``DistributionCall/parameters`` uses, so a table showing
    /// `PSINORMAL(47.5, 6.25)` can offer row 0 and row 1 and mean the mean and the σ.
    public let parameter: Int

    /// What to put there.
    public let value: Double

    /// Records a change to one positional parameter.
    ///
    /// - Parameters:
    ///   - cell: The cell whose distribution is being changed.
    ///   - parameter: Which positional parameter, counting from zero, properties ignored.
    ///   - value: What to put there.
    public init(cell: CellRef, parameter: Int, value: Double) {
        self.cell = cell
        self.parameter = parameter
        self.value = value
    }
}

extension DistributionOverride {

    /// Applies overrides to one cell's formula, editing the tree in place.
    ///
    /// - Parameters:
    ///   - ast: The cell's formula.
    ///   - overrides: The changes for this cell, by parameter index.
    /// - Returns: The formula with those positional arguments replaced.
    static func applied(to ast: FormulaAST, overrides: [Int: Double]) -> FormulaAST {
        guard !overrides.isEmpty else { return ast }
        switch ast {
        case .function(let name, let arguments):
            guard FunctionRegistry.canonical(name).hasPrefix("PSI") else {
                return .function(name, arguments.map { applied(to: $0, overrides: overrides) })
            }
            var positional = 0
            var replaced: [FormulaAST] = []
            for argument in arguments {
                // A `PSI*`-headed argument is a *property* — `PsiTruncate`, `PsiName` — and
                // never counts towards the positional index. Counting one would shift every
                // parameter after it.
                if case .function(let inner, _) = argument,
                   FunctionRegistry.canonical(inner).hasPrefix("PSI") {
                    replaced.append(argument)
                    continue
                }
                if let value = overrides[positional] {
                    replaced.append(.number(value))
                } else {
                    replaced.append(argument)
                }
                positional += 1
            }
            return .function(name, replaced)
        case .add(let lhs, let rhs):
            return .add(applied(to: lhs, overrides: overrides),
                        applied(to: rhs, overrides: overrides))
        case .subtract(let lhs, let rhs):
            return .subtract(applied(to: lhs, overrides: overrides),
                             applied(to: rhs, overrides: overrides))
        case .multiply(let lhs, let rhs):
            return .multiply(applied(to: lhs, overrides: overrides),
                             applied(to: rhs, overrides: overrides))
        case .divide(let lhs, let rhs):
            return .divide(applied(to: lhs, overrides: overrides),
                           applied(to: rhs, overrides: overrides))
        default:
            return ast
        }
    }
}

/// How far a run has got, and what it looks like so far.
public struct SimulationProgress: Sendable {

    /// Trials finished.
    public let completed: Int

    /// Trials asked for.
    public let total: Int

    /// The fraction done, for a progress bar.
    public var fraction: Double {
        let denominator = Double(total)
        guard denominator > 0 else { return 0 }
        return Double(completed) / denominator
    }

    /// Records how far a run has got.
    ///
    /// - Parameters:
    ///   - completed: Trials finished.
    ///   - total: Trials asked for.
    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }
}

/// Whether an answer has stopped moving, so a caller can stop drawing.
///
/// A trial count is a guess until it is checked. This turns it into a measurement: the
/// half-width of the 95% confidence interval on the mean, in the units of the answer and as a
/// fraction of it. When that fraction is small enough for the decision, more trials buy
/// nothing — and on the Superchem model the hurdle probability reads 51.9%, 51.8% and 51.7% at
/// one, twenty and two hundred thousand trials, so the honest answer there is that a thousand
/// was already enough.
public struct Convergence: Sendable {

    /// The mean, as it stands.
    public let mean: Double

    /// Half the width of the 95% interval around it.
    public let halfWidth: Double

    /// That half-width as a fraction of the mean's magnitude, or `nil` where the mean is zero
    /// and a relative figure would divide by it.
    public var relative: Double? {
        let magnitude = Swift.abs(mean)
        guard magnitude > 0 else { return nil }
        return halfWidth / magnitude
    }

    /// Whether the interval is inside `tolerance`, relative to the mean.
    public func hasSettled(within tolerance: Double) -> Bool {
        guard let relative else { return false }
        return relative <= tolerance
    }

    /// The trials this was measured over.
    public let trials: Int

    /// Reads the precision of the mean off a completed set of trials.
    ///
    /// **The standard error, computed here rather than borrowed.** The first version of this
    /// asked `SimulationResults.confidenceInterval(level: 0.95)`, which reports the spread of
    /// the *distribution* and not the precision of its mean — so it grew from 1.51 to 7.86
    /// going from 500 trials to 50,000, converging on ±1.96σ as it should and answering a
    /// different question than the one asked.
    ///
    /// `1.96 · σ / √n` is the interval on the mean, it shrinks as `1/√n`, and it is short
    /// enough to be obviously right, which matters more here than reuse: this number is what
    /// tells somebody they can stop drawing.
    public init(_ results: SimulationResults) {
        let values = results.values
        trials = values.count
        mean = results.statistics.mean
        guard values.count > 1 else {
            halfWidth = .infinity
            return
        }
        let root = Double(values.count).squareRoot()
        guard root > 0 else {
            halfWidth = .infinity
            return
        }
        halfWidth = 1.96 * results.statistics.stdDev / root
    }
}

extension InterpretedRun {

    /// Runs the model concurrently, reporting progress and honouring cancellation.
    ///
    /// ## Why this exists beside the synchronous form
    ///
    /// ``run(over:names:)`` returns when every trial is done and cannot be interrupted. That
    /// is fine for a test and wrong for anything with a window: measured on a 56-cell model,
    /// 200,000 trials take about eighteen seconds on one core, and a real model is larger
    /// than that one. A caller with a progress bar needs three things the synchronous form
    /// cannot give — to not block, to say how far along it is, and to stop.
    ///
    /// **`async` alone would supply none of the speed.** What supplies the speed is that
    /// trials are independent: nothing in trial 400 depends on trial 399, so they fan out
    /// across cores with no coordination beyond collecting the results.
    ///
    /// ## Reproducibility does not depend on the machine
    ///
    /// Each trial derives its own generator from the run's seed and its own index, so trial
    /// 4,001 draws the same numbers whether it ran on core 1 of 1 or core 7 of 10. That is a
    /// **stronger** guarantee than the sequential form's single shared stream, which ties the
    /// answer to the order trials happen to execute in — and it is the reason the two forms
    /// give different numbers for the same seed. `SplitMix64` is designed as a seeder, which
    /// is exactly the job it is doing here.
    ///
    /// - Parameters:
    ///   - cells: The model's cells.
    ///   - names: The named-range resolver.
    ///   - overrides: Parameter changes to apply without touching the workbook.
    ///   - concurrency: How many trials to run at once. Defaults to the active core count.
    ///   - onProgress: Called as batches finish, on an unspecified thread.
    /// - Returns: A completed run.
    /// - Throws: ``TrialRunError``, `CancellationError` if the task is cancelled, or whatever
    ///   evaluating a formula throws.
    public func runConcurrently(
        over cells: any CellValueProvider,
        names: any NameResolver,
        overrides: [DistributionOverride] = [],
        concurrency: Int? = nil,
        onProgress: (@Sendable (SimulationProgress) -> Void)? = nil
    ) async throws -> SimulationRun {
        guard trials > 0 else { throw TrialRunError.invalidTrialCount(trials) }
        guard survey.isSimulable else { throw TrialRunError.notSimulable }
        guard !survey.outputs.isEmpty else { throw TrialRunError.noOutputsToCollect }

        let formulas = try plan(over: cells, overrides: overrides)
        let outputs = survey.outputs
        let registry = self.registry
        let seed = self.seed
        let total = trials
        let lanes = max(1, concurrency ?? ProcessInfo.processInfo.activeProcessorCount)

        // **More batches than cores, deliberately.** One batch per core would parallelise
        // perfectly and report progress exactly twice — nought, then everything, because the
        // lanes all finish together. Splitting finer lets the awaiting loop count completions
        // as they arrive, which is where the progress figure comes from: no shared counter,
        // no lock, and nothing for a `@Sendable` callback to capture.
        //
        // It also evens out the tail. Ten lanes over an odd trial count leaves one lane
        // holding the remainder while nine sit idle.
        // Fine enough for smooth progress, coarse enough that the per-batch overhead stays
        // negligible. Independent of `lanes` now that `lanes` actually bounds the work.
        let batch = max(1, min(2_000, total / 64))

        var collected: [CellRef: [Double]] = [:]
        for output in outputs { collected[output] = [] }

        try await withThrowingTaskGroup(of: (count: Int, values: [CellRef: [Double]]).self) { group in
            var started = 0
            var done = 0

            /// Adds the next batch, if there is one. Returns whether it added anything.
            func addNext() -> Bool {
                guard started < total else { return false }
                let first = started
                let count = min(batch, total - first)
                started += count
                group.addTask {
                    (count, try Self.lane(
                        first: first, count: count, seed: seed, formulas: formulas,
                        base: cells, names: names, outputs: outputs, registry: registry))
                }
                return true
            }

            // **Bounded at `lanes` tasks in flight**, replacing each as it finishes.
            //
            // Adding every batch up front does not do this: a task group runs as many as the
            // cooperative pool will take, so `concurrency` would change only the batch size
            // and every run would use every core. It did, and the scaling numbers measured
            // against it were meaningless — a parameter that silently does nothing is worse
            // than one that is absent.
            for _ in 0..<lanes where addNext() {}

            while let lane = try await group.next() {
                for (ref, values) in lane.values { collected[ref, default: []] += values }
                done += lane.count
                onProgress?(SimulationProgress(completed: done, total: total))
                _ = addNext()
            }
        }

        var results: [CellRef: SimulationResults] = [:]
        for (ref, values) in collected { results[ref] = SimulationResults(values: values) }
        return SimulationRun(outputs: results, trials: total, seed: seed)
    }

    /// One lane's share of the trials.
    ///
    /// Static and taking everything it needs, so nothing of `self` is captured and each lane
    /// is plainly independent of the others.
    private static func lane(
        first: Int, count: Int, seed: UInt64,
        formulas: [(ref: CellRef, ast: FormulaAST)],
        base: any CellValueProvider, names: any NameResolver,
        outputs: [CellRef], registry: FunctionRegistry
    ) throws -> [CellRef: [Double]] {
        var collected: [CellRef: [Double]] = [:]
        for output in outputs { collected[output] = [] }

        for offset in 0..<count {
            // Checked per trial rather than per lane: a cancelled run should stop in
            // milliseconds, not when the lane it is in happens to finish.
            try Task.checkCancellation()

            let random = SeededRandomSource(SplitMix64(seed: Self.streamSeed(seed, first + offset)))
            var trial = MutableCells(base: base)
            for formula in formulas {
                let value = try FormulaEvaluator.evaluate(
                    formula.ast, cells: trial, names: names, functions: registry,
                    at: nil, inSheet: "", random: random)
                trial.overrides[formula.ref.positionKey] = value
            }
            for output in outputs {
                if case .number(let number) = trial.overrides[output.positionKey] ?? .blank {
                    collected[output, default: []].append(number)
                }
            }
        }
        return collected
    }

    /// The generator seed for one trial.
    ///
    /// Mixed with the golden-ratio constant rather than added, so adjacent trial indices do
    /// not produce adjacent streams.
    private static func streamSeed(_ seed: UInt64, _ trial: Int) -> UInt64 {
        seed ^ (UInt64(bitPattern: Int64(trial)) &* 0x9E37_79B9_7F4A_7C15)
    }

    /// The formulas to evaluate, in order, with any overrides already applied.
    ///
    /// Resolved **once** for the whole run rather than per trial: the evaluation order and the
    /// parsed trees do not change between trials, and re-deriving them 200,000 times was
    /// simply work nobody asked for.
    private func plan(
        over cells: any CellValueProvider, overrides: [DistributionOverride]
    ) throws -> [(ref: CellRef, ast: FormulaAST)] {
        var byCell: [CellRef: [Int: Double]] = [:]
        for override in overrides {
            byCell[override.cell, default: [:]][override.parameter] = override.value
        }
        var planned: [(ref: CellRef, ast: FormulaAST)] = []
        for ref in evaluationOrder {
            guard let ast = cells.value(at: ref)?.formulaAST else { continue }
            let edits = byCell[ref] ?? byCell[ref.positionKey] ?? [:]
            planned.append((ref, DistributionOverride.applied(to: ast, overrides: edits)))
        }
        return planned
    }
}
