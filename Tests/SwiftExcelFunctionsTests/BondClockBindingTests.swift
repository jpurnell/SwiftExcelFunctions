import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// Excel's bond functions, bound to BusinessMath's coupon grid.
///
/// Like every other binding suite here, these check the *binding* — Excel's
/// argument order, its frequency and basis codes, its errors — and not the
/// arithmetic, which is BusinessMath's and is tested there.
///
/// The values are Microsoft's own worked examples, quoted from the published
/// function reference. Where an example was not available, the expectation is
/// derived from a documented identity rather than from what this code returns.
final class BondClockBindingTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: [CellValue]) throws -> CellValue {
        let function = try XCTUnwrap(registry.function(named: name), "\(name) is not registered")
        return try function.evaluate(args)
    }

    private func number(_ name: String, _ args: [CellValue]) throws -> Double {
        let result = try call(name, args)
        guard case .number(let value) = result else {
            XCTFail("\(name) returned \(result), expected a number")
            return .nan
        }
        return value
    }

    /// An Excel date serial, so the tests read as dates rather than as five-digit numbers.
    private func serial(_ year: Int, _ month: Int, _ day: Int) -> CellValue {
        .number(BuiltinDateTimeFunctions.componentsToSerial(year: year, month: month, day: day))
    }

    // MARK: - Registration

    func testAllContainsEveryFunctionInTheGroup() {
        XCTAssertEqual(
            Set(BuiltinBondFunctions.all.map(\.name)),
            ["COUPDAYBS", "COUPDAYS", "COUPDAYSNC", "COUPNCD", "COUPNUM", "COUPPCD",
             "PRICE", "YIELD", "DURATION", "MDURATION", "ACCRINT"])
    }

    // MARK: - The coupon clock
    //
    // One settlement, one maturity, six functions. Microsoft documents all six
    // against the same pair of dates — settlement 25 January 2011, maturity
    // 15 November 2011, semi-annual, basis 1 — which makes them a single
    // consistency check as well as six separate ones.
    //
    // The grid runs back from maturity: 15 Nov 2011, 15 May 2011, 15 Nov 2010.
    // Settlement sits in the middle period.

    func testCoupdaybsMicrosoftExample() throws {
        XCTAssertEqual(
            try number("COUPDAYBS", [serial(2011, 1, 25), serial(2011, 11, 15), .number(2), .number(1)]),
            71, accuracy: 1e-9)
    }

    func testCoupdaysMicrosoftExample() throws {
        XCTAssertEqual(
            try number("COUPDAYS", [serial(2011, 1, 25), serial(2011, 11, 15), .number(2), .number(1)]),
            181, accuracy: 1e-9)
    }

    func testCoupdaysncMicrosoftExample() throws {
        XCTAssertEqual(
            try number("COUPDAYSNC", [serial(2011, 1, 25), serial(2011, 11, 15), .number(2), .number(1)]),
            110, accuracy: 1e-9)
    }

    func testCoupnumMicrosoftExample() throws {
        XCTAssertEqual(
            try number("COUPNUM", [serial(2011, 1, 25), serial(2011, 11, 15), .number(2), .number(1)]),
            2, accuracy: 1e-9)
    }

    func testCouppcdIsThePreviousCouponDate() throws {
        XCTAssertEqual(
            try number("COUPPCD", [serial(2011, 1, 25), serial(2011, 11, 15), .number(2), .number(1)]),
            BuiltinDateTimeFunctions.componentsToSerial(year: 2010, month: 11, day: 15),
            accuracy: 1e-9)
    }

    func testCoupncdIsTheNextCouponDate() throws {
        XCTAssertEqual(
            try number("COUPNCD", [serial(2011, 1, 25), serial(2011, 11, 15), .number(2), .number(1)]),
            BuiltinDateTimeFunctions.componentsToSerial(year: 2011, month: 5, day: 15),
            accuracy: 1e-9)
    }

    /// `A + DSC = E` — on the three bases where `E` is measured rather than assumed.
    ///
    /// Not a universal identity, and the exceptions are Excel's rather than ours.
    /// `COUPDAYS` answers a *nominal* period length on any basis with a fixed year:
    /// 360/frequency for bases 0, 2 and 4, and 365/frequency for basis 3. But
    /// `COUPDAYBS` and `COUPDAYSNC` count **actual** days on bases 1, 2 and 3.
    ///
    /// So bases 2 and 3 mix the two — 71 + 110 actual days against a nominal 180 or
    /// 182.5 — and the three values genuinely do not add up in Excel either. Bases
    /// 0, 1 and 4 are internally consistent and are what this asserts.
    ///
    /// Worth writing down, because "the three day counts must sum" is the obvious
    /// invariant to reach for and it would fail here for a reason that has nothing
    /// to do with the binding.
    func testTheThreeDayCountsAgreeWhereExcelMeasuresThePeriod() throws {
        for basis in [0, 1, 4] {
            let args: [CellValue] = [serial(2011, 1, 25), serial(2011, 11, 15), .number(2), .number(Double(basis))]
            let before = try number("COUPDAYBS", args)
            let toNext = try number("COUPDAYSNC", args)
            let inPeriod = try number("COUPDAYS", args)
            XCTAssertEqual(before + toNext, inPeriod, accuracy: 1e-9, "basis \(basis)")
        }
    }

    /// The nominal period lengths, stated for each basis so the paragraph above is
    /// pinned by a test rather than only by a comment.
    func testCoupdaysIsNominalExceptOnActualActual() throws {
        let dates: [CellValue] = [serial(2011, 1, 25), serial(2011, 11, 15), .number(2)]
        XCTAssertEqual(try number("COUPDAYS", dates + [.number(0)]), 180, accuracy: 1e-9)
        XCTAssertEqual(try number("COUPDAYS", dates + [.number(1)]), 181, accuracy: 1e-9)
        XCTAssertEqual(try number("COUPDAYS", dates + [.number(2)]), 180, accuracy: 1e-9)
        XCTAssertEqual(try number("COUPDAYS", dates + [.number(3)]), 182.5, accuracy: 1e-9)
        XCTAssertEqual(try number("COUPDAYS", dates + [.number(4)]), 180, accuracy: 1e-9)
    }

    /// Basis 0 is 30/360, so the period is a nominal 180 days however long the
    /// calendar says it is. This is the default, and the default is what the corpus
    /// uses, so it is worth pinning separately from basis 1.
    func testBasisZeroCountsThirty360() throws {
        let args: [CellValue] = [serial(2011, 1, 25), serial(2011, 11, 15), .number(2)]
        XCTAssertEqual(try number("COUPDAYS", args), 180, accuracy: 1e-9)
        XCTAssertEqual(try number("COUPDAYBS", args), 70, accuracy: 1e-9)
        XCTAssertEqual(try number("COUPDAYSNC", args), 110, accuracy: 1e-9)
    }

    /// Frequency changes the grid, not just the arithmetic: quarterly coupons on the
    /// same bond put settlement in a different period entirely.
    func testFrequencyReshapesTheGrid() throws {
        let quarterly: [CellValue] = [serial(2011, 1, 25), serial(2011, 11, 15), .number(4), .number(1)]
        // Grid back from 15 Nov 2011: 15 Aug, 15 May, 15 Feb 2011, 15 Nov 2010.
        XCTAssertEqual(
            try number("COUPPCD", quarterly),
            BuiltinDateTimeFunctions.componentsToSerial(year: 2010, month: 11, day: 15),
            accuracy: 1e-9)
        XCTAssertEqual(
            try number("COUPNCD", quarterly),
            BuiltinDateTimeFunctions.componentsToSerial(year: 2011, month: 2, day: 15),
            accuracy: 1e-9)
        XCTAssertEqual(try number("COUPNUM", quarterly), 4, accuracy: 1e-9)
    }

    // MARK: - Price and yield

    /// Microsoft's `PRICE` example: a 5.75% bond yielding 6.5%, settling 15 February
    /// 2008 and maturing 15 November 2017, semi-annual, 30/360.
    func testPriceMicrosoftExample() throws {
        let price = try number("PRICE", [
            serial(2008, 2, 15), serial(2017, 11, 15),
            .number(0.0575), .number(0.065), .number(100), .number(2), .number(0),
        ])
        XCTAssertEqual(price, 94.63436162, accuracy: 1e-6)
    }

    /// Microsoft's `YIELD` example, which is the same bond maturing a year earlier
    /// and priced at 95.04287 — and answers exactly 6.5%.
    func testYieldMicrosoftExample() throws {
        let yield = try number("YIELD", [
            serial(2008, 2, 15), serial(2016, 11, 15),
            .number(0.0575), .number(95.04287), .number(100), .number(2), .number(0),
        ])
        XCTAssertEqual(yield, 0.065, accuracy: 1e-6)
    }

    /// `PRICE` and `YIELD` are inverses, and this holds whatever either of them
    /// gets wrong in common — so it is a weaker test than the two above and a
    /// different one: it catches an argument-order slip in exactly one of the pair.
    func testPriceAndYieldInvert() throws {
        let dates: [CellValue] = [serial(2008, 2, 15), serial(2017, 11, 15)]
        let price = try number("PRICE", dates + [.number(0.0575), .number(0.065), .number(100), .number(2), .number(0)])
        let yield = try number("YIELD", dates + [.number(0.0575), .number(price), .number(100), .number(2), .number(0)])
        XCTAssertEqual(yield, 0.065, accuracy: 1e-6)
    }

    // MARK: - Duration

    /// `MDURATION = DURATION / (1 + yld/frequency)`.
    ///
    /// Microsoft states this relation in the `MDURATION` reference, so it is a
    /// documented identity rather than an observation of this implementation. It is
    /// the check that the two bindings pass their arguments in the same order — the
    /// mistake worth catching, since both take six and five of them coincide.
    func testModifiedDurationIsDurationDiscountedOnce() throws {
        let args: [CellValue] = [
            serial(2008, 1, 1), serial(2016, 1, 1),
            .number(0.08), .number(0.09), .number(2), .number(1),
        ]
        let duration = try number("DURATION", args)
        let modified = try number("MDURATION", args)
        XCTAssertEqual(modified, duration / (1 + 0.09 / 2), accuracy: 1e-9)
    }

    /// Duration is in years and cannot exceed the time to maturity — a coarse bound,
    /// and the one that catches a frequency used where a periods-per-year was meant.
    func testDurationIsInYearsAndBoundedByMaturity() throws {
        let duration = try number("DURATION", [
            serial(2008, 1, 1), serial(2016, 1, 1),
            .number(0.08), .number(0.09), .number(2), .number(1),
        ])
        XCTAssertGreaterThan(duration, 0)
        XCTAssertLessThan(duration, 8)
    }

    // MARK: - Accrued interest

    /// Microsoft's `ACCRINT` example: a 10% bond on 1,000 par, issued 1 March 2008,
    /// first interest 31 August 2008, settling 1 May 2008, semi-annual, 30/360.
    ///
    /// Two months of a six-month period at 50 a coupon is 16.66667, which is both
    /// the published answer and what the documented formula gives.
    func testAccrintMicrosoftExample() throws {
        let accrued = try number("ACCRINT", [
            serial(2008, 3, 1), serial(2008, 8, 31), serial(2008, 5, 1),
            .number(0.10), .number(1000), .number(2), .number(0),
        ])
        XCTAssertEqual(accrued, 16.666667, accuracy: 1e-5)
    }

    /// Par defaults to 1,000 when omitted — Excel's default, and not zero.
    func testAccrintParDefaultsToOneThousand() throws {
        let withPar = try number("ACCRINT", [
            serial(2008, 3, 1), serial(2008, 8, 31), serial(2008, 5, 1),
            .number(0.10), .number(1000), .number(2),
        ])
        let withoutPar = try number("ACCRINT", [
            serial(2008, 3, 1), serial(2008, 8, 31), serial(2008, 5, 1),
            .number(0.10), .blank, .number(2),
        ])
        XCTAssertEqual(withoutPar, withPar, accuracy: 1e-9)
    }

    // MARK: - Errors

    /// Settlement on or after maturity is `#NUM!` in all six clock functions and in
    /// all four price and duration ones. Excel is consistent about this and so is
    /// the guard in `CouponPeriod`; the binding's job is to turn the throw into the
    /// right error rather than let it escape.
    func testSettlementAtOrAfterMaturityIsNum() throws {
        let names = ["COUPDAYBS", "COUPDAYS", "COUPDAYSNC", "COUPNCD", "COUPNUM", "COUPPCD"]
        for name in names {
            XCTAssertEqual(
                try call(name, [serial(2011, 11, 15), serial(2011, 1, 25), .number(2), .number(0)]),
                .error(.num), "\(name) with settlement after maturity")
            XCTAssertEqual(
                try call(name, [serial(2011, 11, 15), serial(2011, 11, 15), .number(2), .number(0)]),
                .error(.num), "\(name) with settlement equal to maturity")
        }
    }

    /// Excel allows annual, semi-annual and quarterly, and nothing else.
    func testFrequencyMustBeOneTwoOrFour() throws {
        for bad in [0, 3, 5, 6, 12] {
            XCTAssertEqual(
                try call("COUPNUM", [serial(2011, 1, 25), serial(2011, 11, 15), .number(Double(bad))]),
                .error(.num), "frequency \(bad)")
        }
        for good in [1, 2, 4] {
            let result = try call("COUPNUM", [serial(2011, 1, 25), serial(2011, 11, 15), .number(Double(good))])
            XCTAssertNotEqual(result, .error(.num), "frequency \(good)")
        }
    }

    /// Basis runs 0 to 4. Anything else is `#NUM!`, the same rule `YEARFRAC` follows.
    func testBasisOutsideZeroToFourIsNum() throws {
        for bad in [-1, 5, 9] {
            XCTAssertEqual(
                try call("COUPNUM", [serial(2011, 1, 25), serial(2011, 11, 15), .number(2), .number(Double(bad))]),
                .error(.num), "basis \(bad)")
        }
    }

    /// A non-numeric argument is `#VALUE!`, not `#NUM!`. The distinction is Excel's
    /// and it matters: `#VALUE!` says the argument was the wrong kind, `#NUM!` says
    /// it was the right kind and out of range.
    func testTextArgumentIsValue() throws {
        XCTAssertEqual(
            try call("COUPNUM", [.text("not a date"), serial(2011, 11, 15), .number(2)]),
            .error(.value))
        XCTAssertEqual(
            try call("PRICE", [
                serial(2008, 2, 15), serial(2017, 11, 15),
                .text("five and three quarters"), .number(0.065), .number(100), .number(2),
            ]),
            .error(.value))
    }

    /// A negative rate, yield or redemption is `#NUM!` in Excel, and BusinessMath
    /// throws on each. The binding has to map the throw rather than propagate it.
    func testNegativeRateAndRedemptionAreNum() throws {
        XCTAssertEqual(
            try call("PRICE", [
                serial(2008, 2, 15), serial(2017, 11, 15),
                .number(-0.01), .number(0.065), .number(100), .number(2),
            ]),
            .error(.num))
        XCTAssertEqual(
            try call("PRICE", [
                serial(2008, 2, 15), serial(2017, 11, 15),
                .number(0.0575), .number(0.065), .number(0), .number(2),
            ]),
            .error(.num))
    }
}
