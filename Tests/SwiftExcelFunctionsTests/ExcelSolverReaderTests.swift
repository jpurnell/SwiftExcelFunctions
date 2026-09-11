import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// Reading a classic Excel Solver model out of a workbook's defined names.
///
/// **Solver stores its model in defined names, not in cells or functions.** That is why no
/// amount of function coverage ever revealed whether a workbook had one, and why the
/// coverage matrix is blind to it: there is nothing to call.
///
/// The encodings below — `solver_typ` 1/2/3, the relation codes, the engine codes — are
/// taken from Frontline's published layout and are **not measured against a real workbook**.
/// They are pinned here so that a disagreement is a failing test rather than a silent
/// misreading, and so the one place to correct them is obvious.
final class ExcelSolverReaderTests: XCTestCase {

    private func names(_ pairs: [(String, NamedRangeTarget)]) -> NamedRangeCollection {
        var collection = NamedRangeCollection()
        for (name, target) in pairs {
            collection.add(NamedRange(name: name, reference: target, scope: .workbook))
        }
        return collection
    }

    private func cell(_ ref: String) -> NamedRangeTarget { .cell(CellRef(ref)) }
    private func range(_ from: String, _ to: String) -> NamedRangeTarget {
        .range(CellRange(from: CellRef(from), to: CellRef(to)))
    }
    private func number(_ value: Double) -> NamedRangeTarget { .formula(.number(value)) }

    /// Minimise `B1` by adjusting `A1:A3`, subject to `C1 <= 10`.
    private var minimal: NamedRangeCollection {
        names([
            ("solver_opt", cell("B1")),
            ("solver_typ", number(2)),
            ("solver_adj", range("A1", "A3")),
            ("solver_num", number(1)),
            ("solver_lhs1", cell("C1")),
            ("solver_rel1", number(1)),
            ("solver_rhs1", number(10)),
        ])
    }

    // MARK: - The model

    func testReadsObjectiveAndVariables() throws {
        let model = try XCTUnwrap(ExcelSolverReader.model(from: minimal))
        XCTAssertEqual(model.objective, CellRef("B1"))
        XCTAssertEqual(model.variables, [CellRef("A1"), CellRef("A2"), CellRef("A3")])
    }

    /// **`solver_adj` is a range and the optimizer needs a vector.** Expanding it here, in
    /// reading order, is what fixes the correspondence between a solution's `x[0]` and a
    /// particular cell — and nothing downstream can recover that order if it is lost.
    func testVariablesKeepTheirRangeOrder() throws {
        let model = try XCTUnwrap(ExcelSolverReader.model(from: minimal))
        XCTAssertEqual(model.variables.map(\.reference), ["A1", "A2", "A3"])
    }

    func testSenseMinimise() throws {
        XCTAssertEqual(try XCTUnwrap(ExcelSolverReader.model(from: minimal)).sense, .minimise)
    }

    func testSenseMaximise() throws {
        var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
        pairs = pairs.map { $0.0 == "solver_typ" ? ($0.0, number(1)) : $0 }
        XCTAssertEqual(try XCTUnwrap(ExcelSolverReader.model(from: names(pairs))).sense, .maximise)
    }

    /// `solver_typ` of 3 means "value of", and the target sits in `solver_val`.
    func testSenseTargetValue() throws {
        var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
        pairs = pairs.map { $0.0 == "solver_typ" ? ($0.0, number(3)) : $0 }
        pairs.append(("solver_val", number(42)))
        XCTAssertEqual(try XCTUnwrap(ExcelSolverReader.model(from: names(pairs))).sense,
                       .target(42))
    }

    // MARK: - Constraints

    func testReadsAConstraint() throws {
        let model = try XCTUnwrap(ExcelSolverReader.model(from: minimal))
        XCTAssertEqual(model.constraints.count, 1)
        XCTAssertEqual(model.constraints.first?.lhs, [CellRef("C1")])
        XCTAssertEqual(model.constraints.first?.relation, .lessOrEqual)
        XCTAssertEqual(model.constraints.first?.rhs, .constant(10))
    }

    /// **`solver_num` is the count, and it is authoritative.** A workbook that has been
    /// edited can leave `solver_lhs4` behind after the model dropped to three constraints,
    /// and reading every `solver_lhs*` present would silently resurrect it.
    func testStaleConstraintsBeyondTheCountAreIgnored() throws {
        var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
        pairs.append(("solver_lhs2", cell("C2")))
        pairs.append(("solver_rel2", number(3)))
        pairs.append(("solver_rhs2", number(5)))
        let model = try XCTUnwrap(ExcelSolverReader.model(from: names(pairs)))
        XCTAssertEqual(model.constraints.count, 1, "solver_num says one")
    }

    /// A right-hand side may be a cell rather than a number.
    func testConstraintAgainstACell() throws {
        var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
        pairs = pairs.map { $0.0 == "solver_rhs1" ? ($0.0, cell("D1")) : $0 }
        let model = try XCTUnwrap(ExcelSolverReader.model(from: names(pairs)))
        XCTAssertEqual(model.constraints.first?.rhs, .cells([CellRef("D1")]))
    }

    /// The relation codes, pinned together so the mapping is one visible table.
    func testRelationCodes() throws {
        let expected: [(Double, SolverModel.Relation)] = [
            (1, .lessOrEqual), (2, .equal), (3, .greaterOrEqual),
            (4, .integer), (5, .binary), (6, .allDifferent),
        ]
        for (code, relation) in expected {
            var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
            pairs = pairs.map { $0.0 == "solver_rel1" ? ($0.0, number(code)) : $0 }
            let model = try XCTUnwrap(ExcelSolverReader.model(from: names(pairs)))
            XCTAssertEqual(model.constraints.first?.relation, relation, "code \(code)")
        }
    }

    // MARK: - Engine

    /// `solver_eng`: 1 GRG Nonlinear, 2 Simplex LP, 3 Evolutionary. Absent means GRG, which
    /// is Excel's own default.
    func testEngineCodes() throws {
        let expected: [(Double, SolverModel.Engine)] = [
            (1, .grgNonlinear), (2, .simplexLP), (3, .evolutionary),
        ]
        for (code, engine) in expected {
            var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
            pairs.append(("solver_eng", number(code)))
            XCTAssertEqual(try XCTUnwrap(ExcelSolverReader.model(from: names(pairs))).engine,
                           engine, "code \(code)")
        }
    }

    func testAbsentEngineDefaultsToGRG() throws {
        XCTAssertEqual(try XCTUnwrap(ExcelSolverReader.model(from: minimal)).engine, .grgNonlinear)
    }

    // MARK: - Absence

    /// **No Solver names is not an empty model, it is no model.** A workbook that never had
    /// one must be distinguishable from one whose objective is missing.
    func testAWorkbookWithoutSolverNamesHasNoModel() throws {
        XCTAssertNil(ExcelSolverReader.model(from: NamedRangeCollection()))
    }

    /// Names are matched case-insensitively: Excel writes `solver_opt`, but a workbook
    /// round-tripped through another tool may not preserve the case.
    func testNamesAreMatchedCaseInsensitively() throws {
        var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
        pairs = pairs.map { ($0.0.uppercased(), $0.1) }
        XCTAssertNotNil(ExcelSolverReader.model(from: names(pairs)))
    }
}
