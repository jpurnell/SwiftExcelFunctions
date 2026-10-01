import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// A **negative base raised to a reciprocal-odd power** is the real root, not `#NUM!`.
///
/// ## The measurement
///
/// `GoldmanSachs_CMCSAModel_Jul_28_2017.xlsx` computes a five-year CAGR the defensive way:
///
/// ```
/// IF(ISNUMBER((BC49/AP49)^(1/5)-1), (BC49/AP49)^(1/5)-1, "NM")
/// ```
///
/// `BC49` is `22.454110930290827` and `AP49` is `-319`, so the ratio is
/// `-0.0703891251733255` — a negative base under a fifth root. Excel's cached answer is
/// **`-1.5881675174209027`**, and that is exactly `-(0.0703891251733255 ^ 0.2) - 1`: Excel
/// took the real fifth root and kept the sign.
///
/// `pow(-0.07…, 0.2)` in C is `NaN`, so this answered `#NUM!`, `ISNUMBER` said false, and the
/// cell read `"NM"` — a plausible-looking "not meaningful" that was ours and not the model's.
///
/// ## The rule, and its edge
///
/// Only an **odd** root has a real value for a negative base: there is no real square root of
/// `-4`, and `(-4)^0.5` stays `#NUM!`. The test is on the exponent's reciprocal, which has to
/// be an odd integer — and `1/5` is not exactly representable in binary, so `1/0.2` comes back
/// as `4.999999999999999` and the comparison needs a tolerance rather than an equality.
@Suite struct NegativeBaseRootTests {

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
                                      cells: NoCells(), names: NoNames(), inSheet: "Sheet1")
    }

    private func number(_ formula: String) throws -> Double? {
        guard case .number(let value) = try evaluate(formula) else { return nil }
        return value
    }

    /// **The corpus cell, to the digit.**
    @Test func theCorpusCagr() throws {
        let ours = try #require(try number("(22.454110930290827/-319)^(1/5)-1"),
                                "Excel has a number here, not #NUM!")
        #expect(ours.isClose(to: -1.5881675174209027, within: 1e-12))
    }

    @Test func oddRootsOfNegativesAreReal() throws {
        #expect(try abs(#require(try number("(-8)^(1/3)")) - -2) <= 1e-12)
        #expect(try abs(#require(try number("(-32)^(1/5)")) - -2) <= 1e-12)
        #expect(try abs(#require(try number("(-1)^(1/7)")) - -1) <= 1e-12)
    }

    /// **An even root of a negative has no real value** and stays `#NUM!`.
    @Test func evenRootsOfNegativesStayNum() throws {
        #expect(try evaluate("(-4)^(1/2)") == .error(.num))
        #expect(try evaluate("(-16)^(1/4)") == .error(.num))
    }

    /// Nor does an exponent that is not a reciprocal integer become one.
    @Test func anArbitraryFractionalExponentStaysNum() throws {
        #expect(try evaluate("(-8)^0.7") == .error(.num))
        #expect(try evaluate("(-8)^(2/3)") == .error(.num), "a real value exists but Excel does not compute it, and neither do we")
    }

    /// Integer exponents and positive bases are untouched.
    @Test func theOrdinaryCasesAreUnchanged() throws {
        #expect(try abs(#require(try number("(-2)^3")) - -8) <= 1e-12)
        #expect(try abs(#require(try number("(-2)^2")) - 4) <= 1e-12)
        #expect(try abs(#require(try number("8^(1/3)")) - 2) <= 1e-12)
        #expect(try abs(#require(try number("0^3")) - 0) <= 1e-12)
    }

    /// `POWER` is the same operator spelled differently and answers the same.
    @Test func powerAgrees() throws {
        #expect(try abs(#require(try number("POWER(-32,1/5)")) - -2) <= 1e-12)
    }
}
