import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX
import BusinessMath

/// The Six Sigma capability metrics.
///
/// ## What is checkable here
///
/// The capability ratios are algebra over a mean and a spread, so a run whose moments are
/// known by hand gives exact expected values: a process centred at 100 with σ = 1 against
/// limits of 95 and 105 has `Cp = 10/6` and `Cpk = 5/3`, and nothing about anybody's
/// documentation changes that.
///
/// The defect rates are the interesting ones, because there are **two of them and they are
/// computed differently on purpose** — the unshifted rate counts trials, the shifted rate
/// assumes a normal that has drifted. For a symmetric output the two nearly agree, which is
/// exactly why a test has to pin which is which.
@Suite struct RiskSolverSixSigmaTests {

    private struct Sheet: CellValueProvider {
        let formulas: [String: FormulaAST]
        func value(at ref: CellRef) -> CellValue? { value(at: ref, inSheet: "") }
        func value(at ref: CellRef, inSheet: String) -> CellValue? {
            formulas[ref.reference].map { .formula($0, cached: nil) }
        }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
        func lastPopulatedCell() -> CellRef? { CellRef("B4") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("B4") }
    }
    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }
    private struct Run: SimulationResultProvider {
        let values: [Double]
        func results(for ref: CellRef) -> SimulationResults? {
            ref == CellRef("B4") ? SimulationResults(values: values) : nil
        }
    }

    /// A run centred on 100: 97…103, mean **exactly** 100.
    ///
    /// Whole numbers, deliberately. The first version of this used `stride(by: 0.1)`, whose
    /// points are not exactly representable — the mean came out at 99.99 and `PsiSigmaK`
    /// reported −0.01 where the test asserted 0. The fixture was wrong, not the metric, and a
    /// centring measure is exactly the place where a hundredth of drift in the *test data*
    /// reads as a defect in the code.
    private static let centred: [Double] = (-3...3).map { 100 + Double($0) }

    private func evaluate(
        _ formula: String, spec: String = "PsiSixSigma(95, 105, 100)",
        values: [Double]? = nil
    ) throws -> CellValue {
        let sheet = Sheet(formulas: ["B4": try FormulaParser.parse("1 + PsiOutput() + \(spec)")])
        return try FormulaEvaluator.evaluate(
            try FormulaParser.parse(formula), cells: sheet, names: NoNames(),
            simulation: Run(values: values ?? Self.centred))
    }

    private func number(_ formula: String, spec: String = "PsiSixSigma(95, 105, 100)",
                        values: [Double]? = nil) throws -> Double {
        let answer = try evaluate(formula, spec: spec, values: values)
        guard case .number(let d) = answer else {
            Issue.record("\(formula) gave \(answer)"); return .nan
        }
        return d
    }

    private func deviation() -> Double {
        SimulationResults(values: Self.centred).statistics.stdDev
    }

    // MARK: - The ratios

    /// `Cp` is the allowed spread over the actual spread, and ignores centring.
    @Test func capability() throws {
        let sigma = deviation()
        #expect(try abs(number("PsiSigmaCp(B4)") - (10 / (6 * sigma))) <= 1e-9)
    }

    /// `Cpk` takes the nearer limit; centred, the two sides agree and it is half of `Cp`… no:
    /// centred, `Cpk` equals `Cp`, which is the identity worth asserting.
    @Test func capabilityIndexEqualsCapabilityWhenCentred() throws {
        #expect(try abs(number("PsiSigmaCpk(B4)") - number("PsiSigmaCp(B4)")) <= 1e-9)
        #expect(try abs(number("PsiSigmaCpkUpper(B4)") - number("PsiSigmaCpkLower(B4)")) <= 1e-9)
    }

    /// **Off centre, `Cp` is unchanged and `Cpk` falls.** The pair's entire purpose.
    @Test func capabilityIgnoresCentringAndTheIndexDoesNot() throws {
        let offset = Self.centred.map { $0 + 2 }   // centred on 102, limits still 95…105
        #expect(try abs(number("PsiSigmaCp(B4)", values: offset) - number("PsiSigmaCp(B4)")) <= 1e-9)
        #expect(try number("PsiSigmaCpk(B4)", values: offset) < number("PsiSigmaCpk(B4)"))
        // And the nearer limit is now the upper one.
        #expect(try number("PsiSigmaCpkUpper(B4)", values: offset) < number("PsiSigmaCpkLower(B4)", values: offset))
    }

    /// `k` is signed, so it says which way the process is off centre.
    @Test func centringIsSigned() throws {
        #expect(try abs(number("PsiSigmaK(B4)") - 0) <= 1e-9)
        #expect(try number("PsiSigmaK(B4)", values: Self.centred.map { $0 + 2 }) > 0)
        #expect(try number("PsiSigmaK(B4)", values: Self.centred.map { $0 - 2 }) < 0)
    }

    /// `Cpm` charges for being off **target**, which is not the same as off centre.
    ///
    /// With the target at the midpoint the two agree; move the target and `Cpm` falls while
    /// `Cp` does not notice.
    @Test func cpmChargesForMissingTheTarget() throws {
        #expect(try abs(number("PsiSigmaCpm(B4)") - number("PsiSigmaCp(B4)")) <= 1e-9)
        let offTarget = try number("PsiSigmaCpm(B4)", spec: "PsiSixSigma(95, 105, 103)")
        #expect(try offTarget < number("PsiSigmaCp(B4)"))
    }

    /// An omitted target is the midpoint, not zero.
    ///
    /// Defaulting to zero would report every centred process as wildly off target, and the
    /// number it produced would be small and plausible rather than obviously wrong.
    @Test func anOmittedTargetIsTheMidpoint() throws {
        #expect(try abs(number("PsiSigmaCpm(B4)", spec: "PsiSixSigma(95, 105)") - number("PsiSigmaCpm(B4)", spec: "PsiSixSigma(95, 105, 100)")) <= 1e-12)
    }

    // MARK: - Z scores

    @Test func zScoresAndTheirMinimum() throws {
        let sigma = deviation()
        #expect(try abs(number("PsiSigmaZUpper(B4)") - (5 / sigma)) <= 1e-9)
        #expect(try abs(number("PsiSigmaZLower(B4)") - (5 / sigma)) <= 1e-9)
        #expect(try abs(number("PsiSigmaZMin(B4)") - (5 / sigma)) <= 1e-9)
        // The sigma level is the short-term figure: Zmin with no 1.5 folded in.
        #expect(try abs(number("PsiSigmaSigmaLevel(B4)") - number("PsiSigmaZMin(B4)")) <= 1e-12)
    }

    // MARK: - Defects, counted and assumed

    /// **The unshifted rate counts trials.** No distributional assumption at all.
    ///
    /// The run spans 97…103 inside limits of 95…105, so nothing is defective and the rate is
    /// exactly zero — which a normal approximation would not have said.
    @Test func theUnshiftedDefectRateIsCounted() throws {
        #expect(try abs(number("PsiSigmaDefectPPM(B4)") - 0) <= 1e-12)
        #expect(try abs(number("PsiSigmaYield(B4)") - 1) <= 1e-12)

        // Widen the run past the limits and exactly a tenth of it is outside.
        let ten = Array(repeating: 100.0, count: 9) + [200.0]
        #expect(try abs(number("PsiSigmaDefectPPM(B4)", values: ten) - 100_000) <= 1e-6)
        #expect(try abs(number("PsiSigmaYield(B4)", values: ten) - 0.9) <= 1e-12)
    }

    /// **The shifted rate assumes a normal that has drifted**, so it is positive where the
    /// counted rate is zero. That divergence is the point, not a discrepancy.
    @Test func theShiftedRateIsNormalTheoryAndDiffers() throws {
        #expect(try abs(number("PsiSigmaDefectPPM(B4)") - 0) <= 1e-12)
        #expect(try number("PsiSigmaDefectShiftPPM(B4)") > 0)
    }

    /// The drift is applied toward each limit in turn, so it hurts one side and helps the
    /// other. Taking it as helping both would report a process as better than either view.
    @Test func theDriftHurtsOneSideAndHelpsTheOther() throws {
        let upper = try number("PsiSigmaProbDefectShiftUpper(B4)")
        let lower = try number("PsiSigmaProbDefectShiftLower(B4)")
        #expect(upper > lower, "a positive drift moves toward the upper limit")
        #expect(try abs(number("PsiSigmaProbDefectShift(B4)") - (upper + lower)) <= 1e-12)
        // And PPM is the same number times a million.
        #expect(try abs(number("PsiSigmaDefectShiftPPMUpper(B4)") - (upper * 1e6)) <= 1e-6)
    }

    /// A larger assumed drift can only make the long-term picture worse.
    @Test func aLargerDriftIsWorse() throws {
        let gentle = try number("PsiSigmaDefectShiftPPM(B4)", spec: "PsiSixSigma(95,105,100,0.5)")
        let harsh = try number("PsiSigmaDefectShiftPPM(B4)", spec: "PsiSixSigma(95,105,100,2.5)")
        #expect(harsh > gentle)
    }

    // MARK: - Bounds, and what is missing

    @Test func theBoundsAreReadBack() throws {
        #expect(try number("PsiSigmaLowerBound(B4)").isEqual(to: 95))
        #expect(try number("PsiSigmaUpperBound(B4)").isEqual(to: 105))
    }

    /// A cell with no `PsiSixSigma` is `#N/A`: the model has not said what the limits are.
    @Test func withoutASpecification() throws {
        let sheet = Sheet(formulas: ["B4": try FormulaParser.parse("1 + PsiOutput()")])
        let answer = try FormulaEvaluator.evaluate(
            try FormulaParser.parse("PsiSigmaCp(B4)"), cells: sheet, names: NoNames(),
            simulation: Run(values: Self.centred))
        #expect(answer == .error(.na))
    }

    /// Without a run at all, `#N/A` as every other statistic answers.
    @Test func withoutARun() throws {
        let sheet = Sheet(formulas: ["B4": try FormulaParser.parse("1 + PsiSixSigma(95, 105)")])
        #expect(try FormulaEvaluator.evaluate(
            try FormulaParser.parse("PsiSigmaCp(B4)"), cells: sheet, names: NoNames()) == .error(.na))
    }

    /// A run with no spread is a constant, and a constant has no capability.
    @Test func aConstantRunIsRefused() throws {
        #expect(try evaluate("PsiSigmaCp(B4)", values: [100, 100, 100]) == .error(.num))
    }
}
