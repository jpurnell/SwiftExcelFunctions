import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import BusinessMath

/// Phase 0 of `PROPOSAL_model_graph_simulation.md` — the measurement, not the feature.
///
/// The proposal's §3.1 rests on a claim nobody has measured: that lowering a workbook's
/// formulas into BusinessMath's bytecode is *worth it* relative to walking the
/// `FormulaAST` once per trial. If the ratio is small the compiled path is a nicety and
/// the GUI should come first; if it is large, lowering coverage is the product. §9 calls
/// this "the single most load-bearing unknown in this proposal."
///
/// ## What is actually being compared
///
/// Both paths draw their uncertain inputs **through the same registry code**, in the same
/// order, from an identically seeded generator. `PsiNormal` and friends are quantile
/// functions of a uniform — `sampling(...)` calls `random.nextUniform()` and applies the
/// inverse CDF — and no bytecode opcode can express an inverse CDF. So the distributions
/// are never lowered: each uncertain cell becomes one `.input(i)` and the sampler fills it
/// from outside, exactly as §5.4 describes.
///
/// What differs between the paths, and therefore what this measures, is **propagation** —
/// the arithmetic the workbook itself performs on those draws:
///
/// ```
///   B1 = PsiNormal(100, 10)        uncertain  → input 0
///   B2 = PsiTriangular(5, 7, 12)   uncertain  → input 1
///   B3 = B1 * B2                   propagation
///   B4 = B3 + 250                  propagation, the output
/// ```
///
/// Path A walks `B3` and `B4` as `FormulaAST` through `FormulaEvaluator`, reading `B1` and
/// `B2` back out of a mutable provider. Path B evaluates `(input0 * input1) + 250` as
/// compiled bytecode. Same draws, same answer, different machinery.
///
/// ## The answer, measured 2026-09-08
///
/// **Marginal cost of one propagation operation, per trial, release build:**
/// interpreted 493 ns, compiled 4.2 ns — a ratio of **118x**. Whole-run cost at depth
/// 500 is 58x and still climbing; the curve has not plateaued.
///
/// **Run this in release or do not run it.** The same sweep in a debug build reports
/// 3.8x, because optimization makes the bytecode path about 70x faster while making the
/// AST walk only 2.3x faster. A debug measurement understates the ratio by roughly 31x
/// and would support exactly the wrong plan — that lowering is a nicety and the GUI
/// should come first. It is not, and it should not.
///
/// ```
/// swift test -c release --filter Phase0LoweringSpikeTests
/// ```
///
/// Two reasons this is a floor rather than a ceiling for real workbooks: the propagation
/// step here is `+ 1.0`, where a real formula dispatches through the registry and reads
/// ranges, and the provider here is a dictionary, where a workbook-backed one costs more.
/// Both make the interpreted side more expensive, not less.
///
/// ## This is a spike
///
/// The graph is hand-built. There is no `.xlsx`, no recognizer, no `ModelGraph` type, and
/// no lowering pass — writing those is Phase 1 and 2, and their order depends on what this
/// prints.
final class Phase0LoweringSpikeTests: XCTestCase {

    // MARK: - The model

    private static let trials = 10_000
    private static let seed: UInt64 = 42

    private static let outputConstant = 250.0

    /// `B1` — the first uncertain cell.
    private static let b1: FormulaAST = .function("PSINORMAL", [.number(100), .number(10)])

    /// `B2` — the second uncertain cell.
    private static let b2: FormulaAST = .function("PSITRIANGULAR", [.number(5), .number(7), .number(12)])

    /// `B3 = B1 * B2` — propagation, and the first thing that has to lower.
    private static let b3: FormulaAST = .multiply(
        .cellRef(CellRef(column: 2, row: 1)),
        .cellRef(CellRef(column: 2, row: 2))
    )

    /// `B4 = B3 + 250` — propagation, and the output.
    private static let b4: FormulaAST = .add(
        .cellRef(CellRef(column: 2, row: 3)),
        .number(outputConstant)
    )

    // MARK: - Test doubles

    /// A provider whose cells can be rewritten between trials.
    ///
    /// This is the interpreted path's whole mechanism: assign the trial's draws, then
    /// re-evaluate the formulas that depend on them. A `struct` rather than a class
    /// because `CellValueProvider` is `Sendable` and each trial gets a fresh copy —
    /// which is also what keeps one trial from leaking into the next.
    private struct MutableCells: CellValueProvider {
        var values: [CellRef: CellValue] = [:]

        func value(at ref: CellRef) -> CellValue? { values[ref] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { values[ref] }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private static func number(_ value: CellValue) throws -> Double {
        guard case .number(let d) = value else {
            throw XCTSkip("expected a number, got \(value)")
        }
        return d
    }

    /// A fresh generator at the fixed seed.
    ///
    /// Both paths call this, so both consume the identical uniform stream. If they ever
    /// disagree bit-for-bit, the lowering is wrong — not the randomness.
    private static func randomSource() -> SeededRandomSource<SplitMix64> {
        SeededRandomSource(SplitMix64(seed: seed))
    }

    // MARK: - Propagation chains

    /// `B3 = B1 * B2`, then `depth` further `+ 1.0` cells stacked on top of it.
    ///
    /// The chain is the instrument. One propagation step tells us nothing, because the
    /// shared sampling cost swamps it — the first run of this spike measured 1.2x and
    /// was measuring mostly the draws. Sweeping the depth separates the two: the
    /// intercept is sampling, and the *slope* is the per-operation cost of propagation,
    /// which is the only thing lowering changes.
    private static func interpretedChain(depth: Int) -> [(CellRef, FormulaAST)] {
        var cells: [(CellRef, FormulaAST)] = [
            (CellRef(column: 2, row: 3), .multiply(
                .cellRef(CellRef(column: 2, row: 1)),
                .cellRef(CellRef(column: 2, row: 2))))
        ]
        for step in 0..<depth {
            cells.append((CellRef(column: 2, row: 4 + step),
                          .add(.cellRef(CellRef(column: 2, row: 3 + step)), .number(1.0))))
        }
        return cells
    }

    // MARK: - Path A — interpreted

    private func runInterpreted(depth: Int) throws -> [Double] {
        let names = NoNames()
        let random = Self.randomSource()
        let chain = Self.interpretedChain(depth: depth)
        var out: [Double] = []
        out.reserveCapacity(Self.trials)

        for _ in 0..<Self.trials {
            var cells = MutableCells()
            let d1 = try FormulaEvaluator.evaluate(Self.b1, cells: cells, names: names, random: random)
            cells.values[CellRef(column: 2, row: 1)] = d1
            let d2 = try FormulaEvaluator.evaluate(Self.b2, cells: cells, names: names, random: random)
            cells.values[CellRef(column: 2, row: 2)] = d2

            var last = CellValue.blank
            for (ref, ast) in chain {
                last = try FormulaEvaluator.evaluate(ast, cells: cells, names: names, random: random)
                cells.values[ref] = last
            }
            out.append(try Self.number(last))
        }
        return out
    }

    // MARK: - Path B — compiled

    private func runCompiled(depth: Int) throws -> (values: [Double], instructions: Int) {
        let names = NoNames()
        let random = Self.randomSource()
        let empty = MutableCells()

        let model = try MonteCarloExpressionModel { b in
            var e = b[0] * b[1]
            for _ in 0..<depth { e = e + 1.0 }
            return e
        }

        var out: [Double] = []
        out.reserveCapacity(Self.trials)

        for _ in 0..<Self.trials {
            let d1 = try Self.number(
                try FormulaEvaluator.evaluate(Self.b1, cells: empty, names: names, random: random))
            let d2 = try Self.number(
                try FormulaEvaluator.evaluate(Self.b2, cells: empty, names: names, random: random))
            out.append(try model.evaluate(inputs: [d1, d2]))
        }
        return (out, model.instructionCount())
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// A fixed-point decimal, without a C format string.
    ///
    /// `String(format:)` is a `c-style-format-string` finding under the safety
    /// auditor — the format and the arguments are unrelated at compile time, so a
    /// mismatched specifier is a runtime surprise. `FormatStyle` knows the type.
    private static func fixed(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return value > 0 ? "inf" : "-inf" }
        return value.formatted(.number.precision(.fractionLength(places)).grouping(.never))
    }

    /// Right-aligns into a column, for the table above.
    private static func rightAligned(_ text: String, width: Int) -> String {
        guard text.count < width else { return text }
        return String(repeating: " ", count: width - text.count) + text
    }

    // MARK: - The measurement

    func testInterpretedAndCompiledAgreeAtEveryDepth() throws {
        for depth in [0, 10, 100] {
            let interpreted = try runInterpreted(depth: depth)
            let compiled = try runCompiled(depth: depth)
            XCTAssertEqual(interpreted, compiled.values,
                           "depth \(depth): the paths disagree — the lowering is wrong, not the randomness")
        }
    }

    func testPropagationCostRatioIsRecorded() throws {
        let depths = [0, 10, 50, 100, 250, 500]
        var rows: [(depth: Int, ops: Int, a: Double, b: Double)] = []

        for depth in depths {
            let sa = ContinuousClock.now
            _ = try runInterpreted(depth: depth)
            let ea = Self.seconds(ContinuousClock.now - sa)

            let sb = ContinuousClock.now
            let c = try runCompiled(depth: depth)
            let eb = Self.seconds(ContinuousClock.now - sb)

            rows.append((depth, c.instructions, ea, eb))
        }

        // Slope between the shallowest and deepest run. The intercept is the shared
        // sampling cost, which cancels; what is left is the marginal cost of one
        // propagation operation on each path.
        guard let first = rows.first, let last = rows.last, last.depth > first.depth else {
            XCTFail("need at least two depths"); return
        }
        let steps = Double(last.depth - first.depth)
        let perOpA = (last.a - first.a) / steps / Double(Self.trials) * 1e9
        let perOpB = (last.b - first.b) / steps / Double(Self.trials) * 1e9
        let marginalRatio = perOpB > 0 ? perOpA / perOpB : .infinity

        var table = ""
        for r in rows {
            let whole = r.b > 0 ? r.a / r.b : 0
            table += "  "
                + Self.rightAligned(r.depth.formatted(.number.grouping(.never)), width: 5)
                + "  "
                + Self.rightAligned(r.ops.formatted(.number.grouping(.never)), width: 6)
                + "   "
                + Self.rightAligned(Self.fixed(r.a, places: 4) + "s", width: 8)
                + "  "
                + Self.rightAligned(Self.fixed(r.b, places: 4) + "s", width: 8)
                + "   "
                + Self.rightAligned(Self.fixed(whole, places: 2) + "x", width: 6)
                + "\n"
        }

        print("""

        ── Phase 0: propagation cost ──────────────────────────────
          trials \(Self.trials), seed \(Self.seed), \(depths.count) depths

          depth   instrs   interp     compiled   whole-run
        \(table)
          marginal cost of ONE propagation op, per trial:
            interpreted   \(Self.fixed(perOpA, places: 1)) ns
            compiled      \(Self.fixed(perOpB, places: 1)) ns
            ratio         \(Self.fixed(marginalRatio, places: 1))x

          The whole-run column is diluted by the shared sampling cost,
          which is identical on both paths and cancels in the slope.
          The marginal ratio is the number Phase 4 is ordered by.
        ───────────────────────────────────────────────────────────

        """)
    }
}
