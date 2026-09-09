import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX
import BusinessMath

/// The interpreted trial loop — draw, propagate, collect, repeat.
///
/// `PROPOSAL_model_graph_simulation.md` §3.1 makes this the **correctness baseline**: it
/// handles every formula the registry can evaluate, it is always right, and it is slow.
/// The compiled path, when it exists, handles a subset and must agree with this one
/// bit-for-bit. So this is built first, and on its own it is already a working product.
///
/// ## The order is a parameter, not a computation
///
/// A trial loop needs a topological evaluation order. `SwiftXLSX.DependencyGraph` computes
/// one with cycle detection, but it takes a `Worksheet` — and depending on a file format
/// here would cost this package the one promise it makes. Writing a second topological
/// sort would be worse: two orders that could disagree, in a project whose evaluator
/// already relies on the first.
///
/// So the caller supplies it, which is the same shape as `CellValueProvider` and
/// `RandomSource` — hand it the world, it computes. The order is *validated* on entry
/// rather than trusted, because an order that is wrong produces numbers rather than an
/// error, and numbers are what a simulation is for.
final class InterpretedRunTests: XCTestCase {

    /// A sheet of formulas and constants.
    private struct Sheet: CellValueProvider, PopulatedCellProvider {
        var cells: [CellRef: CellValue] = [:]

        init(formulas: [String: String] = [:], constants: [String: Double] = [:]) throws {
            for (ref, formula) in formulas {
                cells[CellRef(ref)] = .formula(try FormulaParser.parse(formula), cached: nil)
            }
            for (ref, value) in constants {
                cells[CellRef(ref)] = .number(value)
            }
        }

        func populatedCells() -> [CellRef] { Array(cells.keys) }
        func value(at ref: CellRef) -> CellValue? { cells[ref] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { cells[ref] }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
        func lastPopulatedCell() -> CellRef? {
            guard let c = cells.keys.map(\.column).max(),
                  let r = cells.keys.map(\.row).max() else { return nil }
            return CellRef(column: c, row: r)
        }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    /// B1 draws, B2 doubles it, B3 reports. Order B1 → B2 → B3.
    private func simpleModel() throws -> (Sheet, [CellRef]) {
        let sheet = try Sheet(formulas: [
            "B1": "PsiUniform(0, 1)",
            "B2": "B1*2",
            "B3": "B2+PsiOutput()"
        ])
        return (sheet, ["B1", "B2", "B3"].map { CellRef($0) })
    }

    private func run(
        _ sheet: Sheet, _ order: [CellRef], trials: Int = 500, seed: UInt64 = 42
    ) throws -> SimulationRun {
        let survey = ModelSurveyor().survey(sheet)
        return try InterpretedRun(
            survey: survey, evaluationOrder: order, trials: trials, seed: seed
        ).run(over: sheet, names: NoNames())
    }

    // MARK: - Running

    func testCollectsOneValuePerTrialForEachOutput() throws {
        let (sheet, order) = try simpleModel()
        let result = try run(sheet, order, trials: 500)

        let output = try XCTUnwrap(result.results(for: CellRef("B3")))
        XCTAssertEqual(output.values.count, 500)
    }

    /// The draw propagates. `B1` is uniform on [0,1] and `B3` is twice it, so every trial
    /// must land in [0,2] — and the values must actually vary, or the loop is evaluating
    /// once and copying.
    func testTheDrawPropagatesThroughTheModel() throws {
        let (sheet, order) = try simpleModel()
        let output = try XCTUnwrap(try run(sheet, order).results(for: CellRef("B3")))

        XCTAssertTrue(output.values.allSatisfy { $0 >= 0 && $0 <= 2 })
        XCTAssertGreaterThan(Set(output.values).count, 100, "the model is not being re-drawn")
    }

    /// **The property the whole design rests on.** Same seed, same numbers.
    func testTheSameSeedProducesTheSameRun() throws {
        let (sheet, order) = try simpleModel()
        let first = try run(sheet, order, seed: 7)
        let second = try run(sheet, order, seed: 7)

        XCTAssertEqual(first.results(for: CellRef("B3"))?.values,
                       second.results(for: CellRef("B3"))?.values)
    }

    func testADifferentSeedProducesADifferentRun() throws {
        let (sheet, order) = try simpleModel()
        XCTAssertNotEqual(try run(sheet, order, seed: 1).results(for: CellRef("B3"))?.values,
                          try run(sheet, order, seed: 2).results(for: CellRef("B3"))?.values)
    }

    /// Two draws in one trial are independent, not the same number twice.
    func testTwoDrawsInATrialAreIndependent() throws {
        let sheet = try Sheet(formulas: [
            "B1": "PsiUniform(0, 1)",
            "B2": "PsiUniform(0, 1)",
            "B3": "B1-B2+PsiOutput()"
        ])
        let output = try XCTUnwrap(
            try run(sheet, ["B1", "B2", "B3"].map { CellRef($0) }).results(for: CellRef("B3")))

        // Perfectly correlated draws would make every difference exactly zero.
        XCTAssertGreaterThan(output.values.filter { abs($0) > 1e-9 }.count, 400)
    }

    // MARK: - The statistics read the run back

    /// The two passes the proposal describes: run, then evaluate with the run supplied.
    /// This is the whole point — `PsiMean(B3)` answering a number rather than `#N/A`.
    func testStatisticsResolveAgainstACompletedRun() throws {
        let (sheet, order) = try simpleModel()
        let completed = try run(sheet, order, trials: 2000)

        let mean = try FormulaEvaluator.evaluate(
            try FormulaParser.parse("PsiMean(B3)"),
            cells: sheet, names: NoNames(), simulation: completed)

        guard case .number(let m) = mean else { return XCTFail("expected a number") }
        // Uniform(0,1) doubled has mean 1.
        XCTAssertEqual(m, 1.0, accuracy: 0.05)
    }

    // MARK: - Computing the order

    /// The convenience the parameter form existed to avoid needing.
    ///
    /// `DependencyGraph` moved to SwiftExcelCore, so this package reaches it without a
    /// file-format dependency. Same model, same seed, same numbers as the hand-ordered
    /// run — which is the assertion that says the computed order is the right one.
    func testComputingTheOrderGivesTheSameRunAsSupplyingIt() throws {
        let (sheet, order) = try simpleModel()
        let supplied = try run(sheet, order, trials: 300, seed: 5)
        let computed = try InterpretedRun.run(
            survey: ModelSurveyor().survey(sheet), over: sheet, names: NoNames(),
            trials: 300, seed: 5)

        XCTAssertEqual(supplied.results(for: CellRef("B3"))?.values,
                       computed.results(for: CellRef("B3"))?.values)
    }

    /// A circular model has no order, and is refused rather than iterated.
    func testACircularModelIsRefused() throws {
        let sheet = try Sheet(formulas: [
            "B1": "PsiUniform(0, 1)",
            "B2": "B3+1",
            "B3": "B2+B1",
            "B4": "B3+PsiOutput()"
        ])
        XCTAssertThrowsError(
            try InterpretedRun.run(
                survey: ModelSurveyor().survey(sheet), over: sheet, names: NoNames(),
                trials: 10, seed: 1)
        ) { error in
            guard case TrialRunError.orderHasACycle = error else {
                return XCTFail("expected orderHasACycle, got \(error)")
            }
        }
    }

    // MARK: - Refusing a bad order

    /// An order that puts a cell before its own precedent is not an error the loop can
    /// absorb: `B2` would read a stale or empty `B1` and the run would produce numbers
    /// that look like a simulation. Caught on entry instead.
    func testAnOrderThatViolatesDependenciesIsRejected() throws {
        let (sheet, _) = try simpleModel()
        XCTAssertThrowsError(
            try run(sheet, ["B2", "B1", "B3"].map { CellRef($0) })
        ) { error in
            XCTAssertEqual(error as? TrialRunError,
                           .orderViolatesDependency(cell: CellRef("B2"), precedent: CellRef("B1")))
        }
    }

    /// An order that omits a cell the model needs is the same class of failure.
    func testAnOrderMissingAModelCellIsRejected() throws {
        let (sheet, _) = try simpleModel()
        XCTAssertThrowsError(try run(sheet, [CellRef("B1"), CellRef("B3")]))
    }

    /// Nothing to collect is a refusal — but a different one from nothing to vary.
    ///
    /// The model here is perfectly simulable: it has a draw. What it does not have is any
    /// statement of what to collect, and that is the caller's to supply rather than the
    /// model's to fix. `PsiOutput()` is Frontline's convention, not a precondition.
    func testAModelDeclaringNoOutputsSaysSoSpecifically() throws {
        let sheet = try Sheet(formulas: ["B1": "PsiUniform(0, 1)"])
        XCTAssertThrowsError(try run(sheet, [CellRef("B1")])) { error in
            XCTAssertEqual(error as? TrialRunError, .noOutputsToCollect)
        }
    }

    /// And nothing to vary is the other one.
    func testAModelWithNoDrawsIsNotSimulable() throws {
        let sheet = try Sheet(formulas: ["B1": "1+1"], constants: ["A1": 3])
        XCTAssertThrowsError(try run(sheet, [CellRef("B1")])) { error in
            XCTAssertEqual(error as? TrialRunError, .notSimulable)
        }
    }

    func testZeroTrialsIsRejected() throws {
        let (sheet, order) = try simpleModel()
        XCTAssertThrowsError(try run(sheet, order, trials: 0))
    }
}
