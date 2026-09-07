import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The nine Risk Solver distributions the corpus actually calls.
///
/// These cannot be checked against a cached value. Risk Solver draws samples with
/// no published seed, so a saved workbook records one draw from one run — measured,
/// of 90 corpus cells carrying an explicit `PsiBaseCase(X)`, 71 cache the value at X
/// and 19 cache a draw, with nothing in the file to say which. So the oracle
/// excludes the family and these assert the published contract instead: the support,
/// the quantile at a known probability, and the behaviour when nothing is simulating.
final class BuiltinRiskSolverDistributionTests: XCTestCase {

    private struct Cells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }

    /// Outcomes in column A, weights in column B.
    private struct DiscreteCells: CellValueProvider {
        private static let outcomes: [Double] = [100, 200, 300]
        private static let weights: [Double] = [0.2, 0.3, 0.5]
        func value(at ref: CellRef) -> CellValue? {
            let row = ref.row - 1
            guard row >= 0, row < Self.outcomes.count else { return nil }
            switch ref.column {
            case 1: return .number(Self.outcomes[row])
            case 2: return .number(Self.weights[row])
            default: return nil
            }
        }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { value(at: ref) }
        func lastPopulatedCell() -> CellRef? { CellRef(column: 2, row: 3) }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }

    /// Hands back exactly what a test wants, in order.
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

    private func evaluate(_ ast: FormulaAST, random: RandomSource? = nil) throws -> CellValue {
        try FormulaEvaluator.evaluate(ast, cells: Cells(),
                                      names: NamedRangeCollection(), random: random)
    }

    private func number(_ ast: FormulaAST, random: RandomSource? = nil) throws -> Double {
        guard case .number(let value) = try evaluate(ast, random: random) else {
            XCTFail("expected a number, got \(try evaluate(ast, random: random))")
            return .nan
        }
        return value
    }

    // MARK: - The group

    func testTheNineCorpusDistributionsAreRegistered() {
        let names = Set(BuiltinRiskSolverFunctions.all.map(\.name))
        for expected in ["PSIBERNOULLI", "PSINORMAL", "PSILOGNORMAL", "PSITRIANGULAR",
                         "PSIDISCRETE", "PSIUNIFORM", "PSIBINOMIAL", "PSIINTUNIFORM",
                         "PSIPOISSON"] {
            XCTAssertTrue(names.contains(expected), "\(expected) is not registered")
        }
    }

    /// Excel writes these with the add-in prefix, and the registry resolves through it.
    func testTheAddInPrefixResolves() throws {
        let value = try number(.function("_xll.PsiUniform", [.number(0), .number(10)]),
                              random: FixedSource([0.5]))
        XCTAssertEqual(value, 5, accuracy: 1e-12)
    }

    // MARK: - What a distribution answers when nothing is simulating

    /// **The decision this whole binding turns on.**
    ///
    /// The evaluator evaluates arguments before calling a function, so a distribution
    /// handed `PsiBaseCase(99)` and one handed a literal `99` receive the same thing:
    /// `.number(99)`. Nothing in the *value* says which it was.
    ///
    /// So a property function must be recognised from the unevaluated AST. Written as
    /// an ordinary value function, this call would read 99 as a fourth *parameter* and
    /// be wrong in a way that produces plausible numbers.
    func testABaseCaseIsNotReadAsAParameter() throws {
        let ast = FormulaAST.function("_xll.PsiTriangular", [
            .number(1), .number(2), .number(3),
            .function("_xll.PsiBaseCase", [.number(99)]),
        ])
        // Idle: the base case is what Risk Solver displays.
        XCTAssertEqual(try number(ast), 99, accuracy: 1e-12)

        // Simulating: a draw from the distribution, which cannot be 99 — it is
        // outside the support. If 99 came back here, the base case was read as a
        // parameter and the support was widened by it.
        let sample = try number(ast, random: FixedSource([0.5]))
        XCTAssertGreaterThanOrEqual(sample, 1)
        XCTAssertLessThanOrEqual(sample, 3)
    }

    /// A label is a property too, and must not be read as a parameter either.
    func testANameIsNotReadAsAParameter() throws {
        let ast = FormulaAST.function("_xll.PsiUniform", [
            .number(0), .number(10),
            .function("_xll.PsiName", [.text("Aggressive Launch")]),
        ])
        XCTAssertEqual(try number(ast, random: FixedSource([0.25])), 2.5, accuracy: 1e-12)
    }

    /// No source and no base case is a refusal, which is the same rule `RAND()`
    /// follows: this package supplies no randomness of its own and will not invent
    /// any. Returning a mean unasked would be a number nobody requested, and nothing
    /// downstream could distinguish it from a real one.
    func testWithoutASourceOrABaseCaseItRefuses() throws {
        XCTAssertEqual(try evaluate(.function("_xll.PsiNormal", [.number(0), .number(1)])),
                       .error(.value))
    }

    // MARK: - The support and the quantile

    /// Inverse transform: at p = 0.5 a symmetric distribution is at its mean.
    func testNormalAtTheMedianIsItsMean() throws {
        XCTAssertEqual(try number(.function("PSINORMAL", [.number(7), .number(2)]),
                                  random: FixedSource([0.5])), 7, accuracy: 1e-9)
    }

    /// A uniform draw is linear in the probability, so both ends are reachable.
    func testUniformSpansItsRange() throws {
        let ast = FormulaAST.function("PSIUNIFORM", [.number(10), .number(20)])
        XCTAssertEqual(try number(ast, random: FixedSource([0.0])), 10, accuracy: 1e-12)
        XCTAssertEqual(try number(ast, random: FixedSource([0.5])), 15, accuracy: 1e-12)
    }

    /// `PsiTriangular` is published `(a, c, b)` — positionally `(min, likely, max)`.
    ///
    /// The middle argument is the *mode*, not the maximum, and "correcting" the order
    /// to (min, max, likely) would still produce numbers inside a plausible range.
    /// This asserts the asymmetry: with the mode hard against the lower bound, the
    /// median must sit below the midpoint of the range.
    func testTriangularTakesItsModeInTheMiddlePosition() throws {
        let median = try number(.function("PSITRIANGULAR",
                                          [.number(0), .number(0), .number(10)]),
                                random: FixedSource([0.5]))
        XCTAssertGreaterThanOrEqual(median, 0)
        XCTAssertLessThanOrEqual(median, 10)
        XCTAssertLessThan(median, 5, "mode at the floor must pull the median below the midpoint")
    }

    /// Bernoulli is a two-point distribution, and the degenerate cases pin the
    /// direction: p = 1 is always a success, p = 0 never.
    func testBernoulliAtTheDegenerateProbabilities() throws {
        XCTAssertEqual(try number(.function("PSIBERNOULLI", [.number(1)]),
                                  random: FixedSource([0.5])), 1)
        XCTAssertEqual(try number(.function("PSIBERNOULLI", [.number(0)]),
                                  random: FixedSource([0.5])), 0)
    }

    /// Binomial over n trials is bounded by 0 and n, and n = 0 has no outcome but 0.
    func testBinomialIsBoundedByItsTrialCount() throws {
        XCTAssertEqual(try number(.function("PSIBINOMIAL", [.number(0), .number(0.5)]),
                                  random: FixedSource([0.5])), 0)
        let draw = try number(.function("PSIBINOMIAL", [.number(10), .number(0.5)]),
                              random: FixedSource([0.5]))
        XCTAssertGreaterThanOrEqual(draw, 0)
        XCTAssertLessThanOrEqual(draw, 10)
    }

    /// A discrete distribution returns one of its own values, never an index.
    ///
    /// The trap worth pinning: BusinessMath's `DistributionDiscrete.quantile` returns
    /// an *index* into its value list, and `valueAt(_:)` maps that to the outcome.
    /// Returning the index would produce 0, 1 or 2 here — all plausible-looking
    /// numbers, none of them one of the stated outcomes.
    func testDiscreteReturnsAValueAndNotAnIndex() throws {
        let outcomes = FormulaAST.cellRange(CellRange(from: CellRef(column: 1, row: 1),
                                                      to: CellRef(column: 1, row: 3)))
        let weights = FormulaAST.cellRange(CellRange(from: CellRef(column: 2, row: 1),
                                                     to: CellRef(column: 2, row: 3)))
        let ast = FormulaAST.function("PSIDISCRETE", [outcomes, weights])
        for p in [0.0, 0.5, 0.99] {
            let drawn = try FormulaEvaluator.evaluate(ast, cells: DiscreteCells(),
                                                      names: NamedRangeCollection(),
                                                      random: FixedSource([p]))
            guard case .number(let value) = drawn else {
                return XCTFail("expected a number, got \(drawn)")
            }
            XCTAssertTrue([100.0, 200.0, 300.0].contains(value),
                          "\(value) is not one of the stated outcomes")
        }
    }

    /// Both bounds are reachable, which is what "integer uniform" has to mean.
    func testIntUniformIsInclusiveAtBothEnds() throws {
        let ast = FormulaAST.function("PSIINTUNIFORM", [.number(1), .number(6)])
        XCTAssertEqual(try number(ast, random: FixedSource([0.0])), 1)
        XCTAssertEqual(try number(ast, random: FixedSource([0.999_999_999])), 6)
    }

    /// A Poisson process with no arrivals has no outcome but zero.
    func testPoissonAtZeroIntensity() throws {
        XCTAssertEqual(try number(.function("PSIPOISSON", [.number(0)]),
                                  random: FixedSource([0.5])), 0)
    }

    /// Lognormal is positive on all of its support, whatever the draw.
    func testLogNormalIsPositive() throws {
        for p in [0.01, 0.5, 0.99] {
            XCTAssertGreaterThan(try number(.function("PSILOGNORMAL", [.number(1), .number(0.5)]),
                                            random: FixedSource([p])), 0)
        }
    }

    /// **The parameterisation trap, asserted rather than commented.**
    ///
    /// `PsiLogNormal` takes the *arithmetic* mean and deviation; BusinessMath's
    /// `DistributionLogNormal` takes the parameters of the underlying normal, on the
    /// log scale. Passed straight through, the answer is positive, plausibly sized
    /// and wrong.
    ///
    /// The median of a lognormal is `e^µ`, and with the conversion
    /// `µ = ln(m) − σ²/2`, `σ² = ln(1 + s²/m²)` that is `m / √(1 + s²/m²)`. For
    /// m = 10, s = 2 that is 9.805807. Passing the arithmetic moments through
    /// unconverted would put the median at e^10 — off by four orders of magnitude,
    /// which is the size of mistake this conversion prevents.
    func testLogNormalTakesArithmeticMomentsAndConvertsThem() throws {
        let median = try number(.function("PSILOGNORMAL", [.number(10), .number(2)]),
                                random: FixedSource([0.5]))
        XCTAssertEqual(median, 10 / (1 + 4.0 / 100).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(median, 9.805806, accuracy: 1e-5)
    }

    // MARK: - Determinism and errors

    /// The same seed gives the same workbook twice. Nothing external can be matched,
    /// so this is the only reproducibility that means anything here.
    func testTheSameSeedGivesTheSameDraw() throws {
        let ast = FormulaAST.function("PSINORMAL", [.number(0), .number(1)])
        let first = try number(ast, random: SeededRandomSource(seed: 42))
        let second = try number(ast, random: SeededRandomSource(seed: 42))
        XCTAssertEqual(first, second)
    }

    /// An error argument propagates rather than being absorbed, the same rule the
    /// lookups follow: the answer should name the failure nearest the start.
    func testAnErrorArgumentPropagates() throws {
        XCTAssertEqual(try evaluate(.function("PSINORMAL", [.error(.ref), .number(1)]),
                                    random: FixedSource([0.5])),
                       .error(.ref))
    }

    /// A parameter outside the distribution's support is `#NUM!`, not a trap and not
    /// a silently clamped answer.
    func testAnImpossibleParameterIsNum() throws {
        XCTAssertEqual(try evaluate(.function("PSINORMAL", [.number(0), .number(-1)]),
                                    random: FixedSource([0.5])),
                       .error(.num))
        XCTAssertEqual(try evaluate(.function("PSIBERNOULLI", [.number(1.5)]),
                                    random: FixedSource([0.5])),
                       .error(.num))
    }
}
