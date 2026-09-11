import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// Solving a workbook's Solver model.
///
/// The join between the three pieces that already existed: ``ExcelSolverReader`` says what
/// the model is, ``SpreadsheetFunction`` makes the sheet callable, and BusinessMath's
/// optimizers do the searching.
final class SolverRunTests: XCTestCase {

    /// `A1`, `A2` are the variables. `B1 = A1 + A2`. `C1 = A1 - A2`.
    private struct Sheet: CellValueProvider, PopulatedCellProvider {
        var stored: [CellRef: CellValue] = [
            CellRef("A1").positionKey: .number(0),
            CellRef("A2").positionKey: .number(0),
            CellRef("A3").positionKey: .number(0),
            CellRef("D2").positionKey:
                .formula(.add(.add(.cellRef(CellRef("A1")), .cellRef(CellRef("A2"))),
                              .cellRef(CellRef("A3"))), cached: nil),
            CellRef("B1").positionKey:
                .formula(.add(.cellRef(CellRef("A1")), .cellRef(CellRef("A2"))), cached: nil),
            CellRef("C1").positionKey:
                .formula(.subtract(.cellRef(CellRef("A1")), .cellRef(CellRef("A2"))), cached: nil),
            // Deliberately nonlinear, for the Simplex refusal.
            CellRef("E1").positionKey:
                .formula(.multiply(.cellRef(CellRef("A1")), .cellRef(CellRef("A1"))), cached: nil),
        ]
        func value(at ref: CellRef) -> CellValue? { stored[ref.positionKey] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { value(at: ref) }
        func values(in range: CellRange) -> [CellValue] { range.cells.map { value(at: $0) ?? .blank } }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
        func lastPopulatedCell() -> CellRef? { CellRef("E1") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
        func populatedCells() -> [CellRef] {
            stored.keys.map { CellRef(column: $0.column, row: $0.row) }
        }
    }

    private func model(
        sense: SolverModel.Sense = .minimise,
        constraints: [SolverModel.Constraint] = [],
        engine: SolverModel.Engine = .grgNonlinear
    ) -> SolverModel {
        SolverModel(
            objective: CellRef("B1"),
            sense: sense,
            variables: [CellRef("A1"), CellRef("A2")],
            constraints: constraints,
            engine: engine)
    }

    private func solve(_ model: SolverModel) throws -> SolverRun.Solution {
        try SolverRun.solve(model, cells: Sheet(), names: NamedRangeCollection())
    }

    // MARK: - Solving

    /// **Minimising `A1 + A2` subject to `A1 - A2 = 0` and `A1 >= 3`.**
    ///
    /// The answer is forced rather than searched for: equality pins `A1 = A2`, the bound
    /// pins `A1 >= 3`, so the minimum of `A1 + A2` is 6 at `(3, 3)`. A test with one
    /// feasible optimum does not depend on which optimizer ran or where it started.
    func testMinimisesSubjectToConstraints() throws {
        let solution = try solve(model(constraints: [
            .init(lhs: [CellRef("C1")], relation: .equal, rhs: .constant(0)),
            .init(lhs: [CellRef("A1")], relation: .greaterOrEqual, rhs: .constant(3)),
        ]))
        XCTAssertEqual(solution.objective, 6, accuracy: 0.05)
        XCTAssertEqual(solution.variables[CellRef("A1").positionKey] ?? .nan, 3, accuracy: 0.05)
    }

    /// Maximising is minimising the negation, and the result reports the objective in the
    /// caller's terms rather than the optimizer's.
    func testMaximisesWithAnUpperBound() throws {
        let solution = try solve(model(
            sense: .maximise,
            constraints: [.init(lhs: [CellRef("B1")], relation: .lessOrEqual, rhs: .constant(4))]))
        XCTAssertEqual(solution.objective, 4, accuracy: 0.05)
    }

    /// **"Value of" drives the objective to a number**, which is a different problem from
    /// either extreme: the thing minimised is the distance to the target, and the reported
    /// objective is still the cell's own value.
    func testTargetValue() throws {
        let solution = try solve(model(sense: .target(7)))
        XCTAssertEqual(solution.objective, 7, accuracy: 0.05)
    }

    /// The solution carries the variables back keyed by cell, because an optimizer returns
    /// a vector and a caller needs to know which cell each slot was.
    func testVariablesComeBackKeyedByCell() throws {
        let solution = try solve(model())
        XCTAssertEqual(Set(solution.variables.keys),
                       Set([CellRef("A1").positionKey, CellRef("A2").positionKey]))
    }

    /// **A bound that names a cell is read from the sheet**, not treated as zero.
    ///
    /// `D1` holds 5, so `B1 <= D1` caps `A1 + A2` at 5 and maximising reaches exactly that.
    /// An earlier draft compared cell-valued bounds against zero, which is wrong rather
    /// than unsupported — and silently so, since the search still converges, just to the
    /// answer for a different problem.
    func testACellValuedBoundIsRead() throws {
        var sheet = Sheet()
        sheet.stored[CellRef("D1").positionKey] = .number(5)
        let bounded = SolverModel(
            objective: CellRef("B1"), sense: .maximise,
            variables: [CellRef("A1"), CellRef("A2")],
            constraints: [.init(lhs: [CellRef("B1")], relation: .lessOrEqual,
                                rhs: .cells([CellRef("D1")]))],
            engine: .grgNonlinear)
        let solution = try SolverRun.solve(bounded, cells: sheet, names: NamedRangeCollection())
        XCTAssertEqual(solution.objective, 5, accuracy: 0.05)
    }

    // MARK: - What it refuses

    /// A model with no objective has nothing to optimise.
    func testAModelWithoutAnObjectiveIsRefused() throws {
        let headless = SolverModel(objective: nil, sense: .minimise,
                                   variables: [CellRef("A1")], constraints: [], engine: .grgNonlinear)
        XCTAssertThrowsError(try solve(headless)) { error in
            XCTAssertEqual(error as? SolverRunError, SolverRunError.noObjective)
        }
    }

    /// A model with no variables has nothing to adjust.
    func testAModelWithoutVariablesIsRefused() throws {
        let fixed = SolverModel(objective: CellRef("B1"), sense: .minimise,
                                variables: [], constraints: [], engine: .grgNonlinear)
        XCTAssertThrowsError(try solve(fixed)) { error in
            XCTAssertEqual(error as? SolverRunError, SolverRunError.noVariables)
        }
    }

    // MARK: - Integrality

    /// **An integer constraint is now honoured rather than refused.** Minimising `A1 + A2`
    /// with `A1 >= 2.4` and `A1` integral puts the answer at 3, not 2.4 — the constraint
    /// changes the optimum rather than merely rounding it.
    func testIntegerConstraintIsHonoured() throws {
        let solution = try solve(model(constraints: [
            .init(lhs: [CellRef("A1")], relation: .greaterOrEqual, rhs: .constant(2.4)),
            .init(lhs: [CellRef("A2")], relation: .greaterOrEqual, rhs: .constant(0)),
            .init(lhs: [CellRef("A1")], relation: .integer, rhs: .constant(0)),
        ]))
        let a1 = solution.variables[CellRef("A1").positionKey] ?? .nan
        XCTAssertEqual(a1, a1.rounded(), accuracy: 1e-6, "A1 must be integral")
        XCTAssertEqual(a1, 3, accuracy: 0.01)
        XCTAssertEqual(solution.engineUsed, .branchAndBound)
    }

    /// A binary variable is 0 or 1 and nothing between.
    func testBinaryConstraintIsHonoured() throws {
        let solution = try solve(model(
            sense: .maximise,
            constraints: [
                .init(lhs: [CellRef("B1")], relation: .lessOrEqual, rhs: .constant(10)),
                .init(lhs: [CellRef("A1")], relation: .binary, rhs: .constant(0)),
                .init(lhs: [CellRef("A2")], relation: .lessOrEqual, rhs: .constant(0)),
            ]))
        let a1 = solution.variables[CellRef("A1").positionKey] ?? .nan
        XCTAssertTrue(abs(a1) < 1e-6 || abs(a1 - 1) < 1e-6, "A1 was \(a1), not 0 or 1")
    }

    /// **Integrality outranks the nominated engine**, as it does in Excel: a model with
    /// integer variables goes to branch-and-bound whatever the workbook asked for.
    func testIntegralityOutranksTheNominatedEngine() throws {
        let solution = try solve(model(
            constraints: [
                .init(lhs: [CellRef("A1")], relation: .greaterOrEqual, rhs: .constant(1)),
                .init(lhs: [CellRef("A2")], relation: .greaterOrEqual, rhs: .constant(0)),
                .init(lhs: [CellRef("A1")], relation: .integer, rhs: .constant(0)),
            ],
            engine: .simplexLP))
        XCTAssertEqual(solution.engineUsed, .branchAndBound)
    }

    /// An integrality constraint on a cell that is not a decision variable is malformed —
    /// Excel only lets you declare one on an adjustable cell.
    func testIntegerConstraintOnANonVariableIsRefused() throws {
        XCTAssertThrowsError(try solve(model(constraints: [
            .init(lhs: [CellRef("B1")], relation: .integer, rhs: .constant(0)),
        ]))) { error in
            XCTAssertEqual(error as? SolverRunError,
                           SolverRunError.integralityOnNonVariable(CellRef("B1")))
        }
    }

    // MARK: - All different

    /// **All-different is Excel's `dif`: integers `1…N`, each used once**, where `N` is the
    /// number of cells in the group. So three variables must be a permutation of 1, 2, 3 —
    /// which makes their sum 6 whatever the objective wanted, and that is the point of the
    /// constraint rather than a coincidence of the test.
    func testAllDifferentIsAPermutation() throws {
        let permuted = SolverModel(
            objective: CellRef("D2"), sense: .minimise,
            variables: [CellRef("A1"), CellRef("A2"), CellRef("A3")],
            constraints: [.init(lhs: [CellRef("A1"), CellRef("A2"), CellRef("A3")],
                                relation: .allDifferent, rhs: .constant(0))],
            engine: .grgNonlinear)
        let solution = try SolverRun.solve(permuted, cells: Sheet(), names: NamedRangeCollection())

        let values = [CellRef("A1"), CellRef("A2"), CellRef("A3")]
            .map { solution.variables[$0.positionKey] ?? .nan }
        for value in values {
            XCTAssertEqual(value, value.rounded(), accuracy: 1e-6, "must be integral")
            XCTAssertGreaterThanOrEqual(value, 1 - 1e-6)
            XCTAssertLessThanOrEqual(value, 3 + 1e-6)
        }
        XCTAssertEqual(Set(values.map { Int($0.rounded()) }), [1, 2, 3],
                       "each of 1…3 exactly once")
        XCTAssertEqual(solution.engineUsed, .branchAndBound)
    }

    /// All-different on a cell that is not a decision variable is malformed, as integrality
    /// is.
    func testAllDifferentOnANonVariableIsRefused() throws {
        XCTAssertThrowsError(try solve(model(constraints: [
            .init(lhs: [CellRef("B1")], relation: .allDifferent, rhs: .constant(0)),
        ]))) { error in
            XCTAssertEqual(error as? SolverRunError,
                           SolverRunError.integralityOnNonVariable(CellRef("B1")))
        }
    }

    // MARK: - Non-negativity

    /// **The default adds `x >= 0` to every variable**, which is what Excel's checkbox does.
    /// Minimising `A1 + A2` with nothing else said therefore bottoms out at 0, not at
    /// minus infinity.
    func testNonNegativityIsAssumedByDefault() throws {
        let solution = try solve(model())
        XCTAssertEqual(solution.objective, 0, accuracy: 0.05)
        for ref in [CellRef("A1"), CellRef("A2")] {
            XCTAssertGreaterThanOrEqual(solution.variables[ref.positionKey] ?? .nan, -1e-6)
        }
    }

    /// **Turning it off changes the answer**, which is the whole reason it is a setting.
    /// With `A1 >= -5` and negatives permitted, minimising `A1 + A2` reaches -5 rather
    /// than 0.
    func testPermittingNegativesChangesTheAnswer() throws {
        let signed = SolverModel(
            objective: CellRef("B1"), sense: .minimise,
            variables: [CellRef("A1"), CellRef("A2")],
            constraints: [
                .init(lhs: [CellRef("A1")], relation: .greaterOrEqual, rhs: .constant(-5)),
                .init(lhs: [CellRef("A2")], relation: .greaterOrEqual, rhs: .constant(0)),
            ],
            engine: .grgNonlinear,
            assumesNonNegative: false)
        let solution = try SolverRun.solve(signed, cells: Sheet(), names: NamedRangeCollection())
        XCTAssertEqual(solution.objective, -5, accuracy: 0.1)
    }

    /// And Simplex handles a free variable by splitting it, rather than refusing.
    func testSimplexSolvesWithNegativesPermitted() throws {
        let signed = SolverModel(
            objective: CellRef("B1"), sense: .minimise,
            variables: [CellRef("A1"), CellRef("A2")],
            constraints: [
                .init(lhs: [CellRef("A1")], relation: .greaterOrEqual, rhs: .constant(-5)),
                .init(lhs: [CellRef("A2")], relation: .greaterOrEqual, rhs: .constant(0)),
            ],
            engine: .simplexLP,
            assumesNonNegative: false)
        let solution = try SolverRun.solve(signed, cells: Sheet(), names: NamedRangeCollection())
        XCTAssertEqual(solution.engineUsed, .simplex)
        XCTAssertEqual(solution.objective, -5, accuracy: 0.1)
    }

    // MARK: - Simplex

    /// **A linear model nominated for Simplex really runs Simplex.** `B1 = A1 + A2` is
    /// linear in both variables, so the coefficients extract and the LP solves.
    func testLinearModelRunsOnSimplex() throws {
        let solution = try solve(model(
            sense: .maximise,
            constraints: [
                .init(lhs: [CellRef("B1")], relation: .lessOrEqual, rhs: .constant(7)),
                .init(lhs: [CellRef("A1")], relation: .greaterOrEqual, rhs: .constant(0)),
                .init(lhs: [CellRef("A2")], relation: .greaterOrEqual, rhs: .constant(0)),
            ],
            engine: .simplexLP))
        XCTAssertEqual(solution.engineUsed, .simplex)
        XCTAssertEqual(solution.objective, 7, accuracy: 0.01)
    }

    /// **A nonlinear model nominated for Simplex is refused, not silently re-solved.**
    /// Excel says the same thing — "the linearity conditions required by this LP Solver are
    /// not satisfied" — and it is the right answer: quietly switching engines would return
    /// a number the caller believes came from an LP.
    func testNonlinearModelIsRefusedBySimplex() throws {
        let squared = SolverModel(
            objective: CellRef("E1"), sense: .minimise,
            variables: [CellRef("A1"), CellRef("A2")],
            constraints: [.init(lhs: [CellRef("A1")], relation: .greaterOrEqual,
                                rhs: .constant(1))],
            engine: .simplexLP)
        XCTAssertThrowsError(try solve(squared)) { error in
            guard case .nonlinearModel = error as? SolverRunError else {
                return XCTFail("expected nonlinearModel, got \(error)")
            }
        }
    }

    /// The same nonlinear model solves happily under the nonlinear engine.
    func testNonlinearModelSolvesUnderGRG() throws {
        let squared = SolverModel(
            objective: CellRef("E1"), sense: .minimise,
            variables: [CellRef("A1"), CellRef("A2")],
            constraints: [.init(lhs: [CellRef("A1")], relation: .greaterOrEqual,
                                rhs: .constant(2))],
            engine: .grgNonlinear)
        let solution = try solve(squared)
        XCTAssertEqual(solution.objective, 4, accuracy: 0.1)
    }

    // MARK: - Evolutionary

    /// The evolutionary engine is dispatched to, and reported. Both variables are bounded,
    /// because a population-based search has nowhere to sample otherwise.
    func testEvolutionaryEngine() throws {
        let solution = try solve(model(
            constraints: [
                .init(lhs: [CellRef("A1")], relation: .greaterOrEqual, rhs: .constant(1)),
                .init(lhs: [CellRef("A1")], relation: .lessOrEqual, rhs: .constant(9)),
                .init(lhs: [CellRef("A2")], relation: .greaterOrEqual, rhs: .constant(1)),
                .init(lhs: [CellRef("A2")], relation: .lessOrEqual, rhs: .constant(9)),
            ],
            engine: .evolutionary))
        XCTAssertEqual(solution.engineUsed, .differentialEvolution)
        XCTAssertEqual(solution.objective, 2, accuracy: 0.5)
    }

    /// **An unbounded variable is refused**, as Excel refuses it: a population-based search
    /// samples within a box, and inventing one would make the answer depend on a number
    /// nobody in the workbook chose.
    func testEvolutionaryRefusesAnUnboundedVariable() throws {
        XCTAssertThrowsError(try solve(model(
            constraints: [.init(lhs: [CellRef("A1")], relation: .greaterOrEqual,
                                rhs: .constant(1))],
            engine: .evolutionary))) { error in
            XCTAssertEqual(error as? SolverRunError,
                           SolverRunError.evolutionaryNeedsBounds(CellRef("A1")))
        }
    }

    // MARK: - The engine

    /// **The engine actually used is reported, not assumed.** The workbook nominates one;
    /// this reports what ran, so a caller is never misled about how their answer was found.
    func testTheEngineUsedIsReported() throws {
        let solution = try solve(model(engine: .grgNonlinear))
        XCTAssertEqual(solution.engineUsed, .nelderMead)
    }
}
