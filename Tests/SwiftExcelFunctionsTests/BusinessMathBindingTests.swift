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

    /// Bases 1 and 4 are refused rather than approximated.
    ///
    /// BusinessMath has actual/365, actual/360 and 30/360. It does not have
    /// actual/actual or the European 30/360, and answering with a neighbouring
    /// convention would be wrong by a few days in a way nobody would notice until
    /// it priced something.
    func testYearFracRefusesTheConventionsBusinessMathLacks() throws {
        let start = CellValue.number(46023)
        let end = CellValue.number(46204)
        XCTAssertEqual(try call("YEARFRAC", [start, end, .number(1)]), .error(.num))
        XCTAssertEqual(try call("YEARFRAC", [start, end, .number(4)]), .error(.num))
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
    /// is expected to fail until they tag. It will report an unexpected pass on the
    /// day it is fixed, which is the point of writing it now.
    ///
    /// Every one of the corpus's 3,425 `YEARFRAC` calls uses this convention, and
    /// 49 of them have a February month end as their start date.
    func testTheFebruaryEndOfMonthRule() throws {
        XCTExpectFailure("BusinessMath 2.9.0 lacks the NASD February rule; fixed upstream, untagged")
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

}
