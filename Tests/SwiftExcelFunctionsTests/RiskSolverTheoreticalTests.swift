import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// `PsiTheo*` — statistics of the distribution, before any simulation exists.
///
/// ## Why these are checkable when the run statistics are not
///
/// `PsiMean` needed a convention chosen from Frontline's documentation, because a run has no
/// closed form to check against. These do: the mean of `PsiNormal(10, 2)` is 10 whatever
/// anybody's documentation says, the variance is 4, the skewness is 0 and a uniform on
/// `[0, 6]` has mean 3 and variance 3. **The mathematics is the reference**, which is a
/// stronger position than any of the run statistics can be in.
///
/// ## What they are reading
///
/// There is no table mapping `PSINORMAL` to a distribution object. The quantile is read by
/// evaluating the cell's own formula with a random source that returns a chosen `p`, which is
/// the same path the sampler takes — so a distribution the sampler reads one way cannot be
/// read another way here. `testEveryDistributionFamilyIsReachable` is the check on that
/// claim: the `*Alt` percentile-parameterised forms have no closed-form object that a table
/// could have held, and they work anyway.
final class RiskSolverTheoreticalTests: XCTestCase {

    /// A sheet where `B4` holds a formula, given as text.
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

    private func evaluate(_ formula: String, drawing: String) throws -> CellValue {
        let sheet = Sheet(formulas: ["B4": try FormulaParser.parse(drawing)])
        return try FormulaEvaluator.evaluate(
            try FormulaParser.parse(formula), cells: sheet, names: NoNames())
    }

    private func number(_ formula: String, drawing: String) throws -> Double {
        let answer = try evaluate(formula, drawing: drawing)
        guard case .number(let d) = answer else {
            XCTFail("\(formula) over \(drawing) gave \(answer)")
            return .nan
        }
        return d
    }

    // MARK: - Moments against closed forms

    /// `PsiNormal(10, 2)`: mean 10, variance 4, standard deviation 2, skewness 0.
    func testTheNormalsMoments() throws {
        let draw = "PsiNormal(10, 2)"
        XCTAssertEqual(try number("PsiTheoMean(B4)", drawing: draw), 10, accuracy: 1e-6)
        XCTAssertEqual(try number("PsiTheoStdDev(B4)", drawing: draw), 2, accuracy: 1e-3)
        XCTAssertEqual(try number("PsiTheoVariance(B4)", drawing: draw), 4, accuracy: 1e-2)
        XCTAssertEqual(try number("PsiTheoSkewness(B4)", drawing: draw), 0, accuracy: 1e-6)
        XCTAssertEqual(try number("PsiTheoMedian(B4)", drawing: draw), 10, accuracy: 1e-9)
    }

    /// **Kurtosis is not excess kurtosis**: a normal reports 3, matching `PsiKurtosis`.
    ///
    /// The grid understates a tail, so this sits a little under 3 rather than on it — which is
    /// the documented limit of the midpoint rule doing the integrating, not a wrong constant.
    /// Asserted near 3 and nowhere near 0, which is what distinguishes the two conventions.
    func testKurtosisUsesTheNonExcessConvention() throws {
        let value = try number("PsiTheoKurtosis(B4)", drawing: "PsiNormal(10, 2)")
        XCTAssertEqual(value, 3, accuracy: 0.2)
        XCTAssertGreaterThan(value, 2, "0 would mean the excess convention had been used")
    }

    /// A uniform on `[0, 6]`: mean 3, variance 3, and bounds that are exact.
    func testTheUniformsMomentsAndBounds() throws {
        let draw = "PsiUniform(0, 6)"
        XCTAssertEqual(try number("PsiTheoMean(B4)", drawing: draw), 3, accuracy: 1e-9)
        XCTAssertEqual(try number("PsiTheoVariance(B4)", drawing: draw), 3, accuracy: 1e-3)
        // Bounded support, so the extremes are the real ones rather than a far quantile.
        XCTAssertEqual(try number("PsiTheoMin(B4)", drawing: draw), 0, accuracy: 1e-6)
        XCTAssertEqual(try number("PsiTheoMax(B4)", drawing: draw), 6, accuracy: 1e-6)
        XCTAssertEqual(try number("PsiTheoRange(B4)", drawing: draw), 6, accuracy: 1e-6)
    }

    /// A triangular is skewed, and the sign of the skewness says which way.
    func testSkewnessHasTheRightSign() throws {
        // Mode at 1 on [0, 10]: the long tail is to the right.
        XCTAssertGreaterThan(try number("PsiTheoSkewness(B4)",
                                        drawing: "PsiTriangular(0, 1, 10)"), 0)
        // Mode at 9: the long tail is to the left.
        XCTAssertLessThan(try number("PsiTheoSkewness(B4)",
                                     drawing: "PsiTriangular(0, 9, 10)"), 0)
    }

    // MARK: - Percentiles and their mirrors

    /// `PsiTheoPercentile` reads from the bottom, `PsiTheoPercentileD` from the top.
    ///
    /// The pair is the easiest thing here to get backwards, and for a symmetric distribution
    /// a swapped pair is a sign error rather than an obvious failure.
    func testThePercentilePairReadsFromOppositeEnds() throws {
        let draw = "PsiNormal(10, 2)"
        let low = try number("PsiTheoPercentile(B4, 0.05)", drawing: draw)
        let high = try number("PsiTheoPercentileD(B4, 0.05)", drawing: draw)
        XCTAssertLessThan(low, 10)
        XCTAssertGreaterThan(high, 10)
        // Symmetric about the mean, so the two are equidistant.
        XCTAssertEqual(10 - low, high - 10, accuracy: 1e-6)
        XCTAssertEqual(try number("PsiTheoPercentile(B4, 0.5)", drawing: draw), 10,
                       accuracy: 1e-9)
    }

    /// `XtoP` and `XtoQ` are complements, and `PtoX` inverts `XtoP`.
    func testTheProbabilityPairsAreComplements() throws {
        let draw = "PsiUniform(0, 10)"
        XCTAssertEqual(try number("PsiTheoXtoP(B4, 2.5)", drawing: draw), 0.25, accuracy: 1e-6)
        XCTAssertEqual(try number("PsiTheoXtoQ(B4, 2.5)", drawing: draw), 0.75, accuracy: 1e-6)
        XCTAssertEqual(try number("PsiTheoTarget(B4, 2.5)", drawing: draw), 0.25, accuracy: 1e-6)
        XCTAssertEqual(try number("PsiTheoTargetD(B4, 2.5)", drawing: draw), 0.75, accuracy: 1e-6)
        // The round trip, which is what ties the two directions together.
        let x = try number("PsiTheoPtoX(B4, 0.3)", drawing: draw)
        XCTAssertEqual(try number("PsiTheoXtoP(B4, \(x))", drawing: draw), 0.3, accuracy: 1e-6)
    }

    // MARK: - Reaching every family

    /// The claim that there is no table: families with no closed-form object still answer.
    ///
    /// `PsiNormalAlt` is parameterised by percentiles rather than by moments, so nothing a
    /// registry could hold describes it — it is solved for at call time. It works here because
    /// these statistics read the sampler's own path rather than a second description.
    func testEveryDistributionFamilyIsReachable() throws {
        for draw in ["PsiNormal(10, 2)", "PsiUniform(0, 6)", "PsiTriangular(0, 5, 10)",
                     "PsiLogNormal(10, 2)", "PsiExponential(3)",
                     "PsiNormalAlt(0.1, 5, 0.9, 15)"] {
            let mean = try number("PsiTheoMean(B4)", drawing: draw)
            XCTAssertTrue(mean.isFinite, "\(draw) gave \(mean)")
        }
    }

    /// Written in place, with no cell to look up.
    func testTheDistributionMayBeWrittenInPlace() throws {
        XCTAssertEqual(try number("PsiTheoMean(PsiUniform(0, 6))", drawing: "PsiNormal(0,1)"),
                       3, accuracy: 1e-9)
    }

    // MARK: - No subject

    /// A subject that draws nothing is `#VALUE!`, not `#N/A`.
    ///
    /// `#N/A` is what a *run* statistic says before a simulation: the question is well-formed
    /// and the answer is not available yet. A theoretical statistic about a constant is a
    /// different thing — there is no subject, and no simulation would ever supply one.
    func testACellThatDrawsNothingIsRefused() throws {
        XCTAssertEqual(try evaluate("PsiTheoMean(C9)", drawing: "PsiNormal(10, 2)"),
                       .error(.value), "an empty cell draws nothing")
        XCTAssertEqual(try evaluate("PsiTheoMean(42)", drawing: "PsiNormal(10, 2)"),
                       .error(.value), "a number is not a subject")
    }

    /// A probability outside (0, 1) has no quantile.
    func testProbabilitiesOutsideTheOpenIntervalAreRefused() throws {
        for formula in ["PsiTheoPercentile(B4, 0)", "PsiTheoPercentile(B4, 1)",
                        "PsiTheoPercentile(B4, -0.1)", "PsiTheoPercentileD(B4, 1)"] {
            XCTAssertEqual(try evaluate(formula, drawing: "PsiNormal(10, 2)"),
                           .error(.num), formula)
        }
    }
}
