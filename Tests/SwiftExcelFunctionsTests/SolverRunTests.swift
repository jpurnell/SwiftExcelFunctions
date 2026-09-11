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
            CellRef("B1").positionKey:
                .formula(.add(.cellRef(CellRef("A1")), .cellRef(CellRef("A2"))), cached: nil),
            CellRef("C1").positionKey:
                .formula(.subtract(.cellRef(CellRef("A1")), .cellRef(CellRef("A2"))), cached: nil),
        ]
        func value(at ref: CellRef) -> CellValue? { stored[ref.positionKey] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { value(at: ref) }
        func values(in range: CellRange) -> [CellValue] { range.cells.map { value(at: $0) ?? .blank } }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
        func lastPopulatedCell() -> CellRef? { CellRef("C1") }
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

    /// **An integrality constraint is refused, not ignored.**
    ///
    /// Dropping it would answer a different question than the one asked and return a
    /// fractional solution to a problem that required whole numbers — the plausible wrong
    /// answer this project exists to avoid. Branch-and-bound exists upstream; wiring it is
    /// separate work, and until then this says so.
    func testIntegerConstraintsAreRefusedRatherThanDropped() throws {
        XCTAssertThrowsError(try solve(model(constraints: [
            .init(lhs: [CellRef("A1")], relation: .integer, rhs: .constant(0)),
        ]))) { error in
            XCTAssertEqual(error as? SolverRunError,
                           SolverRunError.unsupportedRelation(.integer))
        }
    }

    func testBinaryConstraintsAreRefused() throws {
        XCTAssertThrowsError(try solve(model(constraints: [
            .init(lhs: [CellRef("A1")], relation: .binary, rhs: .constant(0)),
        ])))
    }

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

    // MARK: - The engine

    /// **The engine actually used is reported, not assumed.** The workbook nominates one;
    /// this reports what ran, so a caller is never misled about how their answer was found.
    func testTheEngineUsedIsReported() throws {
        let solution = try solve(model(engine: .simplexLP))
        XCTAssertEqual(solution.engineUsed, .nelderMead,
                       "Simplex needs a linear model extracted from the sheet, which is not done yet")
    }
}
