import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX
import BusinessMath

/// The lowering pass — `FormulaAST` over a graph of cells into BusinessMath bytecode.
///
/// `PROPOSAL_model_graph_simulation.md` §3.1: lowering is an **optimization, not a
/// requirement**. The interpreted loop already runs every model correctly. This exists
/// because the same work costs 493 ns per propagation operation interpreted and 4.2 ns
/// compiled — a measured 118× — and a real model propagates hundreds of times per trial.
///
/// So the bar is not "does it produce a number". It is **"does it produce the same numbers
/// the interpreted path does, bit for bit"**, and every test here is written against that.
final class LowererTests: XCTestCase {

    private struct Sheet: CellValueProvider, PopulatedCellProvider {
        var cells: [CellRef: CellValue] = [:]

        init(formulas: [String: String] = [:], constants: [String: Double] = [:]) throws {
            for (ref, f) in formulas {
                cells[CellRef(ref)] = .formula(try FormulaParser.parse(f), cached: nil)
            }
            for (ref, v) in constants { cells[CellRef(ref)] = .number(v) }
        }

        func populatedCells() -> [CellRef] { Array(cells.keys) }
        func value(at ref: CellRef) -> CellValue? { cells[ref.absolute()] ?? cells[ref] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { value(at: ref) }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { value(at: $0) ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
        func lastPopulatedCell() -> CellRef? {
            guard let c = cells.keys.map(\.column).max(),
                  let r = cells.keys.map(\.row).max() else { return nil }
            return CellRef(column: c, row: r)
        }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func survey(_ sheet: Sheet) -> ModelSurvey { ModelSurveyor().survey(sheet) }

    // MARK: - What lowers

    func testArithmeticLowers() throws {
        let sheet = try Sheet(formulas: [
            "B1": "PsiUniform(0, 1)",
            "B2": "B1*2+3",
            "B3": "B2+PsiOutput()"
        ])
        let lowered = try Lowerer().lower(
            output: CellRef("B3"), survey: survey(sheet), cells: sheet)

        XCTAssertEqual(lowered.inputCount, 1)
        XCTAssertGreaterThan(lowered.instructionCount, 0)
        // input 0.5 → 0.5*2+3 = 4
        XCTAssertEqual(try lowered.model.evaluate(inputs: [0.5]), 4.0, accuracy: 1e-12)
    }

    /// `Expression` has a ternary, so `IF` is a direct lowering rather than a workaround.
    func testConditionalLowers() throws {
        let sheet = try Sheet(formulas: [
            "B1": "PsiUniform(0, 1)",
            "B2": "IF(B1>0.5, 10, 20)",
            "B3": "B2+PsiOutput()"
        ])
        let lowered = try Lowerer().lower(
            output: CellRef("B3"), survey: survey(sheet), cells: sheet)

        XCTAssertEqual(try lowered.model.evaluate(inputs: [0.9]), 10.0, accuracy: 1e-12)
        XCTAssertEqual(try lowered.model.evaluate(inputs: [0.1]), 20.0, accuracy: 1e-12)
    }

    /// `SUM` over a range folds; `SUMPRODUCT` is `ExpressionArray.dot(_:)` exactly.
    func testRangeAggregatesLower() throws {
        let sheet = try Sheet(
            formulas: [
                "A1": "PsiUniform(0, 1)",
                "D1": "SUM(A1:A3)+PsiOutput()"
            ],
            constants: ["A2": 10, "A3": 100])
        let lowered = try Lowerer().lower(
            output: CellRef("D1"), survey: survey(sheet), cells: sheet)

        XCTAssertEqual(try lowered.model.evaluate(inputs: [5]), 115.0, accuracy: 1e-12)
    }

    /// A cell read twice is one draw, not two — the input index is per call site and the
    /// inlined subtree refers back to the same index.
    func testACellReadTwiceIsOneInput() throws {
        let sheet = try Sheet(formulas: [
            "B1": "PsiUniform(0, 1)",
            "B2": "B1+B1",
            "B3": "B2+PsiOutput()"
        ])
        let lowered = try Lowerer().lower(
            output: CellRef("B3"), survey: survey(sheet), cells: sheet)

        XCTAssertEqual(lowered.inputCount, 1)
        XCTAssertEqual(try lowered.model.evaluate(inputs: [3]), 6.0, accuracy: 1e-12)
    }

    // MARK: - What refuses

    /// §5.1: refuse rather than approximate. `Expression` is `Double`-only, so a model
    /// whose trial path can produce text has no faithful lowering — and a NaN standing in
    /// for a string would propagate into a mean nobody could question.
    func testTextRefuses() throws {
        let sheet = try Sheet(formulas: [
            "B1": "PsiUniform(0, 1)",
            "B2": "\"total: \"&B1",
            "B3": "B2+PsiOutput()"
        ])
        let failures = Lowerer().audit(
            output: CellRef("B3"), survey: survey(sheet), cells: sheet)
        XCTAssertFalse(failures.isEmpty)
    }

    /// §5.2: `OFFSET` and `INDIRECT` compute their *address*, so the shape of the
    /// expression would vary per trial. They can never lower.
    func testComputedAddressRefuses() throws {
        let sheet = try Sheet(formulas: [
            "B1": "PsiUniform(0, 1)",
            "B2": "OFFSET(A1, B1, 0)",
            "B3": "B2+PsiOutput()"
        ])
        let failures = Lowerer().audit(
            output: CellRef("B3"), survey: survey(sheet), cells: sheet)
        XCTAssertTrue(failures.contains { if case .computedAddress = $0 { return true } else { return false } })
    }

    /// A function with no opcode is named, not approximated.
    func testUnrepresentableFunctionIsNamed() throws {
        let sheet = try Sheet(formulas: [
            "B1": "PsiUniform(0, 1)",
            "B2": "VLOOKUP(B1, A1:A3, 1)",
            "B3": "B2+PsiOutput()"
        ])
        let failures = Lowerer().audit(
            output: CellRef("B3"), survey: survey(sheet), cells: sheet)
        XCTAssertTrue(failures.contains {
            if case .unrepresentableFunction(let name, _) = $0 { return name == "VLOOKUP" }
            return false
        })
    }

    /// `audit` returning empty is the precondition for `lower` succeeding, and both are
    /// pure functions of the model — which is what makes a corpus survey cheap.
    func testAuditIsEmptyExactlyWhenLoweringSucceeds() throws {
        let ok = try Sheet(formulas: [
            "B1": "PsiUniform(0, 1)", "B2": "B1*2", "B3": "B2+PsiOutput()"
        ])
        XCTAssertTrue(Lowerer().audit(output: CellRef("B3"), survey: survey(ok), cells: ok).isEmpty)
        XCTAssertNoThrow(try Lowerer().lower(output: CellRef("B3"), survey: survey(ok), cells: ok))
    }

    // MARK: - The test that earns the design

    /// **Compiled and interpreted must agree bit for bit.**
    ///
    /// Not to a tolerance. Both paths do the same arithmetic on the same draws, so any
    /// difference is a defect in the lowering rather than drift — and a wrong `SUM` fold
    /// or a mis-ordered input index fails this immediately.
    ///
    /// This is the test that makes it safe to add lowering rules at all: §3.1's two paths
    /// are a correctness baseline and a fast path, and this is the sentence that says they
    /// are the same computation.
    func testCompiledAgreesWithInterpretedBitForBit() throws {
        let sheet = try Sheet(
            formulas: [
                "B1": "PsiUniform(0, 1)",
                "B2": "PsiUniform(0, 1)",
                "B3": "B1*100+B2*7",
                "B4": "IF(B3>50, B3*2, B3/4)",
                "B5": "SUM(B3:B4)+B4+PsiOutput()"
            ])
        let model = survey(sheet)
        let order = ["B1", "B2", "B3", "B4", "B5"].map { CellRef($0) }

        let interpreted = try InterpretedRun(
            survey: model, evaluationOrder: order, trials: 1_000, seed: 42
        ).run(over: sheet, names: NoNames())

        let lowered = try Lowerer().lower(output: CellRef("B5"), survey: model, cells: sheet)

        // Feed the compiled model the same draws the interpreted path used, in the same
        // order, by re-drawing from an identically seeded source.
        let random = SeededRandomSource(SplitMix64(seed: 42))
        var compiled: [Double] = []
        for _ in 0..<1_000 {
            let inputs = model.uncertain.map { cell -> Double in
                _ = cell
                return random.nextUniform()
            }
            compiled.append(try lowered.model.evaluate(inputs: inputs))
        }

        XCTAssertEqual(interpreted.results(for: CellRef("B5"))?.values, compiled,
                       "the two paths disagree — the lowering is wrong, not the randomness")
    }
}
