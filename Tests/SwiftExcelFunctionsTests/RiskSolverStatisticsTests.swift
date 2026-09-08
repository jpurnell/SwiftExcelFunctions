import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import BusinessMath
import SwiftXLSX

/// The read-out surface — `PsiMean(B4)` and friends.
///
/// These are 70 of the 314 Psi calls in six real workbooks, about a fifth of everything
/// the family is used for, so the seam they need is load-bearing rather than speculative.
///
/// ## Why they need a seam at all
///
/// `PsiMean(B4)` cannot be a function of `B4`'s value. `B4` has ten thousand values — it
/// names a vector across trials, and Excel's calculation model has no way to hand a
/// function that vector. So the statistics read a *completed run*, supplied to the
/// evaluator the same way cell values already are.
final class RiskSolverStatisticsTests: XCTestCase {

    private struct NoCells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    /// A completed run for one cell, with values a test can reason about exactly.
    private struct FakeRun: SimulationResultProvider {
        let cell: CellRef
        let values: [Double]

        func results(for ref: CellRef) -> SimulationResults? {
            guard ref == cell else { return nil }
            return SimulationResults(values: values)
        }
    }

    /// 1…100, so mean is 50.5 and the percentiles are arithmetic rather than approximate.
    private static let oneToHundred = (1...100).map(Double.init)

    private func evaluate(
        _ formula: String,
        run: (any SimulationResultProvider)? = nil
    ) throws -> CellValue {
        let ast = try FormulaParser.parse(formula)
        return try FormulaEvaluator.evaluate(
            ast, cells: NoCells(), names: NoNames(), simulation: run)
    }

    private func run() -> FakeRun {
        FakeRun(cell: CellRef("B4"), values: Self.oneToHundred)
    }

    // MARK: - Without a run

    /// Risk Solver shows `#N/A` for a statistic before a simulation has been run, and so
    /// does this. Answering zero, or the base case, would be a number a reader could
    /// mistake for a result.
    func testStatisticWithoutARunIsNotAvailable() throws {
        XCTAssertEqual(try evaluate("PsiMean(B4)"), .error(.na))
        XCTAssertEqual(try evaluate("PsiStdDev(B4)"), .error(.na))
    }

    /// A run that does not cover the requested cell is the same as no run for that cell.
    func testStatisticForACellTheRunDoesNotCoverIsNotAvailable() throws {
        XCTAssertEqual(try evaluate("PsiMean(C9)", run: run()), .error(.na))
    }

    // MARK: - With a run

    func testMeanReadsTheCompletedRun() throws {
        XCTAssertEqual(try evaluate("PsiMean(B4)", run: run()), .number(50.5))
    }

    func testStandardDeviationReadsTheCompletedRun() throws {
        guard case .number(let sd) = try evaluate("PsiStdDev(B4)", run: run()) else {
            return XCTFail("expected a number")
        }
        // Sample standard deviation of 1…100.
        XCTAssertEqual(sd, 29.0114, accuracy: 0.001)
    }

    /// `PsiPercentile(cell, p)` takes its probability as a fraction, as Frontline
    /// documents — `0.95`, not `95`.
    func testPercentileTakesAFraction() throws {
        guard case .number(let p50) = try evaluate("PsiPercentile(B4, 0.5)", run: run()) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(p50, 50.5, accuracy: 1.0)
    }

    /// A probability outside `[0, 1]` is `#NUM!`, which is Excel's answer for a
    /// computation with no result — not a clamp to the nearest end.
    func testPercentileOutsideZeroToOneIsNum() throws {
        XCTAssertEqual(try evaluate("PsiPercentile(B4, 1.5)", run: run()), .error(.num))
        XCTAssertEqual(try evaluate("PsiPercentile(B4, -0.1)", run: run()), .error(.num))
    }

    // MARK: - Cumulative probability

    /// A Bernoulli-shaped run: 30 zeros and 70 ones.
    private func bernoulliRun() -> FakeRun {
        FakeRun(cell: CellRef("B4"),
                values: Array(repeating: 0.0, count: 30) + Array(repeating: 1.0, count: 70))
    }

    /// `PsiTarget(cell, x)` is **cumulative** — the proportion of trials at or below `x`.
    ///
    /// Frontline: *"the proportion of simulated values for cell that are less than or
    /// equal to target value."* The coverage matrix recorded `probabilityAbove`, the
    /// complement, which would have returned a number in [0,1] that is plausible, wrong,
    /// and reported by nothing.
    func testTargetIsCumulative() throws {
        guard case .number(let p) = try evaluate("PsiTarget(B4, 50)", run: run()) else {
            return XCTFail("expected a number")
        }
        // 1…100: fifty values are ≤ 50.
        XCTAssertEqual(p, 0.50, accuracy: 1e-9)
    }

    /// **Inclusive, and this is where it bites.**
    ///
    /// `SimulationResults.probabilityBelow` counts strictly `<`. On a continuous output
    /// the difference from `≤` is measure-zero and invisible. On a discrete one it is the
    /// entire mass at the boundary — and `PsiBernoulli` is 55 of the 314 Psi calls in the
    /// real workbooks, so the discrete case is the common case, not the edge case.
    ///
    /// 30 zeros and 70 ones: `PsiTarget(B4, 0)` is 0.30 inclusive and 0.00 strict.
    func testTargetIncludesTheBoundaryOnADiscreteOutput() throws {
        guard case .number(let p) = try evaluate("PsiTarget(B4, 0)", run: bernoulliRun()) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(p, 0.30, accuracy: 1e-9,
                       "strict < would answer 0.0 and lose the whole mass at the boundary")
    }

    /// Frontline documents `PsiXtoP` and `PsiTarget` as the same function with the same
    /// arguments. Binding one binds both.
    func testXtoPIsTargetUnderAnotherName() throws {
        XCTAssertEqual(try evaluate("PsiXtoP(B4, 50)", run: run()),
                       try evaluate("PsiTarget(B4, 50)", run: run()))
    }

    // MARK: - Value at Risk

    /// `PsiBVaR(cell, c)` reports losses **positive**, where BusinessMath's
    /// `valueAtRisk(confidenceLevel:)` returns the raw percentile — its own documentation
    /// prints `abs(var)`. The flip belongs at the binding, not in the mathematics, which
    /// is what `master_plan.md` says about every sign convention here.
    ///
    /// Frontline: `PsiBVaR(A1, 0.95)` equals `−PsiPercentile(A1, 0.05)`.
    func testValueAtRiskReportsLossesPositive() throws {
        let losses = FakeRun(cell: CellRef("B4"), values: (-100...(-1)).map(Double.init))
        guard case .number(let atRisk) = try evaluate("PsiBVaR(B4, 0.95)", run: losses) else {
            return XCTFail("expected a number")
        }
        XCTAssertGreaterThan(atRisk, 0, "a loss is reported positive")

        guard case .number(let fifth) = try evaluate("PsiPercentile(B4, 0.05)", run: losses) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(atRisk, -fifth, accuracy: 1.0,
                       "PsiBVaR(cell, 0.95) is the negated 5th percentile")
    }

    /// `PsiCVaR(cell, p)` — the mean of the tail, reported positive.
    ///
    /// Frontline: *"the negative of the mean value … for the trials that lie between
    /// PsiMin(cell) and PsiPercentile(cell, 1-percentile), **inclusive**"*, and *"like
    /// PsiBVaR, PsiCVaR returns a loss as a positive number."*
    ///
    /// **This case exists to prove the tail is selected by value, not by count.**
    ///
    /// One trial at −10 and ninety-nine at 0. The 5th percentile is 0, so Frontline's
    /// tail — everything at or below it — is all one hundred trials, mean −0.1, reported
    /// as 0.1. A count-based tail taking the worst `ceil(100 × 0.05) = 5` would average
    /// `[−10, 0, 0, 0, 0]` to −2 and report 2.
    ///
    /// Twenty times apart, and both are numbers a reader would accept. Discrete outputs
    /// tie at the boundary constantly — `PsiBernoulli` is 55 of the 314 Psi calls in real
    /// workbooks — so this is the common case, not a contrived one.
    func testConditionalValueAtRiskSelectsTheTailByValueNotByCount() throws {
        let run = FakeRun(cell: CellRef("B4"),
                          values: [-10.0] + Array(repeating: 0.0, count: 99))
        guard case .number(let cvar) = try evaluate("PsiCVaR(B4, 0.95)", run: run) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(cvar, 0.1, accuracy: 1e-9,
                       "a count-based tail would answer 2.0 here")
    }

    /// Positive, like `PsiBVaR`, where the underlying mean is negative.
    func testConditionalValueAtRiskReportsLossesPositive() throws {
        let losses = FakeRun(cell: CellRef("B4"), values: (-100...(-1)).map(Double.init))
        guard case .number(let cvar) = try evaluate("PsiCVaR(B4, 0.95)", run: losses) else {
            return XCTFail("expected a number")
        }
        XCTAssertGreaterThan(cvar, 0)
    }

    // MARK: - Shape

    /// The first argument names a cell. A statistic handed a literal has been given the
    /// value rather than the reference, and there is no run to look up.
    func testStatisticRequiresACellReference() throws {
        XCTAssertEqual(try evaluate("PsiMean(42)", run: run()), .error(.value))
    }
}
