import Foundation
import SwiftExcelCore

/// One distribution call, at the cell that contains it, with its place in the input vector.
public struct UncertainCell: Sendable, Equatable {

    /// The cell whose formula contains this call.
    ///
    /// Not unique across a survey: a formula may hold several draws, and each is its own
    /// ``UncertainCell`` at the same address.
    public let address: CellRef

    /// The distribution call itself, parameters already separated from properties.
    public let call: DistributionCall

    /// This draw's position in the `[Double]` a sampler fills, one per trial.
    public let inputIndex: Int

    /// Creates a located distribution call.
    ///
    /// - Parameters:
    ///   - address: the cell whose formula contains the call.
    ///   - call: the recognised distribution call.
    ///   - inputIndex: its position in the sampler's input vector.
    public init(address: CellRef, call: DistributionCall, inputIndex: Int) {
        self.address = address
        self.call = call
        self.inputIndex = inputIndex
    }
}

/// What a sheet declares about the simulation it describes.
///
/// The result of applying ``PsiRecognizer`` to every formula a provider holds: which draws
/// there are and where they sit in the input vector, which cells report results, and what
/// the recognizer met and could not model.
///
/// Nothing here is evaluated and nothing is ordered. This says what the model *is*, not
/// how to run it — see ``isSimulable`` for the difference between a described model and a
/// runnable one.
public struct ModelSurvey: Sendable, Equatable {

    /// Every distribution call on the sheet, in reading order, with indices assigned.
    public let uncertain: [UncertainCell]

    /// Cells the model collects results for, in reading order.
    ///
    /// Two ways a cell becomes one, because Frontline supports two. A cell carrying
    /// `PsiOutput()` is marked explicitly. A cell some *other* formula asks a statistic
    /// about — `PsiMean(B4)` — is an output by virtue of being asked about, and needs no
    /// marker.
    ///
    /// The marker is not required, and treating it as required rejects real models: one
    /// workbook here carries 126 Psi calls and **no `PsiOutput()` anywhere**, declaring
    /// its outputs entirely through `PsiMean` and `PsiPercentile`.
    public let outputs: [CellRef]

    /// Property functions the recognizer met and does not model, by the cell holding them.
    ///
    /// Empty is the healthy case. A non-empty entry means this survey describes a model
    /// that cannot yet be simulated *faithfully*, which is different from one that cannot
    /// be simulated at all.
    public let unhandledProperties: [CellRef: [String]]

    /// The number of uniforms one trial consumes.
    public var inputCount: Int { uncertain.count }

    /// Whether every property function encountered was one this recognizer models.
    public var isFullyModelled: Bool { unhandledProperties.isEmpty }

    /// Whether there is anything to simulate.
    ///
    /// Draws, and nothing else. A model with no uncertain cell has nothing to vary and a
    /// run of it would compute the same answer ten thousand times.
    ///
    /// **Outputs are deliberately not required.** An earlier version demanded at least one,
    /// and that rejected a real 126-call model outright for carrying no `PsiOutput()`.
    /// Which cells to collect is the caller's decision and can be supplied; whether there
    /// is randomness to propagate is a fact about the model. See ``outputs``.
    ///
    /// This does **not** check that the outputs descend from the draws — that needs the
    /// dependency edges, which this type deliberately does not have.
    public var isSimulable: Bool { !uncertain.isEmpty }

    /// Whether the model says, by itself, what it wants collected.
    ///
    /// `false` is not an error: it means a caller running this model has to name the
    /// outputs, because the workbook never did.
    public var declaresItsOwnOutputs: Bool { !outputs.isEmpty }

    /// Creates a survey.
    ///
    /// - Parameters:
    ///   - uncertain: every distribution call found, with indices assigned.
    ///   - outputs: cells carrying `PsiOutput()`.
    ///   - unhandledProperties: property functions met but not modelled, by cell.
    public init(
        uncertain: [UncertainCell],
        outputs: [CellRef],
        unhandledProperties: [CellRef: [String]]
    ) {
        self.uncertain = uncertain
        self.outputs = outputs
        self.unhandledProperties = unhandledProperties
    }
}

/// A provider that can list what it holds.
///
/// `CellValueProvider` answers *what is at this address?* and cannot be
/// asked *which addresses do you have?*. Without that, a survey has to scan the bounding
/// rectangle implied by `lastPopulatedCell()`, which costs rows × columns lookups however
/// few cells are populated — and real models are sparse and wide.
///
/// Measured on six real Risk Solver workbooks: the rectangle scan took **34.8s**, against
/// **0.8s** for the same traversal driven by an explicit cell list. Adopting this where a
/// provider already knows its keys — as a workbook-backed or dictionary-backed one always
/// does — removes that entirely.
///
/// Optional by design. A provider that does not adopt it still surveys correctly, just
/// slowly, which is the right trade for a protocol this package does not own.
public protocol PopulatedCellProvider {

    /// Every address this provider holds a value for. Order does not matter; the
    /// surveyor sorts into reading order regardless.
    func populatedCells() -> [CellRef]
}

/// Applies ``PsiRecognizer`` across a whole sheet and assigns input indices.
///
/// ```swift
/// import SwiftExcelCore
///
/// func describe(_ cells: any CellValueProvider) {
///     let survey = ModelSurveyor().survey(cells)
///     _ = survey.inputCount     // uniforms one trial consumes
///     _ = survey.isSimulable    // there are draws, and something reports on them
///     _ = survey.isFullyModelled // nothing was met that cannot be modelled
/// }
/// ```
///
/// ## What this does not do
///
/// It does not order anything. A trial loop needs a topological evaluation order, and
/// `SwiftXLSX.DependencyGraph` already computes one — Kahn's algorithm, with cycle
/// detection — but it is built over `Worksheet`, a type this module depends on only in
/// tests. Writing a second topological sort here to avoid that dependency is exactly the
/// duplication the master plan warns about: two orders that could disagree, in a project
/// whose evaluator already relies on the first. So ordering waits for either an upstream
/// `DependencyGraph` initialiser over a `CellValueProvider`, or the separate simulation
/// module the proposal describes. Recognition does not need it, and this is recognition.
public struct ModelSurveyor: Sendable {

    private let recognizer: PsiRecognizer

    /// - Parameter recognizer: the per-formula recognizer to apply. Defaults to one
    ///   reading every distribution the Risk Solver group registers.
    public init(recognizer: PsiRecognizer = PsiRecognizer()) {
        self.recognizer = recognizer
    }

    /// Surveys every formula cell a provider holds.
    ///
    /// - Parameter cells: the sheet to read. Only cells holding a formula are considered;
    ///   a literal carries no simulation role.
    /// - Returns: the draws, the outputs, and anything unmodelled.
    public func survey(_ cells: any CellValueProvider) -> ModelSurvey {
        var uncertain: [UncertainCell] = []
        var outputs: [CellRef] = []
        var unhandled: [CellRef: [String]] = [:]
        var namedByStatistic: Set<CellRef> = []
        var nextIndex = 0

        for ref in Self.populatedRefs(of: cells) {
            guard let ast = cells.value(at: ref)?.formulaAST else { continue }

            let found = recognizer.recognize(ast)
            if found.isOutput { outputs.append(ref) }

            // A cell this formula asks a statistic about is an output, wherever it lives.
            for subject in found.statisticSubjects {
                if case .cellRef(let subjectRef) = subject { namedByStatistic.insert(subjectRef) }
            }

            for call in found.distributions {
                uncertain.append(UncertainCell(address: ref, call: call, inputIndex: nextIndex))
                nextIndex += 1
                if !call.unhandledProperties.isEmpty {
                    unhandled[ref, default: []].append(contentsOf: call.unhandledProperties)
                }
            }
        }

        // Statistic-named cells join the marked ones, deduplicated and in reading order so
        // the list stays stable between runs.
        let marked = Set(outputs)
        let combined = (outputs + namedByStatistic.subtracting(marked)
            .sorted { ($0.row, $0.column) < ($1.row, $1.column) })

        return ModelSurvey(
            uncertain: uncertain, outputs: combined, unhandledProperties: unhandled)
    }

    /// The cells to consider, in reading order — row, then column.
    ///
    /// The order is the contract, not an incidental. Input indices address positions in a
    /// seeded draw sequence, so an assignment that varied between runs would make a
    /// seeded simulation irreproducible across processes — and a provider is usually
    /// dictionary-backed, whose iteration order Swift does not promise to keep stable
    /// between launches. Sorting is what makes the seed mean something.
    ///
    /// Reading order rather than any other stable order, so that the person looking at
    /// the sheet and the person reading the input vector see the same sequence.
    private static func populatedRefs(of cells: any CellValueProvider) -> [CellRef] {
        if let enumerable = cells as? PopulatedCellProvider {
            return enumerable.populatedCells().sorted { ($0.row, $0.column) < ($1.row, $1.column) }
        }

        // The fallback, and it is genuinely expensive: rows × columns lookups regardless
        // of how few cells are populated. See ``PopulatedCellProvider``.
        guard let last = cells.lastPopulatedCell() else { return [] }

        var refs: [CellRef] = []
        for row in 1...max(last.row, 1) {
            for column in 1...max(last.column, 1) {
                let ref = CellRef(column: column, row: row)
                if cells.value(at: ref) != nil { refs.append(ref) }
            }
        }
        return refs
    }
}
