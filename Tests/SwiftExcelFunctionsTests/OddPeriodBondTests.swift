import Foundation
import Testing
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// Bonds with an irregular first or last coupon period.
///
/// Microsoft publishes a worked example for each of the four, and those are the expectations
/// here. The pair tests matter as much: a price function and its yield function must invert
/// each other, which catches an error in either that a single published number would not.
@Suite struct OddPeriodBondTests {

    private struct Cells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet sheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet sheet: String) -> [CellValue] { [] }
    }
    private struct Names: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func call(_ name: String, _ args: [FormulaAST]) throws -> CellValue {
        try FormulaEvaluator.evaluate(
            .function(name, args), cells: Cells(), names: Names(), functions: .builtin)
    }

    private func day(_ year: Int, _ month: Int, _ d: Int) -> FormulaAST {
        .function("DATE", [.number(Double(year)), .number(Double(month)), .number(Double(d))])
    }

    private func value(_ result: CellValue) -> Double? {
        if case .number(let n) = result { return n }
        return nil
    }

    // MARK: - Odd last period

    /// Microsoft: settlement 2008-02-07, maturity 2008-06-15, last interest 2007-10-15,
    /// rate 3.75%, yield 4.05%, redemption 100, frequency 2, basis 0 → 99.878286.
    @Test func oddLPrice() throws {
        guard let price = value(try call("ODDLPRICE", [
            day(2008, 2, 7), day(2008, 6, 15), day(2007, 10, 15),
            .number(0.0375), .number(0.0405), .number(100), .number(2), .number(0),
        ])) else { Issue.record("expected a number"); return }
        #expect(abs(price - 99.878286) <= 1e-4)
    }

    /// Microsoft: the same bond at 99.878286 yields 4.05%.
    @Test func oddLYield() throws {
        guard let yield = value(try call("ODDLYIELD", [
            day(2008, 2, 7), day(2008, 6, 15), day(2007, 10, 15),
            .number(0.0375), .number(99.878286), .number(100), .number(2), .number(0),
        ])) else { Issue.record("expected a number"); return }
        #expect(abs(yield - 0.0405) <= 1e-5)
    }

    /// The pair invert each other across a range of yields, not only at the published one.
    @Test func theOddLastPairInvert() throws {
        for yield in [0.01, 0.0405, 0.08, 0.15] {
            guard let price = value(try call("ODDLPRICE", [
                day(2008, 2, 7), day(2008, 6, 15), day(2007, 10, 15),
                .number(0.0375), .number(yield), .number(100), .number(2), .number(0),
            ])) else { Issue.record("expected a price"); return }

            guard let back = value(try call("ODDLYIELD", [
                day(2008, 2, 7), day(2008, 6, 15), day(2007, 10, 15),
                .number(0.0375), .number(price), .number(100), .number(2), .number(0),
            ])) else { Issue.record("expected a yield"); return }
            #expect(abs(back - yield) <= 1e-9, "round trip at \(yield)")
        }
    }

    // MARK: - Odd first period

    /// Microsoft: settlement 2008-11-11, maturity 2021-03-01, issue 2008-10-15,
    /// first coupon 2009-03-01, rate 7.85%, yield 6.25%, redemption 100, frequency 2,
    /// basis 1 → 113.597717.
    @Test func oddFPrice() throws {
        guard let price = value(try call("ODDFPRICE", [
            day(2008, 11, 11), day(2021, 3, 1), day(2008, 10, 15), day(2009, 3, 1),
            .number(0.0785), .number(0.0625), .number(100), .number(2), .number(1),
        ])) else { Issue.record("expected a number"); return }
        #expect(abs(price - 113.597717) <= 1e-4)
    }

    /// Microsoft: the same bond at 113.597717 yields 6.25%.
    @Test func oddFYield() throws {
        guard let yield = value(try call("ODDFYIELD", [
            day(2008, 11, 11), day(2021, 3, 1), day(2008, 10, 15), day(2009, 3, 1),
            .number(0.0785), .number(113.597717), .number(100), .number(2), .number(1),
        ])) else { Issue.record("expected a number"); return }
        #expect(abs(yield - 0.0625) <= 1e-6)
    }

    /// **The pair invert each other exactly**, whatever the absolute figures.
    ///
    /// This is the stronger test of the two. `ODDFYIELD` searches for the yield whose price
    /// matches, so a round trip pins the search and the pricing against each other to the
    /// tolerance of the search — a defect in either shows up here, where a single published
    /// number can be matched by a wrong implementation that is wrong twice.
    @Test func theOddFirstPairInvert() throws {
        for yield in [0.02, 0.0625, 0.09] {
            guard let price = value(try call("ODDFPRICE", [
                day(2008, 11, 11), day(2021, 3, 1), day(2008, 10, 15), day(2009, 3, 1),
                .number(0.0785), .number(yield), .number(100), .number(2), .number(1),
            ])) else { Issue.record("expected a price"); return }

            guard let back = value(try call("ODDFYIELD", [
                day(2008, 11, 11), day(2021, 3, 1), day(2008, 10, 15), day(2009, 3, 1),
                .number(0.0785), .number(price), .number(100), .number(2), .number(1),
            ])) else { Issue.record("expected a yield"); return }
            #expect(abs(back - yield) <= 1e-6, "round trip at \(yield)")
        }
    }

    /// Price falls as yield rises, which is the one property a bond price cannot violate.
    @Test func priceFallsAsYieldRises() throws {
        var previous = Double.infinity
        for yield in [0.01, 0.03, 0.05, 0.07, 0.09, 0.12] {
            guard let price = value(try call("ODDFPRICE", [
                day(2008, 11, 11), day(2021, 3, 1), day(2008, 10, 15), day(2009, 3, 1),
                .number(0.0785), .number(yield), .number(100), .number(2), .number(1),
            ])) else { Issue.record("expected a price"); return }
            #expect(price < previous, "price must fall as yield rises")
            previous = price
        }
    }

    // MARK: - Refusals

    @Test func datesMustBeInOrder() throws {
        #expect(try call("ODDLPRICE", [
            day(2008, 6, 15), day(2008, 2, 7), day(2007, 10, 15),
            .number(0.0375), .number(0.0405), .number(100), .number(2),
        ]) == .error(.num))
    }

    /// Excel's frequencies are annual, semi-annual and quarterly, and nothing else.
    @Test func anUnknownFrequencyIsRefused() throws {
        #expect(try call("ODDLPRICE", [
            day(2008, 2, 7), day(2008, 6, 15), day(2007, 10, 15),
            .number(0.0375), .number(0.0405), .number(100), .number(12),
        ]) == .error(.value))
    }

    @Test func anUnknownBasisIsRefused() throws {
        #expect(try call("ODDFPRICE", [
            day(2008, 11, 11), day(2021, 3, 1), day(2008, 10, 15), day(2009, 3, 1),
            .number(0.0785), .number(0.0625), .number(100), .number(2), .number(9),
        ]) == .error(.value))
    }

    @Test func anErrorArgumentPropagates() throws {
        #expect(try call("ODDLYIELD", [
            day(2008, 2, 7), day(2008, 6, 15), day(2007, 10, 15),
            .error(.na), .number(99.8), .number(100), .number(2),
        ]) == .error(.na))
    }
}
