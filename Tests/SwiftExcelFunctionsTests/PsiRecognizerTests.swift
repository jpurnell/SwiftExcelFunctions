import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// Phase 1 of `PROPOSAL_model_graph_simulation.md` — the recognizer.
///
/// `SwiftXLSX.DependencyGraph` already supplies the edges, the topological order and
/// the cycle detection, so what Layer 1 actually needs building is the part that reads
/// a formula and says what *role* it plays in a simulation: does this cell report a
/// result, and does it draw one.
///
/// Every expectation here is a formula string parsed by the real parser, because a
/// recognizer tested against hand-built ASTs proves only that it agrees with whoever
/// built them.
final class PsiRecognizerTests: XCTestCase {

    private let recognizer = PsiRecognizer()

    private func recognize(_ formula: String) throws -> RecognizedFormula {
        recognizer.recognize(try FormulaParser.parse(formula))
    }

    // MARK: - Nothing to find

    func testOrdinaryFormulaCarriesNoRole() throws {
        let found = try recognize("SUM(A1:A10)*2")
        XCTAssertFalse(found.isOutput)
        XCTAssertFalse(found.isUncertain)
        XCTAssertEqual(found.distributions.count, 0)
    }

    /// A statistical function that is not Frontline's. `NORMDIST` is Excel's own and
    /// draws nothing; matching on a loose name test would claim it.
    func testExcelsOwnStatisticsAreNotDistributions() throws {
        let found = try recognize("NORMDIST(5, 0, 1, TRUE)")
        XCTAssertFalse(found.isUncertain)
    }

    // MARK: - Outputs

    /// The corpus writes `PsiOutput` *onto* a real formula rather than instead of one,
    /// 167 times across 41 workbooks. So the marker is a subexpression and the
    /// recognizer has to walk the tree rather than inspect the root.
    func testOutputMarkerIsFoundInsideAnExpression() throws {
        let found = try recognize("SUM(J2:J11)+_xll.PsiOutput()")
        XCTAssertTrue(found.isOutput)
        XCTAssertEqual(found.outputMarkers, 1)
        XCTAssertFalse(found.isUncertain)
    }

    func testBothLegacyPrefixesResolve() throws {
        XCTAssertTrue(try recognize("A1+_xll.PsiOutput()").isOutput)
        XCTAssertTrue(try recognize("A1+_xlfn.PsiOutput()").isOutput)
        XCTAssertTrue(try recognize("A1+PsiOutput()").isOutput)
    }

    // MARK: - Distributions

    func testDistributionIsRecognisedWithItsParameters() throws {
        let found = try recognize("PsiNormal(100, 10)")
        XCTAssertTrue(found.isUncertain)
        XCTAssertEqual(found.distributions.count, 1)

        let call = try XCTUnwrap(found.distributions.first)
        XCTAssertEqual(call.function, "PSINORMAL")
        XCTAssertEqual(call.parameters, [.number(100), .number(10)])
        XCTAssertNil(call.baseCase)
        XCTAssertNil(call.label)
    }

    /// `PsiTriangular(min, likely, max)` is published as `(a, c, b)` — deliberately not
    /// alphabetical. The recognizer must not reorder; it reports what was written.
    func testParametersKeepTheirWrittenOrder() throws {
        let call = try XCTUnwrap(try recognize("PsiTriangular(5, 7, 12)").distributions.first)
        XCTAssertEqual(call.parameters, [.number(5), .number(7), .number(12)])
    }

    /// A distribution nested inside ordinary arithmetic is still a draw.
    func testDistributionNestedInAnExpressionIsFound() throws {
        let found = try recognize("IF(A1>0, PsiNormal(0, 1), 0)")
        XCTAssertEqual(found.distributions.count, 1)
        XCTAssertEqual(found.distributions.first?.function, "PSINORMAL")
    }

    /// **The reason uncertainty attaches to a call site and not to a cell.**
    ///
    /// Two calls in one formula are two independent draws, and a simulation has to feed
    /// them two different uniforms. Modelling the *cell* as the unit of uncertainty
    /// would collapse them into one and silently correlate two variables that the
    /// workbook declared independent.
    func testTwoDistributionsInOneFormulaAreTwoDraws() throws {
        let found = try recognize("PsiNormal(0, 1) + PsiNormal(0, 1)")
        XCTAssertEqual(found.distributions.count, 2)
        XCTAssertEqual(found.distributions.map(\.function), ["PSINORMAL", "PSINORMAL"])
    }

    // MARK: - Property functions

    /// Property functions are arguments, not syntax, and they are not parameters.
    /// Counting `PsiBaseCase(7)` as a fourth parameter would hand the distribution an
    /// arity it does not have.
    func testBaseCaseAndNameAreLiftedOutOfTheParameters() throws {
        let call = try XCTUnwrap(
            try recognize("PsiTriangular(5, 7, 12, PsiBaseCase(7), PsiName(\"Launch\"))")
                .distributions.first)
        XCTAssertEqual(call.parameters, [.number(5), .number(7), .number(12)])
        XCTAssertEqual(call.baseCase, .number(7))
        XCTAssertEqual(call.label, "Launch")
    }

    /// The failure this guards against is silent and numeric. A property function the
    /// recognizer does not model must be *named*, never left in the parameter list —
    /// one unrecognised `PsiTruncate` would shift every parameter after it and the
    /// distribution would still compute, wrongly.
    func testUnmodelledPropertyFunctionIsNamedRatherThanTreatedAsAParameter() throws {
        let call = try XCTUnwrap(
            try recognize("PsiNormal(100, 10, PsiTruncate(0, 200))").distributions.first)
        XCTAssertEqual(call.parameters, [.number(100), .number(10)],
                       "PsiTruncate must not be counted as a third parameter")
        XCTAssertEqual(call.unhandledProperties, ["PSITRUNCATE"])
    }

    /// The corpus attests these two, so `unhandledProperties` is not a hypothetical
    /// branch. `PROPOSAL_psi_bindings.md` records `PsiCorrIndep` and `PsiCorrDepen`
    /// among the functions real workbooks call, and classifies them as declarations
    /// describing how a run is set up — which makes them properties of the draw, not
    /// parameters of the distribution.
    func testCorpusAttestedCorrelationDeclarationsAreReportedNotAbsorbed() throws {
        let call = try XCTUnwrap(
            try recognize("PsiNormal(100, 10, PsiCorrIndep(1))").distributions.first)
        XCTAssertEqual(call.parameters, [.number(100), .number(10)])
        XCTAssertEqual(call.unhandledProperties, ["PSICORRINDEP"])
    }

    /// A distribution's parameter can be an ordinary function call, and that *is* a
    /// parameter. The partition rule keys on the `Psi` prefix, not on being a call.
    func testAnOrdinaryFunctionArgumentStaysAParameter() throws {
        let call = try XCTUnwrap(
            try recognize("PsiNormal(AVERAGE(A1:A9), 10)").distributions.first)
        XCTAssertEqual(call.parameters.count, 2)
        XCTAssertEqual(call.parameters.last, .number(10))
        XCTAssertEqual(call.unhandledProperties, [])
    }

    // MARK: - The drift guard

    /// **Turns a silent misclassification into a red test.**
    ///
    /// The `Psi*` family is not distributions-plus-three-markers. It also holds
    /// statistics — `PsiMean`, `PsiStdDev`, `PsiCVaR`, `PsiPercentile`, `PsiTarget`,
    /// `PsiBVaR` — which read a completed run rather than drawing from one. All six occur
    /// in real corpus workbooks; none is registered yet.
    ///
    /// If one is registered and this recognizer classified by subtraction, it would be
    /// treated as a distribution: allocated an input index, handed a uniform, and asked
    /// to draw. It would return a number and the model would compute. Nothing would
    /// report anything.
    ///
    /// So every registered Risk Solver function must be *deliberately* classified. When
    /// this fails, the fix is to decide what the new function is — not to widen the set
    /// until it passes.
    func testEveryRegisteredRiskSolverFunctionIsClassified() {
        let distributions = Set(
            PsiRecognizer.defaultDistributions.map { FunctionRegistry.canonical($0.name) })

        let unclassified = BuiltinRiskSolverFunctions.all
            .map { FunctionRegistry.canonical($0.name) }
            .filter { !PsiRecognizer.markers.contains($0) && !distributions.contains($0) }

        XCTAssertEqual(
            unclassified.sorted(), [],
            """
            Registered but classified as neither marker nor distribution: \(unclassified.sorted()).
            Decide what each one is. If it is a statistic that reads a completed run, it             must not be recognised as a distribution — see PROPOSAL_model_graph_simulation §6.4.
            """)
    }

    // MARK: - Both roles at once

    /// A cell can draw and report in the same formula.
    func testACellCanBeBothUncertainAndAnOutput() throws {
        let found = try recognize("PsiNormal(0, 1)+PsiOutput()")
        XCTAssertTrue(found.isUncertain)
        XCTAssertTrue(found.isOutput)
    }
}
