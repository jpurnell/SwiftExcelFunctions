import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// Reading a classic Excel Solver model out of a workbook's defined names.
///
/// **Solver stores its model in defined names, not in cells or functions.** That is why no
/// amount of function coverage ever revealed whether a workbook had one, and why the
/// coverage matrix is blind to it: there is nothing to call.
///
/// **Every encoding below is measured**, from two workbooks built in Excel for Mac on
/// 2026-09-11 and saved without solving. `solver_ver` was 2 in both.
///
/// | Read from the file | |
/// |---|---|
/// | `solver_rel` | `1 <=`, `2 =`, `3 >=`, `4 integer`, `5 binary`, `6 alldifferent` |
/// | `solver_typ` | `1` Max, `3` Value Of, with the target in `solver_val` |
/// | `solver_eng` | `2` Simplex LP, `3` Evolutionary |
/// | `solver_neg` | `1` assume non-negative, `2` permit negatives |
///
/// `solver_typ = 2` for Min and `solver_eng = 1` for GRG are the remaining values in each
/// set and were not separately built; everything else here came off a real file.
final class ExcelSolverReaderTests: XCTestCase {

    private func names(
        _ pairs: [(String, NamedRangeTarget)], sheet: String = "Sheet1"
    ) -> NamedRangeCollection {
        var collection = NamedRangeCollection()
        for (name, target) in pairs {
            collection.add(NamedRange(name: name, reference: target, scope: .sheet(sheet)))
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

    // MARK: - What the real files taught

    /// **A word, not a number.** Excel writes `"integer"`, `"binary"` and `"alldifferent"`
    /// into `solver_rhsN` where a bound would go. Before a real file was read this fell
    /// through to an empty cell list — harmless, since integrality ignores its bound, but
    /// accidental rather than intended.
    func testIntegralityBoundIsAWord() throws {
        var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
        pairs = pairs.map { $0.0 == "solver_rel1" ? ($0.0, number(4)) : $0 }
        pairs = pairs.map { $0.0 == "solver_rhs1" ? ($0.0, .formula(.text("integer"))) : $0 }
        let model = try XCTUnwrap(ExcelSolverReader.model(from: names(pairs)))
        XCTAssertEqual(model.constraints.first?.rhs, .label("integer"))
        XCTAssertEqual(model.constraints.first?.relation, .integer)
    }

    /// **The stale-constraint case, as a real workbook produced it.** A model edited from
    /// six constraints down to one keeps `solver_lhs2…6` and `solver_rel2…6` in the file —
    /// including an `alldifferent`. `solver_num` is the only thing that says they are gone.
    func testStaleConstraintsFromAnEditedWorkbook() throws {
        var pairs: [(String, NamedRangeTarget)] = [
            ("solver_opt", cell("B1")),
            ("solver_typ", number(3)),
            ("solver_val", number(42)),
            ("solver_adj", range("A1", "A3")),
            ("solver_num", number(1)),
            ("solver_lhs1", cell("C1")),
            ("solver_rel1", number(1)),
            ("solver_rhs1", number(10)),
        ]
        // The leftovers, exactly as Excel wrote them.
        pairs += [
            ("solver_lhs2", range("A1", "A3")), ("solver_rel2", number(6)),
            ("solver_rhs2", .formula(.text("alldifferent"))),
            ("solver_lhs3", cell("A2")), ("solver_rel3", number(5)),
            ("solver_rhs3", .formula(.text("binary"))),
        ]
        let model = try XCTUnwrap(ExcelSolverReader.model(from: names(pairs)))
        XCTAssertEqual(model.constraints.count, 1)
        XCTAssertEqual(model.sense, .target(42))
    }

    /// `solver_ver` is recorded, because it is the one value that could make every other
    /// encoding wrong at once.
    func testFormatVersionIsRecorded() throws {
        var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
        pairs.append(("solver_ver", number(2)))
        XCTAssertEqual(try XCTUnwrap(ExcelSolverReader.model(from: names(pairs))).formatVersion, 2)
    }

    // MARK: - Non-negativity

    /// Excel's default is to assume it, so an absent `solver_neg` means `true`.
    func testNonNegativityDefaultsToAssumed() throws {
        XCTAssertTrue(try XCTUnwrap(ExcelSolverReader.model(from: minimal)).assumesNonNegative)
    }

    /// `solver_neg` of 2 permits negative variables.
    func testSolverNegTwoPermitsNegatives() throws {
        var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
        pairs.append(("solver_neg", number(2)))
        XCTAssertFalse(try XCTUnwrap(ExcelSolverReader.model(from: names(pairs))).assumesNonNegative)
    }

    // MARK: - Sheet scope

    /// **A model belongs to a sheet, and two sheets' models must not merge.** Excel writes
    /// every `solver_` name with a `localSheetId`, so a workbook can hold several. Read
    /// into one namespace they collide: the last `solver_opt` wins and the constraint count
    /// arrives from the other model entirely.
    func testTwoSheetsKeepTheirOwnModels() throws {
        var collection = NamedRangeCollection()
        for entry in names(Array(minimal.all.map { ($0.name, $0.reference) }),
                           sheet: "Sheet1").all {
            collection.add(entry)
        }
        // A second sheet: a different objective, maximising, with no constraints.
        for (name, target) in [("solver_opt", cell("Z9")), ("solver_typ", number(1)),
                               ("solver_adj", range("Y1", "Y2")), ("solver_num", number(0))] {
            collection.add(NamedRange(name: name, reference: target, scope: .sheet("Sheet2")))
        }

        let all = ExcelSolverReader.models(from: collection)
        XCTAssertEqual(Set(all.keys), ["Sheet1", "Sheet2"])
        XCTAssertEqual(all["Sheet1"]?.objective, CellRef("B1"))
        XCTAssertEqual(all["Sheet1"]?.constraints.count, 1)
        XCTAssertEqual(all["Sheet2"]?.objective, CellRef("Z9"))
        XCTAssertEqual(all["Sheet2"]?.sense, .maximise)
        XCTAssertEqual(all["Sheet2"]?.constraints.count, 0)
    }

    // MARK: - solver_lin

    /// **A workbook older than the engine dropdown declares linearity instead.**
    /// `solver_lin` is the pre-2010 "Assume Linear Model" checkbox, and Excel still writes
    /// it — `1` beside Simplex, `2` beside Evolutionary. With no `solver_eng` at all, a
    /// `solver_lin` of 1 means a linear model, and reading it as GRG would solve a linear
    /// program with a nonlinear method.
    func testSolverLinStandsInForAMissingEngine() throws {
        var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
        pairs.append(("solver_lin", number(1)))
        XCTAssertEqual(try XCTUnwrap(ExcelSolverReader.model(from: names(pairs))).engine,
                       .simplexLP)
    }

    /// And it never overrides an engine that is actually stated.
    func testAnExplicitEngineOutranksSolverLin() throws {
        var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
        pairs.append(("solver_lin", number(1)))
        pairs.append(("solver_eng", number(3)))
        XCTAssertEqual(try XCTUnwrap(ExcelSolverReader.model(from: names(pairs))).engine,
                       .evolutionary)
    }

    // MARK: - Multi-area references

    /// **Changing cells may be several blocks.** Excel lets `By Changing` be
    /// `$A$1:$A$3,$C$5` and writes it as one name, which resolves to neither a cell nor a
    /// range — so it arrives as text. Returning nothing for it reads as "a model with
    /// nothing to adjust", which is a model that cannot be solved rather than one that
    /// could not be parsed.
    func testMultiAreaChangingCells() throws {
        var pairs = Array(minimal.all.map { ($0.name, $0.reference) })
        pairs = pairs.map {
            $0.0 == "solver_adj"
                ? ($0.0, NamedRangeTarget.formula(.text("Sheet1!$A$1:$A$3,Sheet1!$C$5")))
                : $0
        }
        let model = try XCTUnwrap(ExcelSolverReader.model(from: names(pairs)))
        XCTAssertEqual(model.variables.map(\.reference), ["A1", "A2", "A3", "C5"])
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
