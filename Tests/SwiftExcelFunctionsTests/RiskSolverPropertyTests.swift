import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// The property functions attached to a `Psi*` distribution.
///
/// ## The defect these close was not a gap
///
/// None of `PsiTruncate`, `PsiShift`, `PsiUnits` and the rest was registered, and an
/// unregistered name fails the **enclosing** call: `PsiNormal(10, 2, PsiTruncate(5, 15))`
/// produced no number at all rather than an untruncated one. From the coverage matrix this
/// looked like twenty-six rows of completeness work. In a workbook it was a cell that did not
/// evaluate.
///
/// `testAnAttachedPropertyUsedToFailTheWholeCall` is that case, stated as a test.
@Suite struct RiskSolverPropertyTests {

    private struct NoCells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
    }
    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    /// Draws at a chosen probability, so every assertion is a quantile and not a sample.
    private struct At: RandomSource {
        let p: Double
        func nextUniform() -> Double { p }
        func nextInteger(below bound: Int) -> Int {
            bound > 0 ? Swift.min(Int(p * Double(bound)), bound - 1) : 0
        }
    }

    private func draw(_ formula: String, at p: Double) throws -> CellValue {
        try FormulaEvaluator.evaluate(
            try FormulaParser.parse(formula), cells: NoCells(), names: NoNames(),
            random: At(p: p))
    }

    private func number(_ formula: String, at p: Double) throws -> Double {
        let answer = try draw(formula, at: p)
        guard case .number(let d) = answer else {
            Issue.record("\(formula) at \(p) gave \(answer)"); return .nan
        }
        return d
    }

    // MARK: - The defect

    /// An attached property used to fail the cell outright, not merely be ignored.
    @Test func anAttachedPropertyUsedToFailTheWholeCall() throws {
        for formula in ["PsiUniform(0, 10, PsiTruncate(2, 8))",
                        "PsiUniform(0, 10, PsiShift(5))",
                        "PsiUniform(0, 10, PsiUnits(\"days\"))",
                        "PsiUniform(0, 10, PsiCategory(\"Demand\"))",
                        "PsiUniform(0, 10, PsiStatic(TRUE))",
                        "PsiUniform(0, 10, PsiLock())",
                        "PsiUniform(0, 10, PsiCollect(TRUE))",
                        "PsiUniform(0, 10, PsiTruncateP(0.1, 0.9))"] {
            let answer = try draw(formula, at: 0.5)
            #expect(answer.isNumeric, "\(formula) gave \(answer), expected a number")
        }
    }

    // MARK: - Shift

    /// The whole distribution slides; the spread is untouched.
    @Test func shiftMovesEveryDraw() throws {
        for p in [0.1, 0.5, 0.9] {
            let plain = try number("PsiUniform(0, 10)", at: p)
            let moved = try number("PsiUniform(0, 10, PsiShift(100))", at: p)
            #expect(abs(moved - (plain + 100)) <= 1e-9)
        }
    }

    // MARK: - Truncation

    /// **Rescaled, not clamped.** The kept probability is stretched back over (0, 1).
    ///
    /// A clamp would pile every excluded draw onto an endpoint: `p = 0` and `p = 0.1` would
    /// both answer 2, and the run would show a spike where the model meant a bound. Rescaling
    /// keeps the truncated distribution a distribution.
    @Test func truncationRescalesRatherThanClamps() throws {
        // Uniform on [0, 10] truncated to [2, 8] is uniform on [2, 8].
        #expect(try abs(number("PsiUniform(0, 10, PsiTruncate(2, 8))", at: 0.0) - 2) <= 1e-6)
        #expect(try abs(number("PsiUniform(0, 10, PsiTruncate(2, 8))", at: 0.5) - 5) <= 1e-6)
        #expect(try abs(number("PsiUniform(0, 10, PsiTruncate(2, 8))", at: 0.999999) - 8) <= 1e-4)
        // A clamp would have answered 2 at both of these. Rescaling does not.
        #expect(try abs(number("PsiUniform(0, 10, PsiTruncate(2, 8))", at: 0.1) - number("PsiUniform(0, 10, PsiTruncate(2, 8))", at: 0.0)) > 1e-6)
    }

    /// Truncating by probability keeps the stated middle of the distribution.
    @Test func truncationByProbability() throws {
        // The middle 80% of uniform [0, 10] is [1, 9].
        #expect(try abs(number("PsiUniform(0, 10, PsiTruncateP(0.1, 0.9))", at: 0.0) - 1) <= 1e-9)
        #expect(try abs(number("PsiUniform(0, 10, PsiTruncateP(0.1, 0.9))", at: 0.5) - 5) <= 1e-9)
    }

    /// One-sided truncation leaves the other end alone.
    ///
    /// The omitted end arrives as a blank, and reading a blank as zero would bound a cost or
    /// a duration at the origin — which looks entirely plausible and is not what was asked.
    @Test func oneSidedTruncation() throws {
        // Lower bound only: [5, 10].
        #expect(try abs(number("PsiUniform(0, 10, PsiTruncate(5,))", at: 0.0) - 5) <= 1e-6)
        #expect(try abs(number("PsiUniform(0, 10, PsiTruncate(5,))", at: 0.5) - 7.5) <= 1e-6)
    }

    // MARK: - Order

    /// **Truncation applies to the untouched distribution; the shift comes after.**
    ///
    /// `PsiUniform(0, 10, PsiTruncate(2, 8), PsiShift(100))` draws in [2, 8] and lands in
    /// [102, 108]. Applying the shift first would compare shifted values against unshifted
    /// bounds — 102 is well past 8 — and truncate almost everything away, silently, because
    /// the result is still a number.
    @Test func truncationHappensBeforeTheShift() throws {
        let formula = "PsiUniform(0, 10, PsiTruncate(2, 8), PsiShift(100))"
        #expect(try abs(number(formula, at: 0.5) - 105) <= 1e-6)
        #expect(try abs(number(formula, at: 0.0) - 102) <= 1e-6)
    }

    // MARK: - Markers

    /// A label does not become a parameter.
    ///
    /// `attached` appends anything it does not recognise to the parameter list, so an
    /// unrecognised property would be read as a distribution parameter — which for a family
    /// whose arity varies is how a label silently becomes a shape.
    @Test func labelsAreNotParameters() throws {
        let plain = try number("PsiUniform(0, 10)", at: 0.3)
        for property in ["PsiUnits(\"days\")", "PsiCategory(\"Demand\")",
                         "PsiName(\"Demand\")", "PsiStatic(TRUE)", "PsiLock()",
                         "PsiCollect(TRUE)"] {
            #expect(try abs(number("PsiUniform(0, 10, \(property))", at: 0.3) - plain) <= 1e-12, "\(property)")
        }
    }

    /// The base case still works beside the new properties.
    @Test func theBaseCaseIsUnaffected() throws {
        let answer = try FormulaEvaluator.evaluate(
            try FormulaParser.parse("PsiUniform(0, 10, PsiBaseCase(7), PsiShift(1))"),
            cells: NoCells(), names: NoNames())
        #expect(answer == .number(7), "with no randomness, the base case answers")
    }
}
