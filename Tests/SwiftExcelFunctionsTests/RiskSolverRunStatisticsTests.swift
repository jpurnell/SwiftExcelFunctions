import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX
import BusinessMath

/// The `Psi*` statistics that read a completed run's values.
///
/// ## These are held to arithmetic, not to a reference
///
/// Every other convention in this package was settled by asking Excel. That cannot be done
/// here: `Psi*` comes from Frontline's Analytic Solver add-in, and a workbook containing one
/// opens without it reading `#NAME?`. So the assertions below are **values computed by hand
/// from a run a reader can check in their head** — 1…100, where the mean is 50.5 and every
/// moment is arithmetic — rather than numbers recalled from a document.
///
/// Where a convention was chosen rather than derived, the test says which one and why the
/// alternative is plausible. That is the part a later measurement can contradict.
final class RiskSolverRunStatisticsTests: XCTestCase {

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
    private struct FakeRun: SimulationResultProvider {
        let cell: CellRef
        let values: [Double]
        func results(for ref: CellRef) -> SimulationResults? {
            guard ref == cell else { return nil }
            return SimulationResults(values: values)
        }
    }

    /// 1…100: mean 50.5, min 1, max 100, and every moment closed-form.
    private static let oneToHundred = (1...100).map(Double.init)

    private func evaluate(_ formula: String, values: [Double]? = nil) throws -> CellValue {
        try FormulaEvaluator.evaluate(
            try FormulaParser.parse(formula), cells: NoCells(), names: NoNames(),
            simulation: FakeRun(cell: CellRef("B4"), values: values ?? Self.oneToHundred))
    }

    private func number(_ formula: String, values: [Double]? = nil) throws -> Double {
        let answer = try evaluate(formula, values: values)
        guard case .number(let d) = answer else {
            XCTFail("\(formula) gave \(answer), expected a number")
            return .nan
        }
        return d
    }

    // MARK: - Before a run

    /// Every one of these answers `#N/A` with no simulation, like the seven beside them.
    func testEveryStatisticWithoutARunIsNotAvailable() throws {
        for formula in ["PsiVariance(B4)", "PsiSkewness(B4)", "PsiKurtosis(B4)",
                        "PsiRange(B4)", "PsiCount(B4)", "PsiAbsDev(B4)", "PsiCoeffVar(B4)",
                        "PsiStdErr(B4)", "PsiSemiVar(B4)", "PsiSemiDev(B4)",
                        "PsiSemiVar2(B4, 50)", "PsiSemiDev2(B4, 50)", "PsiData(B4, 1)",
                        "PsiFrequency(B4, 1, 10)", "PsiExpGain(B4, 50)", "PsiExpLoss(B4, 50)"] {
            let answer = try FormulaEvaluator.evaluate(
                try FormulaParser.parse(formula), cells: NoCells(), names: NoNames())
            XCTAssertEqual(answer, .error(.na), formula)
        }
    }

    // MARK: - Moments

    /// The sample variance of 1…100 is `n(n+1)/12 = 841.666…`.
    func testVarianceAndRange() throws {
        XCTAssertEqual(try number("PsiVariance(B4)"), 100 * 101 / 12.0, accuracy: 1e-9)
        XCTAssertEqual(try number("PsiRange(B4)"), 99)
        XCTAssertEqual(try number("PsiCount(B4)"), 100)
    }

    /// A symmetric run has zero skewness, whatever its spread.
    func testSkewnessOfASymmetricRunIsZero() throws {
        XCTAssertEqual(try number("PsiSkewness(B4)"), 0, accuracy: 1e-9)
    }

    /// **`PsiKurtosis` is not excess kurtosis.**
    ///
    /// Frontline reports 3 for a normal; BusinessMath's `kurtosis(_:_:)` reports 0. The two
    /// differ by exactly 3, so an implementation that picked the other convention returns a
    /// number that looks perfectly reasonable. This pins the choice rather than assuming it
    /// is obvious.
    func testKurtosisIsNotExcessKurtosis() throws {
        let excess: Double = kurtosis(Self.oneToHundred, .sample)
        XCTAssertEqual(try number("PsiKurtosis(B4)"), excess + 3, accuracy: 1e-9)
        // A uniform run is platykurtic: excess is negative, so the reported figure is below 3.
        XCTAssertLessThan(try number("PsiKurtosis(B4)"), 3)
    }

    // MARK: - Spread

    /// The mean absolute deviation of 1…100 about 50.5 is exactly 25.
    func testAbsoluteDeviation() throws {
        XCTAssertEqual(try number("PsiAbsDev(B4)"), 25, accuracy: 1e-9)
    }

    func testCoefficientOfVariationAndStandardError() throws {
        let sd = (100 * 101 / 12.0).squareRoot()
        XCTAssertEqual(try number("PsiCoeffVar(B4)"), sd / 50.5, accuracy: 1e-9)
        XCTAssertEqual(try number("PsiStdErr(B4)"), sd / 10, accuracy: 1e-9)
    }

    /// A mean of zero has no coefficient of variation — refused, not an infinity.
    func testCoefficientOfVariationAtAZeroMean() throws {
        XCTAssertEqual(try evaluate("PsiCoeffVar(B4)", values: [-1, 0, 1]), .error(.div0))
    }

    // MARK: - Downside

    /// **Averaged over every trial, not over the shortfalls.**
    ///
    /// For `[0, 0, 0, 10]` below a target of 10, three trials fall short by 10 each. Over all
    /// four trials that is `300/4 = 75`; over the three that fell short it would be 100. The
    /// two answer different questions and differ by the shortfall rate, which is not a
    /// rounding — so the choice is asserted rather than left to be inferred.
    func testSemiVarianceAveragesOverEveryTrial() throws {
        XCTAssertEqual(try number("PsiSemiVar2(B4, 10)", values: [0, 0, 0, 10]), 75,
                       accuracy: 1e-9)
        XCTAssertEqual(try number("PsiSemiDev2(B4, 10)", values: [0, 0, 0, 10]),
                       75.0.squareRoot(), accuracy: 1e-9)
    }

    /// Nothing below the target is zero downside, not an error.
    func testNoShortfallIsZero() throws {
        XCTAssertEqual(try number("PsiSemiVar2(B4, 0)", values: [1, 2, 3]), 0, accuracy: 1e-12)
    }

    /// Without its target, the two-argument form refuses rather than falling back to the mean.
    ///
    /// A silent fallback would answer `PsiSemiVar`'s question under `PsiSemiVar2`'s name.
    func testTheTargetFormRequiresItsTarget() throws {
        XCTAssertEqual(try evaluate("PsiSemiVar2(B4)"), .error(.value))
        XCTAssertEqual(try evaluate("PsiSemiDev2(B4)"), .error(.value))
    }

    /// Below the mean, half of a symmetric run falls short.
    func testSemiVarianceAboutTheMean() throws {
        let full = try number("PsiSemiVar(B4)")
        XCTAssertGreaterThan(full, 0)
        // Symmetric, so the downside carries half the total squared deviation.
        XCTAssertEqual(full, 100 * 101 / 12.0 * 99 / 100 / 2, accuracy: 1)
    }

    // MARK: - Reaching into the run

    /// One-based, and a trial past the end is refused rather than clamped.
    func testTrialsAreOneBasedAndBounded() throws {
        XCTAssertEqual(try number("PsiData(B4, 1)"), 1)
        XCTAssertEqual(try number("PsiData(B4, 100)"), 100)
        XCTAssertEqual(try evaluate("PsiData(B4, 0)"), .error(.num))
        XCTAssertEqual(try evaluate("PsiData(B4, 101)"), .error(.num))
    }

    /// A proportion, not a count — and both ends inclusive.
    func testFrequencyIsAProportion() throws {
        XCTAssertEqual(try number("PsiFrequency(B4, 1, 10)"), 0.10, accuracy: 1e-12)
        XCTAssertEqual(try number("PsiFrequency(B4, 1, 100)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try number("PsiFrequency(B4, 101, 200)"), 0, accuracy: 1e-12)
        XCTAssertEqual(try evaluate("PsiFrequency(B4, 10, 1)"), .error(.num),
                       "a lower bound above the upper is not an empty interval")
    }

    // MARK: - Gain and loss

    /// Averaged over every trial, and a loss is reported as a positive magnitude.
    func testExpectedGainAndLoss() throws {
        // 1…100 against 100: only trial 100 clears it, by 0. Expected gain is 0.
        XCTAssertEqual(try number("PsiExpGain(B4, 100)"), 0, accuracy: 1e-12)
        // Against 0: every trial clears it, by its own value. Mean 50.5.
        XCTAssertEqual(try number("PsiExpGain(B4, 0)"), 50.5, accuracy: 1e-9)
        // Against 101: every trial falls short, by 101 − value. Mean 50.5.
        XCTAssertEqual(try number("PsiExpLoss(B4, 101)"), 50.5, accuracy: 1e-9)
        XCTAssertEqual(try number("PsiExpLoss(B4, 0)"), 0, accuracy: 1e-12)
    }

    /// A loss is a magnitude: positive, never negative.
    func testALossIsPositive() throws {
        XCTAssertGreaterThan(try number("PsiExpLoss(B4, 50)"), 0)
    }
}
