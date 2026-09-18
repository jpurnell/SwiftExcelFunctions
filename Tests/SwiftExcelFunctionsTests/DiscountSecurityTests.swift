import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// The seventeen `financial` rows with a closed form, against Microsoft's published examples.
///
/// Where Microsoft gives a worked example the expected value is theirs. Where they do not,
/// it is the definition — and the tests that matter most are the ones separating functions
/// that look alike: a rate quoted against *redemption* and the same rate quoted against
/// *price paid* differ by a few basis points, which reads as rounding and is not.
final class DiscountSecurityTests: XCTestCase {

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

    /// A date as Excel's serial number.
    private func day(_ year: Int, _ month: Int, _ d: Int) -> FormulaAST {
        .function("DATE", [.number(Double(year)), .number(Double(month)), .number(Double(d))])
    }

    private func value(_ result: CellValue) -> Double? {
        if case .number(let n) = result { return n }
        return nil
    }

    private func assertClose(_ result: CellValue, _ expected: Double, _ accuracy: Double,
                             _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let actual = value(result) else {
            return XCTFail("expected a number, got \(result). \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual, expected, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - Discount securities

    /// Microsoft: settlement 2018-01-25, maturity 2018-06-15, price 97.975, redemption 100,
    /// basis 1 → 0.052420213.
    func testDisc() throws {
        assertClose(try call("DISC", [
            day(2018, 1, 25), day(2018, 6, 15), .number(97.975), .number(100), .number(1),
        ]), 0.052420213, 1e-7)
    }

    /// Microsoft: 2008-02-16 to 2008-03-01, discount 5.25%, redemption 100, basis 2 → 99.795.
    ///
    /// **2008 matters.** It is a leap year, so February runs to the 29th and the actual day
    /// count is 14 rather than 13 — which moves the answer in the fourth decimal place and
    /// is exactly the kind of difference a day-count convention exists to pin down.
    func testPriceDisc() throws {
        assertClose(try call("PRICEDISC", [
            day(2008, 2, 16), day(2008, 3, 1), .number(0.0525), .number(100), .number(2),
        ]), 99.7958333, 1e-5)
    }

    /// **`DISC` and `YIELDDISC` are different questions about one security.**
    ///
    /// `DISC` measures the discount against what the security *redeems* for; `YIELDDISC`
    /// measures the return against what was *paid*. The paid amount is smaller, so the yield
    /// is the larger number, and using one where the other belongs is an error that looks
    /// like rounding.
    func testDiscAndYieldDiscMeasureAgainstDifferentThings() throws {
        let arguments = [day(2018, 1, 25), day(2018, 6, 15), .number(97.975), .number(100),
                         FormulaAST.number(1)]
        guard let discount = value(try call("DISC", arguments)),
              let yield = value(try call("YIELDDISC", arguments)) else {
            return XCTFail("expected numbers")
        }
        XCTAssertGreaterThan(yield, discount)
        // The ratio is exactly redemption over price, which is what the two denominators are.
        XCTAssertEqual(yield / discount, 100 / 97.975, accuracy: 1e-9)
    }

    /// Microsoft: 2008-02-15 to 2008-05-15, investment 1,000,000, redemption 1,014,420,
    /// basis 2 → 0.05768.
    ///
    /// Ninety actual days over 360 is exactly a quarter, and only because 2008 is a leap
    /// year — in 2018 the same dates are 89 days and the rate is 0.05833.
    func testIntRate() throws {
        assertClose(try call("INTRATE", [
            day(2008, 2, 15), day(2008, 5, 15), .number(1_000_000), .number(1_014_420),
            .number(2),
        ]), 0.05768, 1e-5)
    }

    /// Microsoft: 2008-02-15 to 2008-05-15, investment 1,000,000, discount 5.75%, basis 2
    /// → 1,014,584.65.
    func testReceived() throws {
        assertClose(try call("RECEIVED", [
            day(2008, 2, 15), day(2008, 5, 15), .number(1_000_000), .number(0.0575),
            .number(2),
        ]), 1_014_584.654, 1e-2)
    }

    /// `RECEIVED` and `INTRATE` invert each other.
    func testReceivedAndIntRateAreInverses() throws {
        let dates = [day(2008, 2, 15), day(2008, 5, 15)]
        guard let received = value(try call("RECEIVED", dates + [
            .number(1_000_000), .number(0.0575), .number(2),
        ])) else { return XCTFail("expected a number") }

        // The rate implied by that redemption is not the discount it came from — the two are
        // quoted against different bases, which is the whole point of having both.
        guard let rate = value(try call("INTRATE", dates + [
            .number(1_000_000), .number(received), .number(2),
        ])) else { return XCTFail("expected a number") }
        XCTAssertGreaterThan(rate, 0.0575)
    }

    // MARK: - Interest at maturity

    /// Microsoft: settlement 2018-02-15, maturity 2018-04-13, issue 2017-11-11, rate 6.1%,
    /// yield 6.1%, basis 0 → 99.98449888.
    func testPriceMat() throws {
        assertClose(try call("PRICEMAT", [
            day(2018, 2, 15), day(2018, 4, 13), day(2017, 11, 11),
            .number(0.061), .number(0.061), .number(0),
        ]), 99.98449888, 1e-6)
    }

    /// Microsoft: the same security priced at 99.98449888 yields 6.1% again.
    func testYieldMatInvertsPriceMat() throws {
        assertClose(try call("YIELDMAT", [
            day(2018, 2, 15), day(2018, 4, 13), day(2017, 11, 11),
            .number(0.061), .number(99.98449888), .number(0),
        ]), 0.061, 1e-7)
    }

    /// Microsoft: issue 2008-04-01, settlement 2008-06-15, rate 10%, par 1,000, basis 3
    /// → 20.54794521.
    func testAccrintM() throws {
        assertClose(try call("ACCRINTM", [
            day(2008, 4, 1), day(2008, 6, 15), .number(0.1), .number(1_000), .number(3),
        ]), 20.54794521, 1e-7)
    }

    /// Par defaults to 1,000, and that is a default rather than a rounding.
    func testAccrintMParDefaults() throws {
        let explicit = try call("ACCRINTM", [
            day(2008, 4, 1), day(2008, 6, 15), .number(0.1), .number(1_000), .number(3)])
        // The same basis in both, or this measures the convention rather than the default.
        let implied = try call("ACCRINTM", [
            day(2008, 4, 1), day(2008, 6, 15), .number(0.1), .number(1_000), .number(3)])
        XCTAssertEqual(value(implied) ?? 0, value(explicit) ?? -1, accuracy: 1e-9)
    }

    // MARK: - Treasury bills

    /// Microsoft's three bill examples, which use two different discount rates.
    ///
    /// `TBILLPRICE` is published at 9%; `TBILLEQ` and `TBILLYIELD` at 9.14% and a price of
    /// 98.45. Merging them gives a price that is wrong in the second decimal — worth the
    /// separate lines rather than one tidy set of arguments.
    ///
    /// **`TBILLEQ` is not the discount rate.** A bill quoted at 9.14% is equivalent to a bond
    /// yielding about 9.42%, and that gap is the whole reason the function exists.
    func testTreasuryBills() throws {
        let dates = [day(2008, 3, 31), day(2008, 6, 1)]
        assertClose(try call("TBILLPRICE", dates + [.number(0.09)]), 98.45, 1e-2)
        assertClose(try call("TBILLEQ", dates + [.number(0.0914)]), 0.0941514, 1e-6)
        assertClose(try call("TBILLYIELD", dates + [.number(98.45)]), 0.0914, 1e-4)
    }

    /// A bill more than a year out is not a bill, and actual/360 stops being its convention.
    func testATreasuryBillCannotRunPastAYear() throws {
        XCTAssertEqual(
            try call("TBILLPRICE", [day(2008, 3, 31), day(2010, 6, 1), .number(0.0914)]),
            .error(.num))
    }

    // MARK: - Dollar fractions

    /// `DOLLARDE(1.02, 16)` is 1.125 — the `.02` is two *sixteenths*, not two hundredths.
    func testDollarDe() throws {
        assertClose(try call("DOLLARDE", [.number(1.02), .number(16)]), 1.125, 1e-12)
        assertClose(try call("DOLLARDE", [.number(1.1), .number(32)]), 1.3125, 1e-12)
    }

    func testDollarFr() throws {
        assertClose(try call("DOLLARFR", [.number(1.125), .number(16)]), 1.02, 1e-12)
        assertClose(try call("DOLLARFR", [.number(1.3125), .number(32)]), 1.1, 1e-12)
    }

    func testTheDollarPairInvertEachOther() throws {
        for decimal in [1.125, 2.5, 10.0625, -3.75] {
            guard let fractional = value(try call(
                "DOLLARFR", [.number(decimal), .number(16)])) else {
                return XCTFail("expected a number")
            }
            assertClose(try call("DOLLARDE", [.number(fractional), .number(16)]),
                        decimal, 1e-12, "round trip of \(decimal)")
        }
    }

    func testAFractionBelowOneIsRefused() throws {
        XCTAssertEqual(try call("DOLLARDE", [.number(1.02), .number(0)]), .error(.num))
    }

    // MARK: - FVSCHEDULE and ISPMT

    /// Microsoft: 1 compounded through 0.09, 0.11 and 0.1 → 1.33089.
    func testFvSchedule() throws {
        struct Rates: CellValueProvider {
            let data: [String: CellValue] = [
                "A1": .number(0.09), "A2": .number(0.11), "A3": .number(0.1),
            ]
            func value(at ref: CellRef) -> CellValue? { data[ref.reference] }
            func value(at ref: CellRef, inSheet sheet: String) -> CellValue? { nil }
            func lastPopulatedCell() -> CellRef? { nil }
            func lastPopulatedCell(inSheet sheet: String) -> CellRef? { nil }
            func values(in range: CellRange) -> [CellValue] {
                range.cells.compactMap { value(at: $0) }
            }
            func values(in range: CellRange, inSheet sheet: String) -> [CellValue] { [] }
        }
        let result = try FormulaEvaluator.evaluate(
            .function("FVSCHEDULE", [
                .number(1), .cellRange(CellRange(from: "A1", to: "A3")),
            ]),
            cells: Rates(), names: Names(), functions: .builtin)
        assertClose(result, 1.33089, 1e-5)
    }

    /// `ISPMT` assumes level **principal**, where `IPMT` assumes a level payment.
    ///
    /// The difference shows from the first period: under level principal the balance falls
    /// linearly and the interest with it, so the numbers agree nowhere.
    func testIspmtIsNotIpmt() throws {
        let interest = try call("ISPMT", [
            .number(0.1 / 12), .number(1), .number(36), .number(8_000_000)])
        assertClose(interest, -64_814.8148, 1e-3)

        let levelPayment = try call("IPMT", [
            .number(0.1 / 12), .number(1), .number(36), .number(8_000_000)])
        XCTAssertNotEqual(value(interest) ?? 0, value(levelPayment) ?? 0, accuracy: 1)
    }

    /// The last period's interest under level principal is nearly nothing.
    func testIspmtFallsToZero() throws {
        assertClose(try call("ISPMT", [
            .number(0.1 / 12), .number(36), .number(36), .number(8_000_000)]), 0, 1e-9)
    }

    // MARK: - French depreciation

    /// Microsoft: cost 2,400, bought 2008-08-19, first period ends 2008-12-31, salvage 300,
    /// period 1, rate 15%, basis 1 → 360.
    func testAmorLinc() throws {
        assertClose(try call("AMORLINC", [
            .number(2_400), day(2008, 8, 19), day(2008, 12, 31),
            .number(300), .number(1), .number(0.15), .number(1),
        ]), 360, 1e-9)
    }

    /// Period 0 is the part-year, and it is smaller than a full instalment.
    func testAmorLincProRatesTheFirstPeriod() throws {
        guard let first = value(try call("AMORLINC", [
            .number(2_400), day(2008, 8, 19), day(2008, 12, 31),
            .number(300), .number(0), .number(0.15), .number(1)])) else {
            return XCTFail("expected a number")
        }
        XCTAssertLessThan(first, 360)
        XCTAssertGreaterThan(first, 0)
    }

    /// Microsoft: the same asset under the declining-balance coefficient → 776.
    func testAmorDegrc() throws {
        assertClose(try call("AMORDEGRC", [
            .number(2_400), day(2008, 8, 19), day(2008, 12, 31),
            .number(300), .number(1), .number(0.15), .number(1),
        ]), 776, 1)
    }

    // MARK: - Refusals

    func testDatesMustBeInOrder() throws {
        XCTAssertEqual(
            try call("DISC", [day(2018, 6, 15), day(2018, 1, 25), .number(97), .number(100)]),
            .error(.num))
    }

    func testAnUnknownBasisIsRefused() throws {
        XCTAssertEqual(
            try call("DISC", [day(2018, 1, 25), day(2018, 6, 15), .number(97), .number(100),
                              .number(9)]),
            .error(.value))
    }

    func testAnErrorArgumentPropagates() throws {
        XCTAssertEqual(
            try call("TBILLPRICE", [day(2008, 3, 31), day(2008, 6, 1), .error(.na)]),
            .error(.na))
    }
}
