import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX
import BusinessMath

/// The last of the run statistics, and the two that need two runs at once.
final class RiskSolverRemainingStatisticsTests: XCTestCase {

    private struct NoCells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
    }
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
    /// Two runs, so the paired statistics have something to pair.
    private struct TwoRuns: SimulationResultProvider {
        let first: [Double]
        let second: [Double]
        func results(for ref: CellRef) -> SimulationResults? {
            switch ref.reference {
            case "B4": return SimulationResults(values: first)
            case "C4": return SimulationResults(values: second)
            default: return nil
            }
        }
    }

    private static let oneToHundred = (1...100).map(Double.init)

    private func evaluate(_ formula: String,
                          first: [Double]? = nil, second: [Double]? = nil) throws -> CellValue {
        try FormulaEvaluator.evaluate(
            try FormulaParser.parse(formula), cells: NoCells(), names: NoNames(),
            simulation: TwoRuns(first: first ?? Self.oneToHundred,
                                second: second ?? Self.oneToHundred))
    }

    private func number(_ formula: String,
                        first: [Double]? = nil, second: [Double]? = nil) throws -> Double {
        let answer = try evaluate(formula, first: first, second: second)
        guard case .number(let d) = answer else {
            XCTFail("\(formula) gave \(answer)"); return .nan
        }
        return d
    }

    // MARK: - Both directions between value and probability

    /// `P` reads from the bottom and `Q` from the top; the pair must be complementary.
    func testThePAndQPairsAreComplements() throws {
        XCTAssertEqual(try number("PsiPtoX(B4, 0.25)"),
                       try number("PsiQtoX(B4, 0.75)"), accuracy: 1e-9)
        XCTAssertEqual(try number("PsiXtoP(B4, 25)") + (try number("PsiXtoQ(B4, 25)")), 1,
                       accuracy: 1e-12)
    }

    /// `PsiQtoX(B4, 0.05)` is the value only five per cent of trials exceed.
    func testTheUpperTailReadsFromTheTop() throws {
        XCTAssertGreaterThan(try number("PsiQtoX(B4, 0.05)"),
                             try number("PsiQtoX(B4, 0.95)"))
    }

    // MARK: - Every trial

    /// `PsiSimData` spills the run as a column.
    func testSimDataIsAColumnOfEveryTrial() throws {
        let answer = try evaluate("PsiSimData(B4)")
        guard case .array(let matrix) = answer else {
            return XCTFail("expected an array, got \(answer)")
        }
        XCTAssertEqual(matrix.rows, 100)
        XCTAssertEqual(matrix.columns, 1)
        XCTAssertEqual(matrix.elements.first, .number(1))
        XCTAssertEqual(matrix.elements.last, .number(100))
    }

    // MARK: - Gain, loss and their ratios

    /// The two ratios are reciprocals of one another.
    func testTheGainAndLossRatiosAreReciprocal() throws {
        let gain = try number("PsiExpGainRatio(B4, 50)")
        let loss = try number("PsiExpLossRatio(B4, 50)")
        XCTAssertEqual(gain * loss, 1, accuracy: 1e-9)
    }

    /// Nothing below the threshold means no ratio at all, rather than an infinity.
    func testARatioWithNoDownside() throws {
        XCTAssertEqual(try evaluate("PsiExpGainRatio(B4, 0)"), .error(.div0))
    }

    /// The margin is signed, and its sign is the message.
    func testTheMarginIsSigned() throws {
        XCTAssertEqual(try number("PsiExpValMargin(B4, 50)"), 0.5, accuracy: 1e-9)
        XCTAssertLessThan(try number("PsiExpValMargin(B4, 80)"), 0)
    }

    // MARK: - Two runs

    /// A run correlated with itself is exactly one.
    func testPerfectCorrelation() throws {
        XCTAssertEqual(try number("PsiCorrelation(B4, C4)"), 1, accuracy: 1e-9)
        XCTAssertEqual(try number("PsiSpearmanRho(B4, C4)"), 1, accuracy: 1e-9)
    }

    /// Reversed, it is exactly minus one.
    func testPerfectAntiCorrelation() throws {
        let reversed = Self.oneToHundred.reversed().map { $0 }
        XCTAssertEqual(try number("PsiCorrelation(B4, C4)", second: reversed), -1,
                       accuracy: 1e-9)
        XCTAssertEqual(try number("PsiSpearmanRho(B4, C4)", second: reversed), -1,
                       accuracy: 1e-9)
    }

    /// **Spearman sees a monotone relationship that Pearson does not.**
    ///
    /// Squaring is monotone but not linear, so the ranks are unchanged and rho stays exactly
    /// one while Pearson falls. That divergence is the reason both statistics exist, and for
    /// simulation outputs joined by a non-linear model it is usually rho that is wanted.
    func testRankCorrelationSeesWhatPearsonMisses() throws {
        let squared = Self.oneToHundred.map { $0 * $0 }
        XCTAssertEqual(try number("PsiSpearmanRho(B4, C4)", second: squared), 1,
                       accuracy: 1e-9)
        XCTAssertLessThan(try number("PsiCorrelation(B4, C4)", second: squared), 1)
    }

    /// **Runs of different lengths are refused, not truncated.**
    ///
    /// Trials are paired by position because trial *n* of each came from the same draw of the
    /// model's inputs. Pairing the first *k* of two different-length runs would correlate two
    /// different experiments and report a number for it.
    func testMismatchedRunsAreRefused() throws {
        XCTAssertEqual(try evaluate("PsiCorrelation(B4, C4)", second: [1, 2, 3]), .error(.na))
    }

    /// Without a run, `#N/A`, as every statistic answers.
    func testWithoutRuns() throws {
        XCTAssertEqual(try FormulaEvaluator.evaluate(
            try FormulaParser.parse("PsiCorrelation(B4, C4)"),
            cells: NoCells(), names: NoNames()), .error(.na))
    }

    // MARK: - The mode

    /// A triangular's mode is where it was told to peak.
    ///
    /// Found through the quantile — a quantile's slope is the reciprocal of the density, so
    /// its flattest point is the density's peak — since these statistics reach a distribution
    /// only through its inverse.
    func testTheModeOfATriangular() throws {
        let sheet = Sheet(formulas: ["B4": try FormulaParser.parse("PsiTriangular(0, 7, 10)")])
        let answer = try FormulaEvaluator.evaluate(
            try FormulaParser.parse("PsiTheoMode(B4)"), cells: sheet, names: NoNames())
        guard case .number(let mode) = answer else { return XCTFail("got \(answer)") }
        XCTAssertEqual(mode, 7, accuracy: 0.1)
    }

    /// A symmetric distribution's mode sits at its centre.
    func testTheModeOfANormal() throws {
        let sheet = Sheet(formulas: ["B4": try FormulaParser.parse("PsiNormal(10, 2)")])
        let answer = try FormulaEvaluator.evaluate(
            try FormulaParser.parse("PsiTheoMode(B4)"), cells: sheet, names: NoNames())
        guard case .number(let mode) = answer else { return XCTFail("got \(answer)") }
        XCTAssertEqual(mode, 10, accuracy: 0.05)
    }
}
