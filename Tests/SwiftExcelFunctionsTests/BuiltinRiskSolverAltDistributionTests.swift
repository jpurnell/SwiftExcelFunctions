import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The `*Alt` distributions, and the rest of what BusinessMath 2.15.0 completed.
///
/// The `*Alt` family is one capability wearing twenty-eight names — given *k*
/// constraints on a *k*-parameter distribution, solve for the parameters — so the
/// assertions here are about the *round trip*: state a distribution's own quantiles
/// as constraints and the fit must recover it. That tests the solve against the
/// distribution itself rather than against a table, and it works for every conformer
/// without a fixture apiece.
final class BuiltinRiskSolverAltDistributionTests: XCTestCase {

    private struct Cells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }

    // Justification: single-threaded test double; the shipped SeededRandomSource is the one that locks.
    private final class FixedSource: RandomSource, @unchecked Sendable {
        private var values: [Double]
        private var index = 0
        init(_ values: [Double]) { self.values = values }
        func nextUniform() -> Double {
            defer { index += 1 }
            return values[index % values.count]
        }
        func nextInteger(below bound: Int) -> Int {
            Swift.min(Int(nextUniform() * Double(bound)), bound - 1)
        }
    }

    private func evaluate(_ name: String, _ args: [FormulaAST],
                          at p: Double) throws -> CellValue {
        try FormulaEvaluator.evaluate(.function(name, args), cells: Cells(),
                                      names: NamedRangeCollection(),
                                      random: FixedSource([p]))
    }

    private func number(_ name: String, _ args: [Double], at p: Double) throws -> Double {
        let result = try evaluate(name, args.map { FormulaAST.number($0) }, at: p)
        guard case .number(let value) = result else {
            XCTFail("\(name) gave \(result)")
            return .nan
        }
        return value
    }

    // MARK: - The group

    func testAllTwentyEightAltDistributionsAreRegistered() {
        XCTAssertEqual(BuiltinRiskSolverAltDistributions.all.count, 28)
        let names = Set(BuiltinRiskSolverFunctions.all.map(\.name))
        for expected in ["PSINORMALALT", "PSIWEIBULLALT", "PSIPARETOALT",
                         "PSIFATIGUELIFEALT", "PSIPERTALT", "PSISTUDENTALT"] {
            XCTAssertTrue(names.contains(expected), "\(expected) missing")
        }
    }

    // MARK: - The round trip, which is the real assertion

    /// State a normal's own quantiles back to it and the fit must return that normal.
    ///
    /// A standard normal has its 5th percentile at −1.6449 and its 95th at +1.6449.
    /// Fed back as constraints, the recovered distribution must put its median at 0
    /// and reproduce those same percentiles.
    func testANormalIsRecoveredFromItsOwnPercentiles() throws {
        let call: [Double] = [0.05, -1.644854, 0.95, 1.644854]
        XCTAssertEqual(try number("PSINORMALALT", call, at: 0.5), 0, accuracy: 1e-4)
        XCTAssertEqual(try number("PSINORMALALT", call, at: 0.05), -1.644854, accuracy: 1e-4)
        XCTAssertEqual(try number("PSINORMALALT", call, at: 0.95), 1.644854, accuracy: 1e-4)
    }

    /// The same distribution, shifted and scaled, to catch a fit that only works
    /// standardised. Mean 100, deviation 15: the 5th percentile is 75.33.
    func testAShiftedNormalIsRecovered() throws {
        let call: [Double] = [0.05, 75.3272, 0.95, 124.6728]
        XCTAssertEqual(try number("PSINORMALALT", call, at: 0.5), 100, accuracy: 1e-3)
    }

    /// A *textual* name states a moment rather than a percentile.
    ///
    /// This is what removes the ambiguity a purely numeric convention would have: a
    /// bare `(0.05, x)` pair cannot say whether it means "the 5th percentile is x" or
    /// "the scale is 0.05". Here `"mean"` is unmistakable.
    func testAMomentCanBeNamedInsteadOfAPercentile() throws {
        let result = try evaluate("PSINORMALALT",
                                  [.text("mean"), .number(50),
                                   .number(0.95), .number(74.67)], at: 0.5)
        guard case .number(let median) = result else {
            return XCTFail("expected a number, got \(result)")
        }
        XCTAssertEqual(median, 50, accuracy: 1e-3, "the median of a normal is its mean")
    }

    /// Both spellings of the deviation reach the same constraint.
    func testTheDeviationIsNamedSeveralWays() throws {
        for label in ["stdev", "sd", "sigma", "standardDeviation"] {
            let result = try evaluate("PSINORMALALT",
                                      [.text("mean"), .number(10),
                                       .text(label), .number(2)], at: 0.5)
            guard case .number(let median) = result else {
                return XCTFail("\(label) gave \(result)")
            }
            XCTAssertEqual(median, 10, accuracy: 1e-6, "label \(label)")
        }
    }

    /// A probability at the closed end of `[0, 1]` is not a constraint a quantile can
    /// satisfy — it is infinite for any unbounded support.
    func testAProbabilityOutsideTheOpenIntervalIsRefused() throws {
        XCTAssertEqual(try evaluate("PSINORMALALT",
                                    [.number(0), .number(1), .number(0.95), .number(2)],
                                    at: 0.5), .error(.value))
    }

    /// An odd number of arguments is a call that cannot be read as pairs at all.
    func testAnOddArgumentCountIsRefused() throws {
        XCTAssertEqual(try evaluate("PSINORMALALT",
                                    [.number(0.05), .number(1), .number(0.95)],
                                    at: 0.5), .error(.value))
    }

    /// Constraints that no parameters can satisfy are `#NUM!`, not a trap.
    ///
    /// The 95th percentile below the 5th describes no distribution.
    func testImpossibleConstraintsAreNum() throws {
        XCTAssertEqual(try evaluate("PSINORMALALT",
                                    [.number(0.05), .number(10), .number(0.95), .number(1)],
                                    at: 0.5), .error(.num))
    }

    /// Every `*Alt` name refuses without a random source, like every other
    /// distribution here.
    func testTheyAllRefuseWithoutASource() throws {
        for function in BuiltinRiskSolverAltDistributions.all {
            let answer = try FormulaEvaluator.evaluate(
                .function(function.name, [.number(0.25), .number(1),
                                          .number(0.75), .number(2)]),
                cells: Cells(), names: NamedRangeCollection(), random: nil)
            XCTAssertEqual(answer, .error(.value), "\(function.name) should refuse")
        }
    }

    // MARK: - The rest of what 2.15.0 completed

    /// `PsiPert(min, likely, max)` — the Beta-PERT, bounded by its own arguments.
    func testPertStaysInsideItsBounds() throws {
        for p in [0.1, 0.5, 0.9] {
            let value = try number("PSIPERT", [10, 20, 40], at: p)
            XCTAssertGreaterThanOrEqual(value, 10)
            XCTAssertLessThanOrEqual(value, 40)
        }
    }

    /// `PsiBetaSubj(min, likely, mean, max)` — the *mean* is third, between the mode
    /// and the maximum, which is not where anyone would guess it.
    func testBetaSubjectiveTakesItsMeanThird() throws {
        let value = try number("PSIBETASUBJ", [0, 3, 4, 10], at: 0.5)
        XCTAssertGreaterThanOrEqual(value, 0)
        XCTAssertLessThanOrEqual(value, 10)
    }

    /// `PsiNormalSkew(a, b, c)` takes **bounds and a skew**, not a mean and a
    /// deviation. With zero skew it is symmetric about the midpoint of its bounds.
    func testNormalSkewTakesBoundsNotMoments() throws {
        let median = try number("PSINORMALSKEW", [-3, 3, 0], at: 0.5)
        XCTAssertEqual(median, 0, accuracy: 0.2,
                       "zero skew is symmetric about the midpoint of the bounds")
    }

    /// The process rows answer a finite number and take their previous state as an
    /// argument, so a single cell evaluation is well defined.
    func testTheProcessRowsStepFromTheStateTheyAreGiven() throws {
        let calls: [(String, [Double])] = [
            ("PSIAR2", [100, 5, 0.5, 0.3, 98, 97]),
            ("PSIMA1", [0, 1, 0.4, 0.2]),
            ("PSIMA2", [0, 1, 0.4, 0.3, 0.2, 0.1]),
            ("PSIARMA11", [0, 1, 0.5, 0.4, 0.5, 0.2]),
            ("PSIARCH1", [0, 0.02, 0.3, 0.01]),
            ("PSIEGARCH11", [0, 0.02, -0.1, 1, 0.1, 0.85, 0.01, 0.02]),
            ("PSIAPARCH11", [0, 0.02, 2, -0.1, 0.1, 0.85, 0.01, 0.02]),
        ]
        for (name, args) in calls {
            for p in [0.2, 0.8] {
                XCTAssertTrue(try number(name, args, at: p).isFinite, "\(name) at p=\(p)")
            }
        }
    }

    /// An AR(1) step with no shock returns to its long-run mean by exactly `phi`.
    ///
    /// At the median draw the standard normal is zero, so the step is deterministic:
    /// `100 + 0.8·(90 − 100) = 92`. That pins both the direction of mean reversion
    /// and which argument is the persistence.
    func testTheDeterministicAROneStep() throws {
        XCTAssertEqual(try number("PSIAR1", [100, 5, 0.8, 90], at: 0.5), 92, accuracy: 1e-9)
    }

    /// `PsiFit(data)` recovers a distribution from a sample, and its median sits
    /// inside the sample's own range.
    func testFitRecoversADistributionFromASample() throws {
        let sample = FormulaAST.cellRange(CellRange(from: CellRef(column: 1, row: 1),
                                                    to: CellRef(column: 1, row: 8)))
        let result = try FormulaEvaluator.evaluate(
            .function("PSIFIT", [sample]), cells: SampleCells(),
            names: NamedRangeCollection(), random: FixedSource([0.5]))
        guard case .number(let median) = result else {
            return XCTFail("PSIFIT gave \(result)")
        }
        XCTAssertGreaterThan(median, 0)
        XCTAssertLessThan(median, 20)
    }

    // MARK: - The metalog fits, and identifying the probability vector

    /// Frontline does not say which of `x_values`/`y_values` is the probability, and
    /// it does not have to: a fitting probability is strictly inside `(0, 1)` and
    /// distinct, which `DistributionMetalog` enforces. Whichever vector satisfies
    /// that definition, is it — in either argument position.
    func testTheProbabilityVectorIsIdentifiedInEitherPosition() {
        let probabilities = [0.1, 0.5, 0.9]
        let values = [12.0, 30.0, 55.0]

        let forward = BuiltinRiskSolverFunctions.probabilityPair(probabilities, values)
        XCTAssertEqual(forward?.probabilities, probabilities)
        XCTAssertEqual(forward?.values, values)

        let reversed = BuiltinRiskSolverFunctions.probabilityPair(values, probabilities)
        XCTAssertEqual(reversed?.probabilities, probabilities,
                       "the same pair, written the other way round")
        XCTAssertEqual(reversed?.values, values)
    }

    /// When **both** vectors could be probabilities the call is genuinely ambiguous —
    /// a market-share or utilisation model does this — and it is refused.
    ///
    /// Refusing beats fitting the transpose: a wrong fit returns a number that looks
    /// entirely reasonable and nothing downstream can question it.
    func testAnAmbiguousMetalogCallIsRefusedRatherThanGuessed() {
        XCTAssertNil(BuiltinRiskSolverFunctions.probabilityPair([0.1, 0.5, 0.9],
                                                                [0.2, 0.4, 0.8]))
    }

    /// Neither vector being a probability is equally unusable.
    func testAMetalogCallWithNoProbabilityVectorIsRefused() {
        XCTAssertNil(BuiltinRiskSolverFunctions.probabilityPair([12, 30, 55],
                                                                [1, 2, 3]))
        // Repeated probabilities are not distinct, so they cannot be the vector.
        XCTAssertNil(BuiltinRiskSolverFunctions.probabilityPair([0.5, 0.5, 0.9],
                                                                [12, 30, 55]))
    }

    /// The fit runs end to end and its quantile is monotone.
    func testTheMetalogFitProducesAMonotoneQuantile() throws {
        let probabilities = FormulaAST.cellRange(CellRange(from: CellRef(column: 1, row: 1),
                                                           to: CellRef(column: 1, row: 3)))
        let values = FormulaAST.cellRange(CellRange(from: CellRef(column: 2, row: 1),
                                                    to: CellRef(column: 2, row: 3)))
        for name in ["PSIMETALOGFIT", "PSIMETALOG2FIT"] {
            var previous = -Double.infinity
            for p in [0.25, 0.5, 0.75] {
                let result = try FormulaEvaluator.evaluate(
                    .function(name, [.number(3), probabilities, values]),
                    cells: MetalogCells(), names: NamedRangeCollection(),
                    random: FixedSource([p]))
                guard case .number(let value) = result else {
                    return XCTFail("\(name) gave \(result)")
                }
                XCTAssertTrue(value.isFinite, "\(name) at p=\(p)")
                XCTAssertGreaterThan(value, previous, "\(name) not monotone")
                previous = value
            }
        }
    }

    /// Probabilities in column A, values in column B.
    private struct MetalogCells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? {
            let row = ref.row - 1
            guard row >= 0, row < 3 else { return nil }
            return ref.column == 1 ? .number([0.1, 0.5, 0.9][row])
                                   : .number([12.0, 30.0, 55.0][row])
        }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { value(at: ref) }
        func lastPopulatedCell() -> CellRef? { CellRef(column: 2, row: 3) }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }

    /// Eight values with a clear centre, for `PsiFit`.
    private struct SampleCells: CellValueProvider {
        static let sample: [Double] = [4, 6, 7, 8, 9, 10, 12, 15]
        func value(at ref: CellRef) -> CellValue? {
            let row = ref.row - 1
            guard ref.column == 1, row >= 0, row < Self.sample.count else { return nil }
            return .number(Self.sample[row])
        }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { value(at: ref) }
        func lastPopulatedCell() -> CellRef? { CellRef(column: 1, row: 8) }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }

    /// The multivariate rows answer a **vector**, which is what Frontline documents:
    /// "returns an array of sample data; to use it, you must array-enter a formula".
    ///
    /// A scalar here would mean the correlation had been discarded — the only reason
    /// these distributions exist.
    func testTheMultivariateRowsAnswerAVector() throws {
        let means = FormulaAST.cellRange(CellRange(from: CellRef(column: 1, row: 1),
                                                   to: CellRef(column: 1, row: 2)))
        let covariance = FormulaAST.cellRange(CellRange(from: CellRef(column: 2, row: 1),
                                                        to: CellRef(column: 3, row: 2)))
        let result = try FormulaEvaluator.evaluate(
            .function("PSIMVNORMAL", [means, covariance]), cells: MVCells(),
            names: NamedRangeCollection(), random: FixedSource([0.3, 0.7, 0.4, 0.6]))
        guard case .array(let matrix) = result else {
            return XCTFail("expected an array, got \(result)")
        }
        XCTAssertEqual(matrix.elements.count, 2, "one value per variable")
        for element in matrix.elements {
            guard case .number(let value) = element else {
                return XCTFail("expected numbers, got \(element)")
            }
            XCTAssertTrue(value.isFinite)
        }
    }

    /// Means in column A, a 2×2 covariance in columns B and C.
    private struct MVCells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? {
            switch (ref.column, ref.row) {
            case (1, 1): return .number(10)
            case (1, 2): return .number(20)
            case (2, 1): return .number(4)
            case (3, 1): return .number(1)
            case (2, 2): return .number(1)
            case (3, 2): return .number(9)
            default: return nil
            }
        }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { value(at: ref) }
        func lastPopulatedCell() -> CellRef? { CellRef(column: 3, row: 2) }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }
}
