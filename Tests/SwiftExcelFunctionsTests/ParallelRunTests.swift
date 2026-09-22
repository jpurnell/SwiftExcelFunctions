import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// The three things a user interface needs from a run: editable parameters, progress it can
/// show, and a stop button — plus the guarantee that none of it changes the answer.
final class ParallelRunTests: XCTestCase {

    /// A model with one uncertain input and one output.
    private struct Model: CellValueProvider, PopulatedCellProvider {
        var cells: [Int: CellValue] = [:]
        private static func key(_ ref: CellRef) -> Int { ref.row << 15 | ref.column }
        subscript(ref: String) -> CellValue? {
            get { cells[Self.key(CellRef(ref))] }
            set { cells[Self.key(CellRef(ref))] = newValue }
        }
        func value(at ref: CellRef) -> CellValue? { cells[Self.key(ref)] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { cells[Self.key(ref)] }
        func lastPopulatedCell() -> CellRef? { CellRef("B2") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { cells[Self.key($0)] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
        func populatedCells() -> [CellRef] {
            cells.keys.map { CellRef(column: $0 & 0x7FFF, row: $0 >> 15) }
        }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    /// `A1` draws, `A2` doubles it and is collected.
    private func model(_ draw: String = "PsiNormal(10, 2)") throws -> Model {
        var model = Model()
        model["A1"] = .formula(try FormulaParser.parse(draw), cached: nil)
        model["A2"] = .formula(try FormulaParser.parse("A1*2 + PsiOutput()"), cached: nil)
        return model
    }

    private func engine(_ model: Model, trials: Int, seed: UInt64 = 7) -> InterpretedRun {
        let survey = ModelSurveyor().survey(model)
        let graph = DependencyGraph(
            cells: model.populatedCells().map { CellAddress(sheet: "", cell: $0) },
            provider: model)
        return InterpretedRun(survey: survey, evaluationOrder: graph.evaluationOrder.map(\.cell),
                              trials: trials, seed: seed)
    }

    // MARK: - Parameters

    /// Editing σ changes the spread, and does not touch the workbook.
    func testAnOverrideChangesTheDistribution() async throws {
        let model = try model()
        let tight = try await engine(model, trials: 4000)
            .runConcurrently(over: model, names: NoNames())
        let wide = try await engine(model, trials: 4000).runConcurrently(
            over: model, names: NoNames(),
            overrides: [DistributionOverride(cell: CellRef("A1"), parameter: 1, value: 20)])

        let tightSD = try XCTUnwrap(tight.results(for: CellRef("A2"))).statistics.stdDev
        let wideSD = try XCTUnwrap(wide.results(for: CellRef("A2"))).statistics.stdDev
        XCTAssertGreaterThan(wideSD, tightSD * 5, "σ 2 → 20 is ten times the spread")

        // The model is unchanged: the same cells, the same formula text.
        guard case .formula(let ast, _)? = model["A1"] else { return XCTFail("no formula") }
        XCTAssertEqual(FormulaSerializer.serialize(ast), "PSINORMAL(10,2)")
    }

    /// Overriding the mean moves the answer by exactly what was asked.
    func testAnOverrideMovesTheMean() async throws {
        let model = try model()
        let run = try await engine(model, trials: 8000).runConcurrently(
            over: model, names: NoNames(),
            overrides: [DistributionOverride(cell: CellRef("A1"), parameter: 0, value: 100)])
        let mean = try XCTUnwrap(run.results(for: CellRef("A2"))).statistics.mean
        XCTAssertEqual(mean, 200, accuracy: 2, "mean 100, doubled")
    }

    /// **A property is not a parameter**, and overriding index 0 must not land on one.
    ///
    /// `PsiNormal(10, 2, PsiName("x"))` has one property among its arguments. Counting it as
    /// positional would shift every parameter after it, and the distribution would still
    /// compute — which is the failure this whole design is arranged to avoid.
    func testAnOverrideCountsPastProperties() throws {
        let ast = try FormulaParser.parse(#"PsiNormal(PsiName("x"), 10, 2)"#)
        let edited = DistributionOverride.applied(to: ast, overrides: [0: 99])
        let text = FormulaSerializer.serialize(edited)
        XCTAssertTrue(text.contains("99"), "the first *parameter* moved")
        XCTAssertTrue(text.uppercased().contains("PSINAME"), "and the property survived")
        XCTAssertFalse(text.contains("PSINAME(99"), "the property was not overwritten")
    }

    /// An unmodelled property survives an edit, because the tree is edited rather than rebuilt.
    func testAnOverridePreservesAnUnhandledProperty() throws {
        let ast = try FormulaParser.parse("PsiNormal(10, 2, PsiTruncate(5, 15))")
        let edited = DistributionOverride.applied(to: ast, overrides: [1: 3])
        let text = FormulaSerializer.serialize(edited).uppercased()
        XCTAssertTrue(text.contains("PSITRUNCATE(5,15)"),
                      "rebuilding from DistributionCall would have dropped this")
        XCTAssertTrue(text.contains("PSINORMAL(10,3"))
    }

    // MARK: - Progress

    func testProgressReachesTheTotalAndIsIncremental() async throws {
        let model = try model()
        let seen = Reports()
        _ = try await engine(model, trials: 5000).runConcurrently(
            over: model, names: NoNames(), concurrency: 4,
            onProgress: { seen.record($0.completed) })
        let counts = seen.all
        XCTAssertGreaterThan(counts.count, 1, "one report at the end is not progress")
        XCTAssertEqual(counts.last, 5000, "and it finishes at the total")
        XCTAssertEqual(counts, counts.sorted(), "never goes backwards")
    }

    /// Thread-safe collection for a `@Sendable` callback.
    // Justification: the only state is one array and every access to it is inside `lock`.
    private final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int] = []
        func record(_ value: Int) { lock.lock(); counts.append(value); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return counts }
    }

    // MARK: - Cancellation

    func testCancellationStopsTheRun() async throws {
        let model = try model()
        let engine = engine(model, trials: 5_000_000)
        let task = Task { try await engine.runConcurrently(over: model, names: NoNames()) }
        try await Task.sleep(nanoseconds: 40_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled run should not return a result")
        } catch is CancellationError {
            // The expected path.
        }
    }

    // MARK: - The answer does not depend on the schedule

    /// **Same seed, same trials, same answer — whatever the core count.**
    ///
    /// Each trial derives its generator from the seed and its own index, so the result cannot
    /// depend on how the work was divided. A run whose answer moves with the machine it ran
    /// on is not reproducible, and the seed would be decoration.
    func testTheAnswerIsIndependentOfConcurrency() async throws {
        let model = try model()
        var means: [Double] = []
        for lanes in [1, 3, 8] {
            let run = try await engine(model, trials: 3000)
                .runConcurrently(over: model, names: NoNames(), concurrency: lanes)
            means.append(try XCTUnwrap(run.results(for: CellRef("A2"))).statistics.mean)
        }
        XCTAssertEqual(means[0], means[1], accuracy: 1e-12)
        XCTAssertEqual(means[1], means[2], accuracy: 1e-12)
    }

    // MARK: - Convergence

    func testConvergenceNarrowsWithTrials() async throws {
        let model = try model()
        var widths: [Double] = []
        for trials in [500, 50_000] {
            let run = try await engine(model, trials: trials)
                .runConcurrently(over: model, names: NoNames())
            let results = try XCTUnwrap(run.results(for: CellRef("A2")))
            widths.append(Convergence(results).halfWidth)
        }
        XCTAssertLessThan(widths[1], widths[0] / 5, "100× the trials, ~10× the precision")
    }

    func testConvergenceReportsWhenItHasSettled() async throws {
        let model = try model()
        let run = try await engine(model, trials: 40_000)
            .runConcurrently(over: model, names: NoNames())
        let convergence = Convergence(try XCTUnwrap(run.results(for: CellRef("A2"))))
        XCTAssertTrue(convergence.hasSettled(within: 0.02), "±2% of a mean of 20")
        XCTAssertFalse(convergence.hasSettled(within: 1e-9), "and not to nine decimals")
    }
}
