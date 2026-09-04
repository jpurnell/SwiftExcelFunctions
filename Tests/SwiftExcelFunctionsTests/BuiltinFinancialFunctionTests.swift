import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

final class BuiltinFinancialFunctionTests: XCTestCase {

    // MARK: - Helpers

    /// Evaluates an ``ExcelFunction`` with the given ``CellValue`` arguments.
    private func eval(
        _ fn: ExcelFunction, _ args: CellValue...
    ) throws -> CellValue {
        try fn.evaluate(args)
    }

    /// Extracts the numeric value from a ``CellValue``, failing if not a number.
    private func number(_ value: CellValue, file: StaticString = #filePath,
                         line: UInt = #line) -> Double {
        guard case .number(let n) = value else {
            XCTFail("Expected .number but got \(value)", file: file, line: line)
            return .nan
        }
        return n
    }

    // MARK: - PMT Tests

    func testPMT_30YearMortgage() throws {
        // PMT(0.065/12, 360, -500000) => monthly payment on $500K at 6.5% for 30 years
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0.065 / 12.0), .number(360), .number(-500_000)
        )
        let payment = number(result)
        // Excel gives approximately 3160.34
        XCTAssertEqual(payment, 3160.34, accuracy: 0.01)
    }

    func testPMT_10YearLoan() throws {
        // PMT(0.08/12, 120, -100000) => monthly payment on $100K at 8% for 10 years
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0.08 / 12.0), .number(120), .number(-100_000)
        )
        let payment = number(result)
        // Excel gives approximately 1213.28
        XCTAssertEqual(payment, 1213.28, accuracy: 0.01)
    }

    func testPMT_ZeroRate() throws {
        // PMT(0, 12, -1200) => $100/month with no interest
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0), .number(12), .number(-1200)
        )
        let payment = number(result)
        XCTAssertEqual(payment, 100.0, accuracy: 0.01)
    }

    func testPMT_WithFutureValue() throws {
        // PMT(0.06/12, 120, 0, -10000) => saving toward $10K future value
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0.06 / 12.0), .number(120), .number(0), .number(-10_000)
        )
        let payment = number(result)
        // Should be a positive payment (cash outflow from your perspective = saving)
        // Excel: PMT(0.005, 120, 0, -10000) = 61.02
        XCTAssertEqual(payment, 61.02, accuracy: 0.01)
    }

    func testPMT_BeginningOfPeriod() throws {
        // PMT(0.065/12, 360, -500000, 0, 1) => beginning of period
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0.065 / 12.0), .number(360), .number(-500_000), .number(0), .number(1)
        )
        let payment = number(result)
        // Beginning-of-period payment is slightly less than end-of-period
        let endResult = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0.065 / 12.0), .number(360), .number(-500_000)
        )
        let endPayment = number(endResult)
        // type=1 payment should equal type=0 payment / (1+rate)
        let expectedBeginning = endPayment / (1.0 + 0.065 / 12.0)
        XCTAssertEqual(payment, expectedBeginning, accuracy: 0.01)
        XCTAssertLessThan(payment, endPayment)
    }

    // MARK: - IPMT / PPMT Tests

    func testIPMT_FirstPeriod() throws {
        // IPMT(0.065/12, 1, 360, -500000)
        let result = try eval(
            BuiltinFinancialFunctions.ipmt,
            .number(0.065 / 12.0), .number(1), .number(360), .number(-500_000)
        )
        let interest = number(result)
        // First month interest on $500K at 6.5%/12 = 500000 * 0.065/12 = 2708.33
        // But sign: PV is negative (you owe), interest should be negative (paying interest)
        // Actually with our sign convention: PV = -500000 means you borrowed it
        // IPMT for period 1 = balance * rate = -500000 * (0.065/12) = -2708.33
        // But the function returns a positive or negative value based on convention
        XCTAssertEqual(interest, -2708.33, accuracy: 0.01)
    }

    func testIPMT_PPMT_SumEquals_PMT() throws {
        // For any period: IPMT + PPMT = PMT
        let rate = 0.065 / 12.0
        let nper = 360.0
        let pv = -500_000.0

        let pmtResult = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(rate), .number(nper), .number(pv)
        )
        let pmtValue = number(pmtResult)

        // Test for several periods
        for per in [1.0, 2.0, 10.0, 100.0, 360.0] {
            let ipmtResult = try eval(
                BuiltinFinancialFunctions.ipmt,
                .number(rate), .number(per), .number(nper), .number(pv)
            )
            let ppmtResult = try eval(
                BuiltinFinancialFunctions.ppmt,
                .number(rate), .number(per), .number(nper), .number(pv)
            )
            let ipmtValue = number(ipmtResult)
            let ppmtValue = number(ppmtResult)

            XCTAssertEqual(
                ipmtValue + ppmtValue, pmtValue, accuracy: 0.01,
                "IPMT + PPMT should equal PMT for period \(per)"
            )
        }
    }

    func testIPMT_InterestDecreasesOverTime() throws {
        // Interest portion should decrease over the life of a loan
        let rate = 0.08 / 12.0
        let nper = 120.0
        let pv = -100_000.0

        let earlyInterest = try eval(
            BuiltinFinancialFunctions.ipmt,
            .number(rate), .number(1), .number(nper), .number(pv)
        )
        let lateInterest = try eval(
            BuiltinFinancialFunctions.ipmt,
            .number(rate), .number(119), .number(nper), .number(pv)
        )

        // Both should be negative (paying interest), early more negative than late
        let earlyVal = number(earlyInterest)
        let lateVal = number(lateInterest)
        // For a standard amortizing loan, early interest magnitude > late interest magnitude
        XCTAssertLessThan(earlyVal, lateVal,
                          "Early period interest should be more negative than late period")
    }

    func testPPMT_InvalidPeriod() throws {
        // Period 0 or period > nper should return #NUM!
        let result = try eval(
            BuiltinFinancialFunctions.ppmt,
            .number(0.05), .number(0), .number(12), .number(-1000)
        )
        XCTAssertEqual(result, .error(.num))

        let result2 = try eval(
            BuiltinFinancialFunctions.ppmt,
            .number(0.05), .number(13), .number(12), .number(-1000)
        )
        XCTAssertEqual(result2, .error(.num))
    }

    // MARK: - NPV Tests

    func testNPV_BasicCashFlows() throws {
        // NPV(0.10, 300, 420, 680)
        // = 300/(1.1)^1 + 420/(1.1)^2 + 680/(1.1)^3
        // = 272.73 + 347.11 + 510.88 = 1130.72
        // Wait, let me recalculate:
        // 300/1.1 = 272.727...
        // 420/1.21 = 347.107...
        // 680/1.331 = 510.895...
        // Sum = 1130.73
        let result = try eval(
            BuiltinFinancialFunctions.npv,
            .number(0.10), .number(300), .number(420), .number(680)
        )
        let npvValue = number(result)
        // Excel: NPV(0.10, 300, 420, 680) ≈ 1130.73
        XCTAssertEqual(npvValue, 1130.73, accuracy: 0.01)
    }

    func testNPV_WithInitialInvestment() throws {
        // Typical usage: NPV(0.10, 300, 420, 680) + (-1000)
        // where -1000 is the initial investment at time 0
        let npvResult = try eval(
            BuiltinFinancialFunctions.npv,
            .number(0.10), .number(300), .number(420), .number(680)
        )
        let npvValue = number(npvResult)
        let netNPV = npvValue - 1000.0
        XCTAssertEqual(netNPV, 130.73, accuracy: 0.01)
    }

    func testNPV_AllAsArguments() throws {
        // NPV(0.10, -1000, 300, 420, 680)
        // Treats -1000 as period 1 cash flow (not period 0)
        let result = try eval(
            BuiltinFinancialFunctions.npv,
            .number(0.10), .number(-1000), .number(300), .number(420), .number(680)
        )
        let npvValue = number(result)
        // -1000/1.1 + 300/1.21 + 420/1.331 + 680/1.4641
        // = -1000/1.1 + 300/1.21 + 420/1.331 + 680/1.4641
        // = -909.0909 + 247.9339 + 315.5522 + 464.4490 = 118.844
        XCTAssertEqual(npvValue, 118.84, accuracy: 0.01)
    }

    // MARK: - IRR Tests

    func testIRR_BasicInvestment() throws {
        // IRR([-1000, 300, 420, 680])
        let cashFlows: [CellValue] = [
            .number(-1000), .number(300), .number(420), .number(680),
        ]
        let result = try BuiltinFinancialFunctions.irr.evaluate([
            .array(cashFlows),
        ])
        let irrValue = number(result)
        // Should be some positive rate
        XCTAssertGreaterThan(irrValue, 0)
        XCTAssertLessThan(irrValue, 1)

        // Verify: NPV at this rate should be approximately 0
        var npvCheck = 0.0
        let flows = [-1000.0, 300.0, 420.0, 680.0]
        for (i, cf) in flows.enumerated() {
            npvCheck += cf / pow(1.0 + irrValue, Double(i))
        }
        XCTAssertEqual(npvCheck, 0.0, accuracy: 0.01)
    }

    func testIRR_EvenCashFlows() throws {
        // IRR([-10000, 3000, 3000, 3000, 3000, 3000])
        // 5 payments of $3000 on a $10000 investment
        let cashFlows: [CellValue] = [
            .number(-10_000), .number(3000), .number(3000),
            .number(3000), .number(3000), .number(3000),
        ]
        let result = try BuiltinFinancialFunctions.irr.evaluate([
            .array(cashFlows),
        ])
        let irrValue = number(result)
        // Excel: IRR({-10000,3000,3000,3000,3000,3000}) ≈ 0.15238 (15.24%)
        XCTAssertEqual(irrValue, 0.15238, accuracy: 0.001)
    }

    func testIRR_WithGuess() throws {
        // IRR([-5000, 1000, 2000, 3000], 0.05)
        let cashFlows: [CellValue] = [
            .number(-5000), .number(1000), .number(2000), .number(3000),
        ]
        let result = try BuiltinFinancialFunctions.irr.evaluate([
            .array(cashFlows), .number(0.05),
        ])
        let irrValue = number(result)
        XCTAssertGreaterThan(irrValue, 0)
        // Verify NPV at IRR ≈ 0
        var npvCheck = 0.0
        let flows = [-5000.0, 1000.0, 2000.0, 3000.0]
        for (i, cf) in flows.enumerated() {
            npvCheck += cf / pow(1.0 + irrValue, Double(i))
        }
        XCTAssertEqual(npvCheck, 0.0, accuracy: 0.01)
    }

    func testIRR_NoSignChange_ReturnsNUM() throws {
        // All positive cash flows — cannot compute IRR
        let cashFlows: [CellValue] = [
            .number(100), .number(200), .number(300),
        ]
        let result = try BuiltinFinancialFunctions.irr.evaluate([
            .array(cashFlows),
        ])
        XCTAssertEqual(result, .error(.num))
    }

    func testIRR_SingleValue_ReturnsNUM() throws {
        // Need at least 2 cash flows
        let cashFlows: [CellValue] = [.number(-100)]
        let result = try BuiltinFinancialFunctions.irr.evaluate([
            .array(cashFlows),
        ])
        XCTAssertEqual(result, .error(.num))
    }

    // MARK: - FV Tests

    func testFV_MonthlySavings() throws {
        // FV(0.065/12, 360, -500) => future value of saving $500/month at 6.5% for 30 years
        let result = try eval(
            BuiltinFinancialFunctions.fv,
            .number(0.065 / 12.0), .number(360), .number(-500)
        )
        let futureValue = number(result)
        // FV(0.065/12, 360, -500) = -(-500) * ((1+0.065/12)^360 - 1) / (0.065/12)
        // ≈ 553,089
        XCTAssertEqual(futureValue, 553_089.04, accuracy: 1.0)
    }

    func testFV_WithPresentValue() throws {
        // FV(0.05, 10, -100, -1000) => $1000 initial + $100/year at 5% for 10 years
        let result = try eval(
            BuiltinFinancialFunctions.fv,
            .number(0.05), .number(10), .number(-100), .number(-1000)
        )
        let futureValue = number(result)
        // FV = -(-1000)*(1.05)^10 - (-100)*((1.05)^10 - 1)/0.05
        // = 1000*1.62889 + 100*12.5779
        // = 1628.89 + 1257.79 = 2886.68
        XCTAssertEqual(futureValue, 2886.68, accuracy: 0.01)
    }

    func testFV_ZeroRate() throws {
        // FV(0, 12, -100) = 1200
        let result = try eval(
            BuiltinFinancialFunctions.fv,
            .number(0), .number(12), .number(-100)
        )
        let futureValue = number(result)
        XCTAssertEqual(futureValue, 1200.0, accuracy: 0.01)
    }

    func testFV_BeginningOfPeriod() throws {
        // FV(0.05, 10, -100, 0, 1) vs FV(0.05, 10, -100, 0, 0)
        let endResult = try eval(
            BuiltinFinancialFunctions.fv,
            .number(0.05), .number(10), .number(-100), .number(0), .number(0)
        )
        let beginResult = try eval(
            BuiltinFinancialFunctions.fv,
            .number(0.05), .number(10), .number(-100), .number(0), .number(1)
        )
        let endValue = number(endResult)
        let beginValue = number(beginResult)
        // Beginning of period FV should be higher (payments earn one extra period of interest)
        XCTAssertGreaterThan(beginValue, endValue)
    }

    // MARK: - PV Tests

    func testPV_MonthlyPayment() throws {
        // PV(0.08/12, 120, -1000) => present value of $1000/month at 8% for 10 years
        let result = try eval(
            BuiltinFinancialFunctions.pv,
            .number(0.08 / 12.0), .number(120), .number(-1000)
        )
        let presentValue = number(result)
        // Excel: PV(0.08/12, 120, -1000) ≈ 82,421.50
        XCTAssertEqual(presentValue, 82_421.50, accuracy: 1.0)
    }

    func testPV_ZeroRate() throws {
        // PV(0, 12, -100) = 1200
        let result = try eval(
            BuiltinFinancialFunctions.pv,
            .number(0), .number(12), .number(-100)
        )
        let presentValue = number(result)
        XCTAssertEqual(presentValue, 1200.0, accuracy: 0.01)
    }

    func testPV_WithFutureValue() throws {
        // PV(0.05, 10, 0, -10000) => present value of $10K received in 10 years at 5%
        let result = try eval(
            BuiltinFinancialFunctions.pv,
            .number(0.05), .number(10), .number(0), .number(-10_000)
        )
        let presentValue = number(result)
        // PV = 10000 / (1.05)^10 = 10000 / 1.62889 = 6139.13
        XCTAssertEqual(presentValue, 6139.13, accuracy: 0.01)
    }

    func testPV_PMT_Roundtrip() throws {
        // PV computed from PMT should return the original principal
        let rate = 0.065 / 12.0
        let nper = 360.0
        let originalPV = -500_000.0

        let pmtResult = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(rate), .number(nper), .number(originalPV)
        )
        let payment = number(pmtResult)

        let pvResult = try eval(
            BuiltinFinancialFunctions.pv,
            .number(rate), .number(nper), .number(payment)
        )
        let recoveredPV = number(pvResult)

        XCTAssertEqual(recoveredPV, originalPV, accuracy: 0.01)
    }

    // MARK: - RATE Tests

    func testRATE_KnownLoan() throws {
        // Given PMT(0.065/12, 360, -500000) ≈ 3160.34, solve for rate
        let result = try eval(
            BuiltinFinancialFunctions.rate,
            .number(360), .number(3160.34), .number(-500_000)
        )
        let rateValue = number(result)
        XCTAssertEqual(rateValue, 0.065 / 12.0, accuracy: 0.0001)
    }

    func testRATE_SimpleScenario() throws {
        // RATE(120, -1213.28, 100000)
        // Should recover approximately 0.08/12
        let result = try eval(
            BuiltinFinancialFunctions.rate,
            .number(120), .number(-1213.28), .number(100_000)
        )
        let rateValue = number(result)
        XCTAssertEqual(rateValue, 0.08 / 12.0, accuracy: 0.0001)
    }

    func testRATE_WithGuess() throws {
        // RATE(360, 3160.34, -500000, 0, 0, 0.005)
        let result = try eval(
            BuiltinFinancialFunctions.rate,
            .number(360), .number(3160.34), .number(-500_000),
            .number(0), .number(0), .number(0.005)
        )
        let rateValue = number(result)
        XCTAssertEqual(rateValue, 0.065 / 12.0, accuracy: 0.0001)
    }

    // MARK: - NPER Tests

    func testNPER_KnownLoan() throws {
        // Given PMT(0.065/12, 360, -500000), solve for nper
        let result = try eval(
            BuiltinFinancialFunctions.nper,
            .number(0.065 / 12.0), .number(3160.34), .number(-500_000)
        )
        let nperValue = number(result)
        XCTAssertEqual(nperValue, 360.0, accuracy: 0.1)
    }

    func testNPER_ZeroRate() throws {
        // NPER(0, -100, 1200) = 12
        let result = try eval(
            BuiltinFinancialFunctions.nper,
            .number(0), .number(-100), .number(1200)
        )
        let nperValue = number(result)
        XCTAssertEqual(nperValue, 12.0, accuracy: 0.01)
    }

    func testNPER_Savings() throws {
        // NPER(0.06/12, -500, 0, 100000) => how many months to save $100K at 6% saving $500/month
        let result = try eval(
            BuiltinFinancialFunctions.nper,
            .number(0.06 / 12.0), .number(-500), .number(0), .number(100_000)
        )
        let nperValue = number(result)
        // NPER(0.005, -500, 0, 100000) ≈ 138.98 months
        XCTAssertEqual(nperValue, 138.98, accuracy: 0.1)
    }

    func testNPER_InvalidInput_ReturnsNUM() throws {
        // NPER(0, 0, 1000) => division by zero (pmt=0, rate=0)
        let result = try eval(
            BuiltinFinancialFunctions.nper,
            .number(0), .number(0), .number(1000)
        )
        XCTAssertEqual(result, .error(.num))
    }

    // MARK: - SLN Tests

    func testSLN_Basic() throws {
        // SLN(10000, 1000, 5) = (10000 - 1000) / 5 = 1800
        let result = try eval(
            BuiltinFinancialFunctions.sln,
            .number(10_000), .number(1000), .number(5)
        )
        let depreciation = number(result)
        XCTAssertEqual(depreciation, 1800.0, accuracy: 0.01)
    }

    func testSLN_ZeroSalvage() throws {
        // SLN(50000, 0, 10) = 5000
        let result = try eval(
            BuiltinFinancialFunctions.sln,
            .number(50_000), .number(0), .number(10)
        )
        let depreciation = number(result)
        XCTAssertEqual(depreciation, 5000.0, accuracy: 0.01)
    }

    func testSLN_DivisionByZero() throws {
        // SLN(10000, 1000, 0) => #DIV/0!
        let result = try eval(
            BuiltinFinancialFunctions.sln,
            .number(10_000), .number(1000), .number(0)
        )
        XCTAssertEqual(result, .error(.div0))
    }

    // MARK: - DB Tests

    func testDB_FirstYear() throws {
        // DB(1000000, 100000, 6, 1)
        // rate = 1 - (100000/1000000)^(1/6) = 1 - 0.1^(1/6) = 1 - 0.68129... = 0.31871
        // rounded to 3 decimals = 0.319
        // First year (12 months): 1000000 * 0.319 * 12/12 = 319000
        let result = try eval(
            BuiltinFinancialFunctions.db,
            .number(1_000_000), .number(100_000), .number(6), .number(1)
        )
        let depreciation = number(result)
        // Excel: DB(1000000, 100000, 6, 1) = 319000
        XCTAssertEqual(depreciation, 319_000.0, accuracy: 0.01)
    }

    func testDB_SecondYear() throws {
        // DB(1000000, 100000, 6, 2)
        // After year 1: accumulated = 319000
        // Year 2: (1000000 - 319000) * 0.319 = 681000 * 0.319 = 217239
        let result = try eval(
            BuiltinFinancialFunctions.db,
            .number(1_000_000), .number(100_000), .number(6), .number(2)
        )
        let depreciation = number(result)
        // Excel: DB(1000000, 100000, 6, 2) = 217239
        XCTAssertEqual(depreciation, 217_239.0, accuracy: 1.0)
    }

    func testDB_ThirdYear() throws {
        // DB(1000000, 100000, 6, 3)
        // After year 1: 319000
        // After year 2: 319000 + 217239 = 536239
        // Year 3: (1000000 - 536239) * 0.319 = 463761 * 0.319 = 147939.759
        let result = try eval(
            BuiltinFinancialFunctions.db,
            .number(1_000_000), .number(100_000), .number(6), .number(3)
        )
        let depreciation = number(result)
        // Excel: DB(1000000, 100000, 6, 3) ≈ 147939.76
        XCTAssertEqual(depreciation, 147_939.76, accuracy: 1.0)
    }

    func testDB_WithPartialFirstYear() throws {
        // DB(1000000, 100000, 6, 1, 6) => only 6 months in first year
        // rate = 0.319
        // First year: 1000000 * 0.319 * 6/12 = 159500
        let result = try eval(
            BuiltinFinancialFunctions.db,
            .number(1_000_000), .number(100_000), .number(6), .number(1), .number(6)
        )
        let depreciation = number(result)
        XCTAssertEqual(depreciation, 159_500.0, accuracy: 0.01)
    }

    func testDB_LastFractionalYear() throws {
        // DB(1000000, 100000, 6, 7, 6)
        // With 6-month first year, there's a 7th period covering the remaining 6 months
        let result = try eval(
            BuiltinFinancialFunctions.db,
            .number(1_000_000), .number(100_000), .number(6), .number(7), .number(6)
        )
        let depreciation = number(result)
        // Should be a positive number (the remaining depreciation in the last half year)
        XCTAssertGreaterThan(depreciation, 0)
    }

    // MARK: - Cross-Function Consistency Tests

    func testFV_PV_Roundtrip() throws {
        // FV and PV should be inverses:
        // If FV(rate, nper, pmt, pv=0) = X, then PV(rate, nper, pmt, fv=X) should be 0
        let rate = 0.05
        let nper = 10.0
        let pmt = -100.0

        let fvResult = try eval(
            BuiltinFinancialFunctions.fv,
            .number(rate), .number(nper), .number(pmt)
        )
        let futureValue = number(fvResult)

        // PV(rate, nper, pmt, fv) should return 0 when fv equals the FV we computed
        // FV already accounts for the payments, so pass fv=futureValue (not negated)
        let pvResult = try eval(
            BuiltinFinancialFunctions.pv,
            .number(rate), .number(nper), .number(pmt), .number(futureValue)
        )
        let presentValue = number(pvResult)

        // PV should be approximately 0 since the FV already captures all payments
        XCTAssertEqual(presentValue, 0.0, accuracy: 0.01)
    }

    func testPMT_FV_Consistency() throws {
        // Save $500/month at 6.5% for 30 years
        let rate = 0.065 / 12.0
        let nper = 360.0
        let pmt = -500.0

        let fvResult = try eval(
            BuiltinFinancialFunctions.fv,
            .number(rate), .number(nper), .number(pmt)
        )
        let futureValue = number(fvResult)

        // Now compute PMT needed to reach that FV (note: FV is positive since we paid in)
        // PMT(rate, nper, pv=0, fv=futureValue) should give us back the original payment
        let pmtResult = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(rate), .number(nper), .number(0), .number(futureValue)
        )
        let recoveredPMT = number(pmtResult)

        XCTAssertEqual(recoveredPMT, pmt, accuracy: 0.01)
    }

    // MARK: - Error Handling Tests

    func testPMT_NonNumericInput() throws {
        // PMT with a text arg that's not a number should throw
        XCTAssertThrowsError(
            try eval(
                BuiltinFinancialFunctions.pmt,
                .text("abc"), .number(12), .number(-1000)
            )
        )
    }

    func testNPV_NonNumericInput() throws {
        // NPV with a non-numeric cash flow should throw
        XCTAssertThrowsError(
            try eval(
                BuiltinFinancialFunctions.npv,
                .number(0.10), .text("not a number")
            )
        )
    }

    // MARK: - Function Registration Tests

    func testAllFunctionsRegistered() {
        let all = BuiltinFinancialFunctions.all
        XCTAssertEqual(all.count, 11)

        let names = all.map(\.name)
        XCTAssertTrue(names.contains("PMT"))
        XCTAssertTrue(names.contains("IPMT"))
        XCTAssertTrue(names.contains("PPMT"))
        XCTAssertTrue(names.contains("NPV"))
        XCTAssertTrue(names.contains("IRR"))
        XCTAssertTrue(names.contains("FV"))
        XCTAssertTrue(names.contains("PV"))
        XCTAssertTrue(names.contains("RATE"))
        XCTAssertTrue(names.contains("NPER"))
        XCTAssertTrue(names.contains("SLN"))
        XCTAssertTrue(names.contains("DB"))
    }

    func testFunctionArityBounds() {
        // Verify arity constraints match Excel
        let pmt = BuiltinFinancialFunctions.pmt
        XCTAssertEqual(pmt.minArgs, 3)
        XCTAssertEqual(pmt.maxArgs, 5)

        let npv = BuiltinFinancialFunctions.npv
        XCTAssertEqual(npv.minArgs, 2)
        XCTAssertNil(npv.maxArgs) // variadic

        let sln = BuiltinFinancialFunctions.sln
        XCTAssertEqual(sln.minArgs, 3)
        XCTAssertEqual(sln.maxArgs, 3)

        let irr = BuiltinFinancialFunctions.irr
        XCTAssertEqual(irr.minArgs, 1)
        XCTAssertEqual(irr.maxArgs, 2)
    }

    // MARK: - Edge Cases

    func testPMT_LargeValues() throws {
        // PMT with very large loan amount
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0.04 / 12.0), .number(360), .number(-10_000_000)
        )
        let payment = number(result)
        // Should be a reasonable positive number
        XCTAssertGreaterThan(payment, 0)
        XCTAssertLessThan(payment, 100_000)
    }

    func testIPMT_WithType1() throws {
        // IPMT with type=1 (beginning of period)
        // For period 1 with type=1, interest should be 0 (payment at beginning, no interest accrued)
        let result = try eval(
            BuiltinFinancialFunctions.ipmt,
            .number(0.05 / 12.0), .number(1), .number(60), .number(-10_000),
            .number(0), .number(1)
        )
        let interest = number(result)
        XCTAssertEqual(interest, 0.0, accuracy: 0.01)
    }

    func testIPMT_PPMT_WithType1_SumEqualsPMT() throws {
        // Even with type=1, IPMT + PPMT should still equal PMT
        let rate = 0.05 / 12.0
        let nper = 60.0
        let pv = -10_000.0
        let type = 1.0

        let pmtResult = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(rate), .number(nper), .number(pv), .number(0), .number(type)
        )
        let pmtValue = number(pmtResult)

        for per in [1.0, 5.0, 30.0, 60.0] {
            let ipmtResult = try eval(
                BuiltinFinancialFunctions.ipmt,
                .number(rate), .number(per), .number(nper), .number(pv),
                .number(0), .number(type)
            )
            let ppmtResult = try eval(
                BuiltinFinancialFunctions.ppmt,
                .number(rate), .number(per), .number(nper), .number(pv),
                .number(0), .number(type)
            )
            let ipmtValue = number(ipmtResult)
            let ppmtValue = number(ppmtResult)

            XCTAssertEqual(
                ipmtValue + ppmtValue, pmtValue, accuracy: 0.01,
                "IPMT + PPMT should equal PMT for period \(per) with type=1"
            )
        }
    }

    func testBoolCoercion() throws {
        // Bool values should be coerced: true -> 1, false -> 0
        let result = try eval(
            BuiltinFinancialFunctions.sln,
            .number(10_000), .number(1000), .bool(true)
        )
        let depreciation = number(result)
        // SLN(10000, 1000, 1) = 9000
        XCTAssertEqual(depreciation, 9000.0, accuracy: 0.01)
    }

    func testBlankCoercion() throws {
        // Blank values should be coerced to 0
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .blank, .number(12), .number(-1200)
        )
        let payment = number(result)
        // PMT(0, 12, -1200) = 100
        XCTAssertEqual(payment, 100.0, accuracy: 0.01)
    }

    func testNumericStringCoercion() throws {
        // Numeric strings should be parsed
        let result = try eval(
            BuiltinFinancialFunctions.sln,
            .text("10000"), .text("1000"), .text("5")
        )
        let depreciation = number(result)
        XCTAssertEqual(depreciation, 1800.0, accuracy: 0.01)
    }
}
