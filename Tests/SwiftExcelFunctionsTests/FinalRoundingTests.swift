import Foundation
import SwiftExcelCore
import SwiftXLSX
import XCTest
@testable import SwiftExcelFunctions

/// Excel's correction to a final addition or subtraction.
///
/// **Every expected value here was read out of Excel**, not derived. Twenty formulas were put
/// to it and its answers recorded; these are those answers. That matters more than usual,
/// because the rule is not the one anybody guesses — it is about the *ratio* of the result to
/// its operands, and it applies to the last operation only.
final class FinalRoundingTests: XCTestCase {

    private struct NoCells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func evaluate(_ formula: String) throws -> CellValue {
        try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                      cells: NoCells(), names: NoNames())
    }

    private func number(_ formula: String) throws -> Double {
        guard case .number(let value) = try evaluate(formula) else {
            XCTFail("\(formula) did not produce a number"); return .nan
        }
        return value
    }

    // MARK: - Cancellation at the root

    func testACancelledSubtractionIsZero() throws {
        XCTAssertEqual(try number("0.1+0.2-0.3"), 0)
        XCTAssertEqual(try number("1.1-1-0.1"), 0)
        XCTAssertEqual(try number("0.5-0.4-0.1"), 0)
    }

    /// The rule is about the ratio, not the size.
    ///
    /// `5.8e-12` is a hundred thousand times *larger* than a residue that gets corrected away,
    /// and it survives — because against operands of about `0.1` it is a real difference.
    func testARealDifferenceSurvivesHoweverSmall() throws {
        XCTAssertEqual(try number("100000.1-100000-0.1"), 5.820760540231618e-12)
        XCTAssertEqual(try number("10000000.1-10000000-0.1"), -3.7252903539730653e-10)
        XCTAssertEqual(try number("1-0.9999999999999"), 1.000310945187266e-13)
    }

    /// A small number that no cancellation produced is left alone.
    func testSmallnessAloneIsNotCorrected() throws {
        XCTAssertEqual(try number("0.00000000001"), 1e-11)
        XCTAssertEqual(try number("0.00000000001*1"), 1e-11)
        XCTAssertEqual(try number("0.00000000001/10"), 1e-12)
    }

    // MARK: - Only the last operation

    /// The case that rules out correcting every addition as it happens.
    ///
    /// The same subtraction is corrected alone in a cell and not corrected inside a product.
    func testAnInnerCancellationKeepsItsResidue() throws {
        XCTAssertEqual(try number("(0.1+0.2-0.3)*1"), 5.551115123125783e-17)
        XCTAssertEqual(try number("(0.1+0.2-0.3)*1000000"), 5.551115123125783e-11)
        // Adding nothing afterwards makes the residue the operand, so there is no scale for
        // it to be negligible against.
        XCTAssertEqual(try number("(0.1+0.2-0.3)+0"), 5.551115123125783e-17)
    }

    // MARK: - Comparison is subtraction

    /// The famous pair, and they are not inconsistent.
    ///
    /// `0.1+0.2` and `0.3` differ by 1.85e-16 *of themselves*, so they are equal. The residue
    /// and zero differ by the whole of the residue, so they are not.
    func testComparisonAppliesTheSameRule() throws {
        XCTAssertEqual(try evaluate("IF(0.1+0.2=0.3,\"equal\",\"not equal\")"), .text("equal"))
        XCTAssertEqual(try evaluate("IF(0.1+0.2-0.3=0,\"zero\",\"not zero\")"), .text("not zero"))
        XCTAssertEqual(try evaluate("(0.1+0.2-0.3)=0"), .bool(false))
    }

    /// A comparison is corrected wherever it sits, unlike an addition.
    ///
    /// In `IF(0.1+0.2=0.3, …)` the comparison is nested inside a function and still applies
    /// the rule — which is how Excel behaves, and why the correction cannot simply be a
    /// property of the root node.
    func testANestedComparisonIsStillCorrected() throws {
        XCTAssertEqual(try evaluate("IF(0.1+0.2=0.3,1,2)"), .number(1))
        XCTAssertEqual(try evaluate("IF(0.1+0.2<>0.3,1,2)"), .number(2))
    }

    /// Ordering obeys it too, since `<` and `>` subtract as `=` does.
    func testOrderingUsesTheCorrectedDifference() throws {
        XCTAssertEqual(try evaluate("(0.1+0.2)>0.3"), .bool(false))
        XCTAssertEqual(try evaluate("(0.1+0.2)>=0.3"), .bool(true))
        XCTAssertEqual(try evaluate("(0.1+0.2)<0.3"), .bool(false))
    }

    /// Everything else sees the uncorrected value.
    ///
    /// `SIGN` is the clearest demonstration: Excel returns 1, so the residue is genuinely
    /// there — the correction is applied when the value becomes the cell's, not before.
    func testOtherFunctionsSeeTheResidue() throws {
        XCTAssertEqual(try number("SIGN(0.1+0.2-0.3)"), 1)
    }

    // MARK: - The rule itself

    func testTheThresholdIsRelative() {
        // Negligible against 1, so nothing.
        XCTAssertEqual(ExcelFinalRounding.corrected(1e-16, lhs: 1, rhs: 1), 0)
        // The same number against operands of its own size is the whole of them.
        XCTAssertEqual(ExcelFinalRounding.corrected(1e-16, lhs: 1e-16, rhs: 0), 1e-16)
        // Above the threshold at any scale. Against operands of a million the threshold is
        // 1e-9, so 1e-8 is ten times too big to be negligible and survives.
        XCTAssertEqual(ExcelFinalRounding.corrected(1e-13, lhs: 1, rhs: 1), 1e-13)
        XCTAssertEqual(ExcelFinalRounding.corrected(1e-8, lhs: 1e6, rhs: 1e6), 1e-8)
        // Below it at the same scale, and it goes.
        XCTAssertEqual(ExcelFinalRounding.corrected(1e-10, lhs: 1e6, rhs: 1e6), 0)
        // The larger operand sets the scale, not the smaller.
        XCTAssertEqual(ExcelFinalRounding.corrected(1e-10, lhs: 1e-6, rhs: 1e6), 0)
    }

    /// Zero operands leave the result alone rather than making everything negligible.
    func testAZeroScaleCorrectsNothing() {
        XCTAssertEqual(ExcelFinalRounding.corrected(5, lhs: 0, rhs: 0), 5)
        XCTAssertEqual(ExcelFinalRounding.corrected(0, lhs: 0, rhs: 0), 0)
    }
}
