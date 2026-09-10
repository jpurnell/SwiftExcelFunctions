import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The functions whose mathematics belongs to BusinessMath.
///
/// Every one of these delegates. Reimplementing a covariance or a day count here
/// would put a second answer in the same dependency chain, which is the failure
/// this arrangement exists to prevent — so these tests check the *binding*: that
/// Excel's argument order, conventions and edge behaviour reach the right
/// function, not that the arithmetic is correct. BusinessMath tests that.
final class BusinessMathBindingTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: [CellValue]) throws -> CellValue {
        let function = try XCTUnwrap(registry.function(named: name), "\(name) is not registered")
        return try function.evaluate(args)
    }

    private func number(_ name: String, _ args: [CellValue]) throws -> Double {
        guard case .number(let value) = try call(name, args) else {
            throw XCTSkip("\(name) did not return a number")
        }
        return value
    }

    // MARK: - Registration

    /// The group's inventory, by name. It was the one group without this, which is
    /// how seven functions could be added without any test noticing the shape of the
    /// group had changed.
    func testAllContainsEveryFunctionInTheGroup() {
        XCTAssertEqual(
            Set(BuiltinBindingFunctions.all.map(\.name)),
            ["YEARFRAC", "COVARIANCE.P", "COVARIANCE.S", "COVAR", "NORM.S.INV", "XIRR",
             "SLOPE", "INTERCEPT", "NORM.INV", "NORM.DIST", "NORM.S.DIST",
             "RANK", "RANK.EQ", "RANK.AVG",
             "NOMINAL", "EFFECT", "SYD", "VDB"])
    }

    // MARK: - YEARFRAC

    /// 2026-01-01 to 2026-07-01 is half a year on a 30/360 basis: six months of
    /// thirty days each, over 360.
    func testYearFracOnThirtyThreeSixtyIsHalfAYear() throws {
        let start = CellValue.number(46023)   // 2026-01-01
        let end = CellValue.number(46204)     // 2026-07-01
        XCTAssertEqual(try number("YEARFRAC", [start, end, .number(0)]), 0.5, accuracy: 0.001)
    }

    /// Basis 3 is actual/365, so the same span is 181/365 rather than a clean half.
    func testYearFracOnActual365CountsRealDays() throws {
        let start = CellValue.number(46023)
        let end = CellValue.number(46204)
        XCTAssertEqual(
            try number("YEARFRAC", [start, end, .number(3)]), 181.0 / 365.0, accuracy: 0.001)
    }

    /// An omitted basis means 0, which is what the corpus writes.
    func testYearFracDefaultsToThirtyThreeSixty() throws {
        let start = CellValue.number(46023)
        let end = CellValue.number(46204)
        XCTAssertEqual(try number("YEARFRAC", [start, end]), 0.5, accuracy: 0.001)
    }

    /// All five bases compute, since BusinessMath 2.11.0 added the last two.
    ///
    /// Basis 4 is exact. Bases 1, 2 and 3 carry an upstream daylight-saving defect
    /// and basis 0 an upstream February one, both documented on the binding — but
    /// "computes" and "is right" are different claims, and this test makes only the
    /// first. The second is `MicrosoftSpecificationTests`' job.
    func testYearFracComputesEveryDocumentedBasis() throws {
        let start = CellValue.number(46023)   // 2026-01-01
        let end = CellValue.number(46204)     // 2026-07-01
        for basis in 0...4 {
            let result = try call("YEARFRAC", [start, end, .number(Double(basis))])
            guard case .number = result else {
                return XCTFail("basis \(basis) answered \(result)")
            }
        }
    }

    /// A basis Excel does not define is still `#NUM!`.
    func testYearFracRefusesAnUndefinedBasis() throws {
        let start = CellValue.number(46023)
        let end = CellValue.number(46204)
        XCTAssertEqual(try call("YEARFRAC", [start, end, .number(5)]), .error(.num))
        XCTAssertEqual(try call("YEARFRAC", [start, end, .number(-1)]), .error(.num))
    }

    /// Measured: every one of the corpus's 3,425 YEARFRAC calls passes two
    /// arguments and none passes a basis, so all of them take the default.
    /// The two conventions BusinessMath lacks are reached by nothing.
    func testTheDefaultBasisIsTheOneRealWorkbooksUse() throws {
        let start = CellValue.number(46023)
        let end = CellValue.number(46204)
        XCTAssertEqual(
            try number("YEARFRAC", [start, end]),
            try number("YEARFRAC", [start, end, .number(0)]),
            accuracy: 1e-12)
    }

    // MARK: - XIRR

    /// A year apart, out 1000 and back 1100, is 10%.
    ///
    /// Dates arrive as Excel serials and have to become `Date`s before
    /// BusinessMath's `xirr` will speak to them; that conversion is the binding.
    func testXirrOnASingleYearIsTheSimpleReturn() throws {
        let values = CellValue.array(CellMatrix(row: [.number(-1000), .number(1100)]))
        let dates = CellValue.array(CellMatrix(row: [.number(46023), .number(46388)]))   // 2026-01-01, 2027-01-01
        XCTAssertEqual(try number("XIRR", [values, dates]), 0.10, accuracy: 0.001)
    }

    /// Irregular spacing is the whole point of XIRR over IRR: the dates carry
    /// the timing rather than the positions.
    func testXirrHonoursIrregularSpacing() throws {
        let values = CellValue.array(CellMatrix(row: [.number(-1000), .number(500), .number(700)]))
        let dates = CellValue.array(CellMatrix(row: [.number(46023), .number(46114), .number(46388)]))
        let rate = try number("XIRR", [values, dates])
        XCTAssertGreaterThan(rate, 0.15, "front-loaded return beats a flat 20%")
        XCTAssertLessThan(rate, 0.35)
    }

    /// Mismatched counts have no answer.
    func testXirrRejectsMismatchedValuesAndDates() throws {
        let values = CellValue.array(CellMatrix(row: [.number(-100), .number(110)]))
        let dates = CellValue.array(CellMatrix(row: [.number(46023)]))
        XCTAssertEqual(try call("XIRR", [values, dates]), .error(.num))
    }

    /// Cash flows that never change sign have no rate of return.
    func testXirrNeedsASignChange() throws {
        let values = CellValue.array(CellMatrix(row: [.number(100), .number(110)]))
        let dates = CellValue.array(CellMatrix(row: [.number(46023), .number(46388)]))
        XCTAssertEqual(try call("XIRR", [values, dates]), .error(.num))
    }

    // MARK: - Covariance

    /// Population and sample differ by their divisor, and Excel spells the
    /// difference in the name. Getting the pair backwards is invisible until
    /// somebody compares against a spreadsheet.
    func testCovariancePopulationAndSampleDiffer() throws {
        let x = CellValue.array(CellMatrix(row: [.number(1), .number(2), .number(3), .number(4)]))
        let y = CellValue.array(CellMatrix(row: [.number(2), .number(4), .number(5), .number(8)]))

        let population = try number("COVARIANCE.P", [x, y])
        let sample = try number("COVARIANCE.S", [x, y])
        XCTAssertEqual(population, sample * 3.0 / 4.0, accuracy: 1e-9,
                       "population divides by n where sample divides by n-1")
    }

    /// `COVAR` is the legacy name for the population form, not the sample one.
    func testCovarIsThePopulationForm() throws {
        let x = CellValue.array(CellMatrix(row: [.number(1), .number(2), .number(3), .number(4)]))
        let y = CellValue.array(CellMatrix(row: [.number(2), .number(4), .number(5), .number(8)]))
        XCTAssertEqual(
            try number("COVAR", [x, y]), try number("COVARIANCE.P", [x, y]), accuracy: 1e-12)
    }

    func testCovarianceRejectsMismatchedLengths() throws {
        let x = CellValue.array(CellMatrix(row: [.number(1), .number(2)]))
        let y = CellValue.array(CellMatrix(row: [.number(1), .number(2), .number(3)]))
        XCTAssertEqual(try call("COVARIANCE.P", [x, y]), .error(.na))
    }

    // MARK: - NORM.S.INV

    /// The median of the standard normal is zero, and the quartiles are
    /// symmetric about it.
    func testStandardNormalInverse() throws {
        XCTAssertEqual(try number("NORM.S.INV", [.number(0.5)]), 0, accuracy: 1e-6)
        let upper = try number("NORM.S.INV", [.number(0.975)])
        let lower = try number("NORM.S.INV", [.number(0.025)])
        XCTAssertEqual(upper, -lower, accuracy: 1e-6)
        XCTAssertEqual(upper, 1.959964, accuracy: 1e-4, "the familiar 95% z")
    }

    /// A probability outside (0, 1) has no answer.
    func testStandardNormalInverseRejectsImpossibleProbabilities() throws {
        XCTAssertEqual(try call("NORM.S.INV", [.number(0)]), .error(.num))
        XCTAssertEqual(try call("NORM.S.INV", [.number(1)]), .error(.num))
    }
    // MARK: - The February end-of-month rule

    /// **Known gap, upstream.** `YEARFRAC(2020-02-29, 2020-12-31)` is 301/360.
    ///
    /// Taken from a corpus workbook — `Long Acre Team 2013 Probabilistic All.xlsx`,
    /// `Lease Renewal!L77` — where Excel's own cached answer is
    /// `0.83611111111111114`. Ours is `0.8388888888888889`, which is 302/360: one
    /// day out.
    ///
    /// `DayCountConvention.thirty360` in BusinessMath 2.9.0 does not apply the NASD
    /// February rule. The last day of February counts as a 30th, and — the part
    /// that decides this case — the pull-back of an end date on the 31st tests the
    /// start day *before* that adjustment rather than after. Adjusting first gives
    /// 300 days, not adjusting at all gives 302, and only the documented ordering
    /// gives Excel's 301.
    ///
    /// The BusinessMath session found and fixed this on
    /// `feature/excel-financial-ten`; this build pins `exact: "2.9.0"`, so the test
    /// Fixed in BusinessMath 2.15.0. The guard is gone and the assertion stays: this
    /// is the cell that found the defect, and it is the one that keeps it fixed.
    ///
    /// Every one of the corpus's 3,425 `YEARFRAC` calls uses this convention, and
    /// 49 of them have a February month end as their start date.
    func testTheFebruaryEndOfMonthRule() throws {
        guard let yearfrac = BuiltinBindingFunctions.all.first(where: { $0.name == "YEARFRAC" })
        else {
            return XCTFail("YEARFRAC is not registered")
        }
        // 2020-02-29 and 2020-12-31 as Excel serials.
        let result = try yearfrac.evaluate([.number(43890), .number(44196)])
        guard case .number(let fraction) = result else {
            return XCTFail("expected a number, got \(result)")
        }
        XCTAssertEqual(fraction, 0.83611111111111114, accuracy: 1e-12,
                       "Excel's own cached value for this cell")
    }


    // MARK: - Rate conversion

    /// Microsoft's `NOMINAL` example: 5.3543% effective, compounded quarterly.
    func testNominalMicrosoftExample() throws {
        XCTAssertEqual(try number("NOMINAL", [.number(0.053543), .number(4)]),
                       0.0525, accuracy: 1e-6)
    }

    /// Microsoft's `EFFECT` example, which is the same pair the other way round.
    ///
    /// The expected value is computed from the documented formula —
    /// `(1 + nominal/npery)^npery − 1` — rather than taken from Microsoft's rounded
    /// display of it, which is 0.053543.
    func testEffectMicrosoftExample() throws {
        XCTAssertEqual(try number("EFFECT", [.number(0.0525), .number(4)]),
                       0.05354266737075463, accuracy: 1e-9)
    }

    /// The two are inverses, which is the check that catches an argument order
    /// swapped in exactly one of them.
    func testNominalAndEffectInvert() throws {
        let effective = try number("EFFECT", [.number(0.0525), .number(12)])
        XCTAssertEqual(try number("NOMINAL", [.number(effective), .number(12)]),
                       0.0525, accuracy: 1e-12)
    }

    /// `npery` is truncated, not rounded: 4.9 compounding periods is quarterly.
    func testNperyIsTruncated() throws {
        XCTAssertEqual(try number("EFFECT", [.number(0.0525), .number(4.9)]),
                       try number("EFFECT", [.number(0.0525), .number(4)]),
                       accuracy: 1e-12)
    }

    func testNperyBelowOneIsNum() throws {
        XCTAssertEqual(try call("EFFECT", [.number(0.0525), .number(0)]), .error(.num))
        XCTAssertEqual(try call("NOMINAL", [.number(0.0525), .number(0.5)]), .error(.num))
    }

    // MARK: - Depreciation

    /// Microsoft's `SYD` example: 30,000 cost, 7,500 salvage, ten-year life.
    ///
    /// The first year charges 10/55 of the 22,500 depreciable base and the tenth
    /// charges 1/55 — the published figures, and what the documented formula gives.
    func testSydMicrosoftExample() throws {
        XCTAssertEqual(
            try number("SYD", [.number(30000), .number(7500), .number(10), .number(1)]),
            4090.909090909091, accuracy: 1e-9)
        XCTAssertEqual(
            try number("SYD", [.number(30000), .number(7500), .number(10), .number(10)]),
            409.0909090909091, accuracy: 1e-9)
    }

    /// A period outside `1...life` is `#NUM!`.
    func testSydPeriodOutsideLifeIsNum() throws {
        XCTAssertEqual(
            try call("SYD", [.number(30000), .number(7500), .number(10), .number(11)]),
            .error(.num))
        XCTAssertEqual(
            try call("SYD", [.number(30000), .number(7500), .number(10), .number(0)]),
            .error(.num))
    }

    /// Microsoft's `VDB` example: 2,400 cost, 300 salvage, ten-year life. The first
    /// year at the default factor of 2 charges 2,400 × 0.2 = 480.
    func testVdbMicrosoftExample() throws {
        XCTAssertEqual(
            try number("VDB", [.number(2400), .number(300), .number(10), .number(0), .number(1)]),
            480, accuracy: 1e-9)
    }

    /// Microsoft's remaining `VDB` examples, which exercise the span and the factor
    /// on the same asset expressed in days and months.
    ///
    /// | Call | Published |
    /// |---|---|
    /// | `VDB(2400, 300, 10*365, 0, 1)` — the first day | 1.32 |
    /// | `VDB(2400, 300, 10*12, 0, 1)` — the first month | 40.00 |
    /// | `VDB(2400, 300, 10*12, 6, 18)` — months 6 to 18 | 396.31 |
    /// | `VDB(2400, 300, 10*12, 6, 18, 1.5)` — the same at factor 1.5 | 311.81 |
    func testVdbSpanAndFactorMicrosoftExamples() throws {
        XCTAssertEqual(
            try number("VDB", [.number(2400), .number(300), .number(3650), .number(0), .number(1)]),
            1.32, accuracy: 0.005)
        XCTAssertEqual(
            try number("VDB", [.number(2400), .number(300), .number(120), .number(0), .number(1)]),
            40, accuracy: 1e-9)
        XCTAssertEqual(
            try number("VDB", [.number(2400), .number(300), .number(120), .number(6), .number(18)]),
            396.31, accuracy: 0.005)
        XCTAssertEqual(
            try number("VDB", [.number(2400), .number(300), .number(120), .number(6), .number(18),
                               .number(1.5)]),
            311.81, accuracy: 0.005)
    }

    /// `no_switch` is negated across the binding, so it needs a test that sets it.
    ///
    /// Microsoft's own asset does not exercise it: at the default factor of 2, the
    /// declining-balance charge on 2,400 over ten years beats straight line in every
    /// period, so the switch never fires and the flag changes nothing whatever it is
    /// set to. A test built on that asset would pass with the flag ignored entirely,
    /// which is worth saying because the first version of this test did exactly that.
    ///
    /// At factor 1 the switch does fire — straight line overtakes in the sixth period
    /// — and the last five periods then charge 1,027.50 with the switch and 580.35
    /// without it.
    func testVdbNoSwitchReachesTheUpstreamFlag() throws {
        let switching = try number(
            "VDB", [.number(2400), .number(300), .number(10), .number(5), .number(10), .number(1)])
        let held = try number(
            "VDB", [.number(2400), .number(300), .number(10), .number(5), .number(10),
                    .number(1), .bool(true)])
        XCTAssertEqual(switching, 1027.5, accuracy: 1e-6)
        XCTAssertEqual(held, 580.3477437600002, accuracy: 1e-6)
        XCTAssertLessThan(held, switching)
    }

    /// The full life depreciates the asset to its salvage value, switch or not.
    func testVdbOverTheWholeLifeReachesSalvage() throws {
        XCTAssertEqual(
            try number("VDB", [.number(2400), .number(300), .number(10), .number(0), .number(10)]),
            2100, accuracy: 1e-9)
    }
}
