import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The distributions beyond the nine the corpus calls.
///
/// The risk here is different from the corpus nine. These are bound from
/// documentation on both sides, so the failure mode is not "does not compile" but
/// "compiles, runs, and answers a plausible number for a different distribution".
/// The parameterisation conversions therefore get exact assertions rather than
/// range checks — a range check would pass with the conversion removed.
final class BuiltinRiskSolverMoreDistributionTests: XCTestCase {

    /// Column A holds 10, 20, 30, 40; column B holds equal weights.
    private struct ListCells: CellValueProvider {
        static let list: [Double] = [10, 20, 30, 40]
        func value(at ref: CellRef) -> CellValue? {
            let row = ref.row - 1
            guard row >= 0, row < Self.list.count else { return nil }
            if ref.column == 3 {
                // Two metalog coefficients: a median term and a spread term.
                return row < 2 ? .number([0.5, 0.2][row]) : nil
            }
            return ref.column == 1 ? .number(Self.list[row]) : .number(0.25)
        }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { value(at: ref) }
        func lastPopulatedCell() -> CellRef? { CellRef(column: 3, row: 4) }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }

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

    private func number(_ name: String, _ args: [FormulaAST], at p: Double) throws -> Double {
        let result = try FormulaEvaluator.evaluate(
            .function(name, args), cells: Cells(),
            names: NamedRangeCollection(), random: FixedSource([p]))
        guard case .number(let value) = result else {
            XCTFail("\(name) gave \(result)")
            return .nan
        }
        return value
    }

    // MARK: - The group

    func testEveryFurtherDistributionIsRegistered() {
        XCTAssertEqual(BuiltinRiskSolverFunctions.furtherDistributions.count, 45)
        let names = Set(BuiltinRiskSolverFunctions.all.map(\.name))
        for expected in ["PSIBETA", "PSIWEIBULL", "PSIGAMMA", "PSIEXPONENTIAL", "PSIPARETO",
                         "PSILOGISTIC", "PSISTUDENT", "PSIHYPERGEO", "PSIMYERSON"] {
            XCTAssertTrue(names.contains(expected), "\(expected) is missing")
        }
    }

    /// One valid call for every distribution bound here.
    ///
    /// Doubles as documentation: these are the argument shapes each one accepts, in
    /// Frontline's order. Anything absent from this table is not bound.
    static let validCalls: [(String, [Double])] = [
        ("PSIBETA", [2, 2]), ("PSIBURR12", [0, 1, 2, 2]), ("PSICAUCHY", [0, 1]),
        ("PSICHISQUARE", [3]), ("PSICUMUL", [0, 10, 5, 0.5]), ("PSIDAGUM", [0, 1, 2, 2]),
        ("PSIDBLTRIANG", [0, 5, 10, 0.5]), ("PSIDISUNIFORM", [7]), ("PSIERLANG", [2, 1]),
        ("PSIEXPONENTIAL", [1]), ("PSIFDIST", [3, 5]), ("PSIFATIGUELIFE", [0, 1, 1]),
        ("PSIFRECHET", [0, 1, 2]), ("PSIGAMMA", [2, 1]), ("PSIGENERAL", [0, 10, 5, 1]),
        ("PSIGEOMETRIC", [0.5]), ("PSIHYPSECANT", [0, 1]), ("PSIHYPERGEO", [5, 20, 50]),
        ("PSIINVNORMAL", [1, 1]), ("PSIJOHNSONSB", [1, 1, 0, 10]),
        ("PSIJOHNSONSU", [1, 1, 0, 1]), ("PSIKUMARASWAMY", [2, 2, 0, 1]),
        ("PSILAPLACE", [0, 1]), ("PSILEVY", [0, 1]), ("PSILOGLOGISTIC", [0, 1, 2]),
        ("PSILOGNORM2", [0, 1]), ("PSILOGARITHMIC", [0.5]), ("PSILOGISTIC", [0, 1]),
        ("PSIMAXEXTREME", [0, 1]), ("PSIMINEXTREME", [0, 1]), ("PSIMYERSON", [0, 5, 10]),
        ("PSINEGBINOMIAL", [5, 0.4]), ("PSIPARETO", [1, 2]), ("PSIPEARSON5", [2, 1]),
        ("PSIPEARSON6", [2, 3, 1]), ("PSIRAYLEIGH", [1]), ("PSIRECIPROCAL", [1, 10]),
        ("PSISTUDENT", [5]), ("PSIWEIBULL", [2, 1]), ("PSIRESAMPLE", [5]),
        ("PSISHUFFLE", [5]), ("PSIMOMENTFIT", [10, 2, 0, 3]),
        ("PSIAR1", [100, 5, 0.8, 90]), ("PSIGARCH11", [0, 0.02, 0.1, 0.85, 0.01, 0.02]),
    ]

    /// The table above covers every distribution bound here, and nothing else.
    ///
    /// `PsiMetalog` is the one exclusion: its coefficients are a *range*, which a
    /// table of scalars cannot express, so it has its own test below.
    func testTheValidCallTableCoversTheWholeGroup() {
        let tabulated = Set(Self.validCalls.map(\.0)).union(["PSIMETALOG"])
        XCTAssertEqual(tabulated,
                       Set(BuiltinRiskSolverFunctions.furtherDistributions.map(\.name)))
    }

    /// `PsiMetalog(min, max, coefficients)` — bounded, and its quantile stays inside
    /// the bounds it was given.
    ///
    /// Frontline documents a fourth argument, `prop_fcns`. That is the general
    /// property-function slot — the one carrying `PsiTruncate`, `PsiBaseCase`,
    /// `PsiName` — not a parameter, and `attached(_:_:)` removes it before the
    /// distribution sees anything.
    func testMetalogStaysInsideItsBounds() throws {
        let coefficients = FormulaAST.cellRange(CellRange(from: CellRef(column: 3, row: 1),
                                                          to: CellRef(column: 3, row: 2)))
        for p in [0.2, 0.5, 0.8] {
            let drawn = try FormulaEvaluator.evaluate(
                .function("PSIMETALOG", [.number(0), .number(100), coefficients]),
                cells: ListCells(), names: NamedRangeCollection(), random: FixedSource([p]))
            guard case .number(let value) = drawn else {
                return XCTFail("PSIMETALOG gave \(drawn)")
            }
            XCTAssertTrue(value.isFinite, "not finite at p=\(p)")
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 100)
        }
    }

    /// Given valid parameters, every one draws a finite number.
    ///
    /// The broadest thing worth asserting across forty-one bindings: that each is
    /// wired to something that answers, rather than trapping, returning `NaN`, or
    /// refusing a call it should accept.
    func testEveryDistributionDrawsAFiniteNumber() throws {
        for (name, args) in Self.validCalls {
            for p in [0.1, 0.5, 0.9] {
                let value = try number(name, args.map { FormulaAST.number($0) }, at: p)
                XCTAssertTrue(value.isFinite, "\(name) at p=\(p) gave \(value)")
            }
        }
    }

    /// Every one refuses without a source, given parameters it accepts.
    ///
    /// Driven through the evaluator rather than `function.evaluate(_:)`, because the
    /// latter takes the context-free fallback and would answer `#VALUE!` whatever the
    /// body did — a test that passes without exercising anything.
    func testTheyAllRefuseWithoutASource() throws {
        for (name, args) in Self.validCalls {
            let answer = try FormulaEvaluator.evaluate(
                .function(name, args.map { FormulaAST.number($0) }), cells: Cells(),
                names: NamedRangeCollection(), random: nil)
            XCTAssertEqual(answer, .error(.value), "\(name) should refuse")
        }
    }

    /// A quantile is non-decreasing in its probability — the contract the whole
    /// inverse-transform approach rests on. A binding that scrambled a parameter
    /// into a shape can break this while still returning finite numbers.
    func testEveryQuantileIsMonotone() throws {
        for (name, args) in Self.validCalls {
            let asts = args.map { FormulaAST.number($0) }
            let low = try number(name, asts, at: 0.2)
            let mid = try number(name, asts, at: 0.5)
            let high = try number(name, asts, at: 0.8)
            XCTAssertLessThanOrEqual(low, mid, "\(name) not monotone at 0.2 -> 0.5")
            XCTAssertLessThanOrEqual(mid, high, "\(name) not monotone at 0.5 -> 0.8")
        }
    }

    // MARK: - The conversions, asserted exactly

    /// **`PsiExponential(beta)` states the mean; BusinessMath takes the rate.**
    ///
    /// The median of an exponential with mean β is `β·ln 2`. For β = 100 that is
    /// 69.31. Without the inversion the answer would be 0.00693 — right sign, right
    /// shape, wrong by four orders of magnitude.
    func testExponentialTakesTheMeanAndInvertsIt() throws {
        let median = try number("PSIEXPONENTIAL", [.number(100)], at: 0.5)
        XCTAssertEqual(median, 100 * Foundation.log(2.0), accuracy: 1e-6)
        XCTAssertGreaterThan(median, 1, "an un-inverted rate would give ~0.007")
    }

    /// **`PsiLogistic(mu, s)` states the scale; BusinessMath takes the deviation.**
    ///
    /// A logistic's standard deviation is `s·π/√3`. At p = 0.75 the quantile is
    /// `mu + s·ln 3`, so with mu = 0 and s = 2 the answer is 2·ln 3 = 2.1972.
    /// Passing the scale through unconverted narrows it by a factor of 1.814.
    func testLogisticTakesTheScaleAndConvertsIt() throws {
        let upperQuartile = try number("PSILOGISTIC", [.number(0), .number(2)], at: 0.75)
        XCTAssertEqual(upperQuartile, 2 * Foundation.log(3.0), accuracy: 1e-6)
    }

    /// **`PsiGamma` has a real shape, so it cannot use `DistributionGamma`.**
    ///
    /// That type takes `r: Int` and builds the draw as a sum of `r` exponentials.
    /// Rounding 2.5 to 2 answers a different distribution; this asserts the
    /// half-integer shape is honoured by checking it sits strictly between the two
    /// integer neighbours.
    func testGammaHonoursARealShape() throws {
        let atTwo = try number("PSIGAMMA", [.number(2), .number(1)], at: 0.5)
        let atHalf = try number("PSIGAMMA", [.number(2.5), .number(1)], at: 0.5)
        let atThree = try number("PSIGAMMA", [.number(3), .number(1)], at: 0.5)
        XCTAssertGreaterThan(atHalf, atTwo)
        XCTAssertLessThan(atHalf, atThree)
    }

    /// `PsiLogNorm2` takes the log-scale parameters directly — the counterpart to
    /// `PsiLogNormal`, which takes the arithmetic ones and converts. Binding both
    /// the same way would make one of them wrong; the median here is `e^mu`.
    func testLogNorm2TakesLogScaleParametersUnconverted() throws {
        let median = try number("PSILOGNORM2", [.number(1), .number(0.5)], at: 0.5)
        XCTAssertEqual(median, Foundation.exp(1.0), accuracy: 1e-6)
    }

    // MARK: - Supports and shapes

    /// Beta lives on [0, 1] and is symmetric when its shapes are equal.
    func testBetaIsBoundedAndSymmetric() throws {
        let median = try number("PSIBETA", [.number(2), .number(2)], at: 0.5)
        XCTAssertEqual(median, 0.5, accuracy: 1e-6)
    }

    /// Weibull with shape 1 is exponential, whose median is `scale·ln 2`.
    func testWeibullAtShapeOneIsExponential() throws {
        let median = try number("PSIWEIBULL", [.number(1), .number(10)], at: 0.5)
        XCTAssertEqual(median, 10 * Foundation.log(2.0), accuracy: 1e-6)
    }

    /// Pareto's median is `scale · 2^(1/shape)`, straight from its documentation.
    func testParetoTakesScaleThenShape() throws {
        let median = try number("PSIPARETO", [.number(5), .number(2)], at: 0.5)
        XCTAssertEqual(median, 5 * Foundation.pow(2.0, 0.5), accuracy: 1e-6)
    }

    /// A symmetric distribution's median is its location, which pins argument one
    /// as the location rather than the scale for the whole location-scale family.
    func testTheLocationScaleFamilyPutsLocationFirst() throws {
        for name in ["PSICAUCHY", "PSILAPLACE", "PSIHYPSECANT"] {
            XCTAssertEqual(try number(name, [.number(42), .number(3)], at: 0.5), 42,
                           accuracy: 1e-6, "\(name) argument order")
        }
    }

    /// Reciprocal is log-uniform, so its median is the *geometric* mean of its
    /// bounds — √(1·100) = 10, not the arithmetic 50.5.
    func testReciprocalIsLogUniform() throws {
        let median = try number("PSIRECIPROCAL", [.number(1), .number(100)], at: 0.5)
        XCTAssertEqual(median, 10, accuracy: 1e-6)
    }

    /// Student's t with large degrees of freedom approaches the standard normal;
    /// its median is zero at any df.
    func testStudentIsCentredAtZero() throws {
        XCTAssertEqual(try number("PSISTUDENT", [.number(10)], at: 0.5), 0, accuracy: 1e-6)
    }

    /// The discrete rows return whole numbers, never a fractional count.
    func testTheDiscreteRowsReturnCounts() throws {
        for (name, args) in [("PSIHYPERGEO", [FormulaAST.number(10), .number(20), .number(50)]),
                             ("PSINEGBINOMIAL", [.number(5), .number(0.4)]),
                             ("PSIGEOMETRIC", [.number(0.3)]),
                             ("PSILOGARITHMIC", [.number(0.5)])] {
            let drawn = try number(name, args, at: 0.5)
            XCTAssertEqual(drawn, drawn.rounded(), "\(name) should be a whole count")
            XCTAssertGreaterThanOrEqual(drawn, 0, "\(name) should be non-negative")
        }
    }

    /// `PsiMinExtreme` is a distinct distribution from `PsiMaxExtreme`, not its
    /// negation — the shortcut BusinessMath's own work list warns against.
    func testTheTwoGumbelsAreNotEachOthersNegation() throws {
        let maximum = try number("PSIMAXEXTREME", [.number(0), .number(1)], at: 0.3)
        let minimum = try number("PSIMINEXTREME", [.number(0), .number(1)], at: 0.3)
        XCTAssertNotEqual(maximum, -minimum, accuracy: 1e-9)
    }

    /// The list-taking rows return a value from the list, never an index into it.
    ///
    /// `DistributionDiscreteUniform.quantile` answers an index, so returning it
    /// directly would give 0, 1, 2, 3 here — every one a plausible number and none
    /// of them in the data.
    func testTheListTakingRowsReturnValuesNotIndices() throws {
        let column = FormulaAST.cellRange(CellRange(from: CellRef(column: 1, row: 1),
                                                    to: CellRef(column: 1, row: 4)))
        for name in ["PSIDISUNIFORM", "PSIRESAMPLE", "PSISHUFFLE"] {
            for p in [0.0, 0.5, 0.99] {
                let drawn = try FormulaEvaluator.evaluate(
                    .function(name, [column]), cells: ListCells(),
                    names: NamedRangeCollection(), random: FixedSource([p]))
                guard case .number(let value) = drawn else {
                    return XCTFail("\(name) gave \(drawn)")
                }
                XCTAssertTrue(ListCells.list.contains(value),
                              "\(name) at p=\(p) gave \(value), which is not in the data")
            }
        }
    }

    /// A parameter outside the support is `#NUM!` rather than a trap or a `NaN`.
    func testImpossibleParametersAreNum() throws {
        let cases: [(String, [Double])] = [
            ("PSIBETA", [-1, 2]),
            ("PSIWEIBULL", [0, 1]),
            ("PSIEXPONENTIAL", [0]),
            ("PSIPARETO", [-5, 2]),
        ]
        for (name, args) in cases {
            let answer = try FormulaEvaluator.evaluate(
                .function(name, args.map { FormulaAST.number($0) }), cells: Cells(),
                names: NamedRangeCollection(), random: FixedSource([0.5]))
            XCTAssertEqual(answer, .error(.num), "\(name)")
        }
    }
}
