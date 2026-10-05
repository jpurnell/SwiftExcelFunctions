import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

@Suite struct BuiltinFinancialFunctionTests {

    // MARK: - Helpers

    /// Evaluates an ``ExcelFunction`` with the given ``CellValue`` arguments.
    private func eval(
        _ fn: ExcelFunction, _ args: CellValue...
    ) throws -> CellValue {
        try fn.evaluate(args)
    }

    /// Extracts the numeric value from a ``CellValue``, failing if not a number.
    private func number(_ value: CellValue, sourceLocation: SourceLocation = #_sourceLocation) -> Double {
        guard case .number(let n) = value else {
            Issue.record("Expected .number but got \(value)")
            return .nan
        }
        return n
    }

    // MARK: - PMT Tests

    @Test func pmt_30YearMortgage() throws {
        // PMT(0.065/12, 360, -500000) => monthly payment on $500K at 6.5% for 30 years
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0.065 / 12.0), .number(360), .number(-500_000)
        )
        let payment = number(result)
        // Excel gives approximately 3160.34
        #expect(abs(payment - 3160.34) <= 0.01)
    }

    @Test func pmt_10YearLoan() throws {
        // PMT(0.08/12, 120, -100000) => monthly payment on $100K at 8% for 10 years
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0.08 / 12.0), .number(120), .number(-100_000)
        )
        let payment = number(result)
        // Excel gives approximately 1213.28
        #expect(abs(payment - 1213.28) <= 0.01)
    }

    @Test func pmt_ZeroRate() throws {
        // PMT(0, 12, -1200) => $100/month with no interest
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0), .number(12), .number(-1200)
        )
        let payment = number(result)
        #expect(abs(payment - 100.0) <= 0.01)
    }

    @Test func pmt_WithFutureValue() throws {
        // PMT(0.06/12, 120, 0, -10000) => saving toward $10K future value
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0.06 / 12.0), .number(120), .number(0), .number(-10_000)
        )
        let payment = number(result)
        // Should be a positive payment (cash outflow from your perspective = saving)
        // Excel: PMT(0.005, 120, 0, -10000) = 61.02
        #expect(abs(payment - 61.02) <= 0.01)
    }

    @Test func pmt_BeginningOfPeriod() throws {
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
        #expect(abs(payment - expectedBeginning) <= 0.01)
        #expect(payment < endPayment)
    }

    /// No payment schedule has zero payments. Excel answers `#NUM!` for `nper = 0`; this
    /// used to answer `.number(-inf)`, which a caller summing a column would carry forward
    /// as a number.
    @Test func pmt_ZeroPeriodsAtZeroRateIsNumError() throws {
        // PMT(0, 0, 1000) — the zero-rate branch divides by nper directly.
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0), .number(0), .number(1000)
        )
        #expect(result == .error(.num))
    }

    @Test func pmt_ZeroPeriodsAtPositiveRateIsNumError() throws {
        // PMT(0.05, 0, 1000) — (1+r)^0 − 1 is zero, the same hole by another route.
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0.05), .number(0), .number(1000)
        )
        #expect(result == .error(.num))
    }

    // MARK: - IPMT / PPMT Tests

    /// Microsoft's published example, and the sign it establishes.
    ///
    /// `IPMT(0.1/12, 1, 3*12, 8000)` is documented as **−66.67**, which is exactly
    /// −(8000 × 0.1/12): a positive present value is money you owe, so the interest on it
    /// leaves, so the answer is negative.
    ///
    /// **This test asserted the opposite sign and passed for months.** It used a *negative*
    /// `pv`, where an inverted answer looks entirely plausible — and the inversion cancels
    /// in `IPMT + PPMT = PMT`, so the identity test beside it passed too. The workbook
    /// checker found it in a real mortgage schedule: 720 cells where the interest and the
    /// principal had swapped places. Both cases are asserted now, and the published one
    /// first.
    @Test func ipmt_FirstPeriod() throws {
        let published = try eval(
            BuiltinFinancialFunctions.ipmt,
            .number(0.1 / 12.0), .number(1), .number(36), .number(8_000)
        )
        #expect(abs(number(published) - -66.67) <= 0.01)

        // The same rule with the sign of `pv` reversed: money lent rather than borrowed.
        let lent = try eval(
            BuiltinFinancialFunctions.ipmt,
            .number(0.065 / 12.0), .number(1), .number(360), .number(-500_000)
        )
        #expect(abs(number(lent) - 2_708.33) <= 0.01)
    }

    /// Microsoft's published `PPMT` example: **−75.62** for the first payment.
    ///
    /// The principal part of a first payment on a two-year loan, which is the small half —
    /// the interest is the large one. Reversing them is exactly the defect above, and this
    /// is the assertion that pins which is which.
    @Test func ppmt_FirstPeriodMatchesThePublishedExample() throws {
        let result = try eval(
            BuiltinFinancialFunctions.ppmt,
            .number(0.1 / 12.0), .number(1), .number(24), .number(2_000)
        )
        #expect(abs(number(result) - -75.62) <= 0.01)

        // And the interest for the same payment is the larger part.
        let interest = try eval(
            BuiltinFinancialFunctions.ipmt,
            .number(0.1 / 12.0), .number(1), .number(24), .number(2_000)
        )
        #expect(abs(number(interest) - -16.67) <= 0.01)
        #expect(number(interest) < 0)
        #expect(abs(number(result)) > abs(number(interest)), "on a two-year loan the principal part is the larger one")
    }

    @Test func ipmt_PPMT_SumEquals_PMT() throws {
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

            #expect(abs((ipmtValue + ppmtValue) - pmtValue) <= 0.01, "IPMT + PPMT should equal PMT for period \(per)")
        }
    }

    @Test func ipmt_InterestDecreasesOverTime() throws {
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

        // `pv` is negative here — money lent — so the interest arrives and is positive.
        // What the test is really about is the *magnitude*, which falls as the balance
        // does, and stating it that way is true whichever way round `pv` is.
        let earlyVal = number(earlyInterest)
        let lateVal = number(lateInterest)
        #expect(abs(earlyVal) > abs(lateVal), "interest is charged on a balance that shrinks")
    }

    @Test func ppmt_InvalidPeriod() throws {
        // Period 0 or period > nper should return #NUM!
        let result = try eval(
            BuiltinFinancialFunctions.ppmt,
            .number(0.05), .number(0), .number(12), .number(-1000)
        )
        #expect(result == .error(.num))

        let result2 = try eval(
            BuiltinFinancialFunctions.ppmt,
            .number(0.05), .number(13), .number(12), .number(-1000)
        )
        #expect(result2 == .error(.num))
    }

    // MARK: - NPV Tests

    @Test func npv_BasicCashFlows() throws {
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
        #expect(abs(npvValue - 1130.73) <= 0.01)
    }

    @Test func npv_WithInitialInvestment() throws {
        // Typical usage: NPV(0.10, 300, 420, 680) + (-1000)
        // where -1000 is the initial investment at time 0
        let npvResult = try eval(
            BuiltinFinancialFunctions.npv,
            .number(0.10), .number(300), .number(420), .number(680)
        )
        let npvValue = number(npvResult)
        let netNPV = npvValue - 1000.0
        #expect(abs(netNPV - 130.73) <= 0.01)
    }

    @Test func npv_AllAsArguments() throws {
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
        #expect(abs(npvValue - 118.84) <= 0.01)
    }

    // MARK: - IRR Tests

    @Test func irr_BasicInvestment() throws {
        // IRR([-1000, 300, 420, 680])
        let cashFlows: [CellValue] = [
            .number(-1000), .number(300), .number(420), .number(680),
        ]
        let result = try BuiltinFinancialFunctions.irr.evaluate([
            .array(CellMatrix(column: cashFlows)),
        ])
        let irrValue = number(result)
        // Should be some positive rate
        #expect(irrValue > 0)
        #expect(irrValue < 1)

        // Verify: NPV at this rate should be approximately 0
        var npvCheck = 0.0
        let flows = [-1000.0, 300.0, 420.0, 680.0]
        for (i, cf) in flows.enumerated() {
            npvCheck += cf / pow(1.0 + irrValue, Double(i))
        }
        #expect(abs(npvCheck - 0.0) <= 0.01)
    }

    @Test func irr_EvenCashFlows() throws {
        // IRR([-10000, 3000, 3000, 3000, 3000, 3000])
        // 5 payments of $3000 on a $10000 investment
        let cashFlows: [CellValue] = [
            .number(-10_000), .number(3000), .number(3000),
            .number(3000), .number(3000), .number(3000),
        ]
        let result = try BuiltinFinancialFunctions.irr.evaluate([
            .array(CellMatrix(column: cashFlows)),
        ])
        let irrValue = number(result)
        // Excel: IRR({-10000,3000,3000,3000,3000,3000}) ≈ 0.15238 (15.24%)
        #expect(abs(irrValue - 0.15238) <= 0.001)
    }

    @Test func irr_WithGuess() throws {
        // IRR([-5000, 1000, 2000, 3000], 0.05)
        let cashFlows: [CellValue] = [
            .number(-5000), .number(1000), .number(2000), .number(3000),
        ]
        let result = try BuiltinFinancialFunctions.irr.evaluate([
            .array(CellMatrix(column: cashFlows)), .number(0.05),
        ])
        let irrValue = number(result)
        #expect(irrValue > 0)
        // Verify NPV at IRR ≈ 0
        var npvCheck = 0.0
        let flows = [-5000.0, 1000.0, 2000.0, 3000.0]
        for (i, cf) in flows.enumerated() {
            npvCheck += cf / pow(1.0 + irrValue, Double(i))
        }
        #expect(abs(npvCheck - 0.0) <= 0.01)
    }

    @Test func irr_NoSignChange_ReturnsNUM() throws {
        // All positive cash flows — cannot compute IRR
        let cashFlows: [CellValue] = [
            .number(100), .number(200), .number(300),
        ]
        let result = try BuiltinFinancialFunctions.irr.evaluate([
            .array(CellMatrix(column: cashFlows)),
        ])
        #expect(result == .error(.num))
    }

    @Test func irr_SingleValue_ReturnsNUM() throws {
        // Need at least 2 cash flows
        let cashFlows: [CellValue] = [.number(-100)]
        let result = try BuiltinFinancialFunctions.irr.evaluate([
            .array(CellMatrix(column: cashFlows)),
        ])
        #expect(result == .error(.num))
    }

    // MARK: - FV Tests

    @Test func fv_MonthlySavings() throws {
        // FV(0.065/12, 360, -500) => future value of saving $500/month at 6.5% for 30 years
        let result = try eval(
            BuiltinFinancialFunctions.fv,
            .number(0.065 / 12.0), .number(360), .number(-500)
        )
        let futureValue = number(result)
        // FV(0.065/12, 360, -500) = -(-500) * ((1+0.065/12)^360 - 1) / (0.065/12)
        // ≈ 553,089
        #expect(abs(futureValue - 553_089.04) <= 1.0)
    }

    @Test func fv_WithPresentValue() throws {
        // FV(0.05, 10, -100, -1000) => $1000 initial + $100/year at 5% for 10 years
        let result = try eval(
            BuiltinFinancialFunctions.fv,
            .number(0.05), .number(10), .number(-100), .number(-1000)
        )
        let futureValue = number(result)
        // FV = -(-1000)*(1.05)^10 - (-100)*((1.05)^10 - 1)/0.05
        // = 1000*1.62889 + 100*12.5779
        // = 1628.89 + 1257.79 = 2886.68
        #expect(abs(futureValue - 2886.68) <= 0.01)
    }

    @Test func fv_ZeroRate() throws {
        // FV(0, 12, -100) = 1200
        let result = try eval(
            BuiltinFinancialFunctions.fv,
            .number(0), .number(12), .number(-100)
        )
        let futureValue = number(result)
        #expect(abs(futureValue - 1200.0) <= 0.01)
    }

    @Test func fv_BeginningOfPeriod() throws {
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
        #expect(beginValue > endValue)
    }

    // MARK: - PV Tests

    @Test func pv_MonthlyPayment() throws {
        // PV(0.08/12, 120, -1000) => present value of $1000/month at 8% for 10 years
        let result = try eval(
            BuiltinFinancialFunctions.pv,
            .number(0.08 / 12.0), .number(120), .number(-1000)
        )
        let presentValue = number(result)
        // Excel: PV(0.08/12, 120, -1000) ≈ 82,421.50
        #expect(abs(presentValue - 82_421.50) <= 1.0)
    }

    @Test func pv_ZeroRate() throws {
        // PV(0, 12, -100) = 1200
        let result = try eval(
            BuiltinFinancialFunctions.pv,
            .number(0), .number(12), .number(-100)
        )
        let presentValue = number(result)
        #expect(abs(presentValue - 1200.0) <= 0.01)
    }

    @Test func pv_WithFutureValue() throws {
        // PV(0.05, 10, 0, -10000) => present value of $10K received in 10 years at 5%
        let result = try eval(
            BuiltinFinancialFunctions.pv,
            .number(0.05), .number(10), .number(0), .number(-10_000)
        )
        let presentValue = number(result)
        // PV = 10000 / (1.05)^10 = 10000 / 1.62889 = 6139.13
        #expect(abs(presentValue - 6139.13) <= 0.01)
    }

    @Test func pv_PMT_Roundtrip() throws {
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

        #expect(abs(recoveredPV - originalPV) <= 0.01)
    }

    // MARK: - RATE Tests

    @Test func rate_KnownLoan() throws {
        // Given PMT(0.065/12, 360, -500000) ≈ 3160.34, solve for rate
        let result = try eval(
            BuiltinFinancialFunctions.rate,
            .number(360), .number(3160.34), .number(-500_000)
        )
        let rateValue = number(result)
        #expect(abs(rateValue - (0.065 / 12.0)) <= 0.0001)
    }

    @Test func rate_SimpleScenario() throws {
        // RATE(120, -1213.28, 100000)
        // Should recover approximately 0.08/12
        let result = try eval(
            BuiltinFinancialFunctions.rate,
            .number(120), .number(-1213.28), .number(100_000)
        )
        let rateValue = number(result)
        #expect(abs(rateValue - (0.08 / 12.0)) <= 0.0001)
    }

    @Test func rate_WithGuess() throws {
        // RATE(360, 3160.34, -500000, 0, 0, 0.005)
        let result = try eval(
            BuiltinFinancialFunctions.rate,
            .number(360), .number(3160.34), .number(-500_000),
            .number(0), .number(0), .number(0.005)
        )
        let rateValue = number(result)
        #expect(abs(rateValue - (0.065 / 12.0)) <= 0.0001)
    }

    // MARK: - NPER Tests

    @Test func nper_KnownLoan() throws {
        // Given PMT(0.065/12, 360, -500000), solve for nper
        let result = try eval(
            BuiltinFinancialFunctions.nper,
            .number(0.065 / 12.0), .number(3160.34), .number(-500_000)
        )
        let nperValue = number(result)
        #expect(abs(nperValue - 360.0) <= 0.1)
    }

    @Test func nper_ZeroRate() throws {
        // NPER(0, -100, 1200) = 12
        let result = try eval(
            BuiltinFinancialFunctions.nper,
            .number(0), .number(-100), .number(1200)
        )
        let nperValue = number(result)
        #expect(abs(nperValue - 12.0) <= 0.01)
    }

    @Test func nper_Savings() throws {
        // NPER(0.06/12, -500, 0, 100000) => how many months to save $100K at 6% saving $500/month
        let result = try eval(
            BuiltinFinancialFunctions.nper,
            .number(0.06 / 12.0), .number(-500), .number(0), .number(100_000)
        )
        let nperValue = number(result)
        // NPER(0.005, -500, 0, 100000) ≈ 138.98 months
        #expect(abs(nperValue - 138.98) <= 0.1)
    }

    @Test func nper_InvalidInput_ReturnsNUM() throws {
        // NPER(0, 0, 1000) => division by zero (pmt=0, rate=0)
        let result = try eval(
            BuiltinFinancialFunctions.nper,
            .number(0), .number(0), .number(1000)
        )
        #expect(result == .error(.num))
    }

    // MARK: - SLN Tests

    @Test func sln_Basic() throws {
        // SLN(10000, 1000, 5) = (10000 - 1000) / 5 = 1800
        let result = try eval(
            BuiltinFinancialFunctions.sln,
            .number(10_000), .number(1000), .number(5)
        )
        let depreciation = number(result)
        #expect(abs(depreciation - 1800.0) <= 0.01)
    }

    @Test func sln_ZeroSalvage() throws {
        // SLN(50000, 0, 10) = 5000
        let result = try eval(
            BuiltinFinancialFunctions.sln,
            .number(50_000), .number(0), .number(10)
        )
        let depreciation = number(result)
        #expect(abs(depreciation - 5000.0) <= 0.01)
    }

    @Test func sln_DivisionByZero() throws {
        // SLN(10000, 1000, 0) => #DIV/0!
        let result = try eval(
            BuiltinFinancialFunctions.sln,
            .number(10_000), .number(1000), .number(0)
        )
        #expect(result == .error(.div0))
    }

    // MARK: - DB Tests

    @Test func db_FirstYear() throws {
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
        #expect(abs(depreciation - 319_000.0) <= 0.01)
    }

    @Test func db_SecondYear() throws {
        // DB(1000000, 100000, 6, 2)
        // After year 1: accumulated = 319000
        // Year 2: (1000000 - 319000) * 0.319 = 681000 * 0.319 = 217239
        let result = try eval(
            BuiltinFinancialFunctions.db,
            .number(1_000_000), .number(100_000), .number(6), .number(2)
        )
        let depreciation = number(result)
        // Excel: DB(1000000, 100000, 6, 2) = 217239
        #expect(abs(depreciation - 217_239.0) <= 1.0)
    }

    @Test func db_ThirdYear() throws {
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
        #expect(abs(depreciation - 147_939.76) <= 1.0)
    }

    @Test func db_WithPartialFirstYear() throws {
        // DB(1000000, 100000, 6, 1, 6) => only 6 months in first year
        // rate = 0.319
        // First year: 1000000 * 0.319 * 6/12 = 159500
        let result = try eval(
            BuiltinFinancialFunctions.db,
            .number(1_000_000), .number(100_000), .number(6), .number(1), .number(6)
        )
        let depreciation = number(result)
        #expect(abs(depreciation - 159_500.0) <= 0.01)
    }

    @Test func db_LastFractionalYear() throws {
        // DB(1000000, 100000, 6, 7, 6)
        // With 6-month first year, there's a 7th period covering the remaining 6 months
        let result = try eval(
            BuiltinFinancialFunctions.db,
            .number(1_000_000), .number(100_000), .number(6), .number(7), .number(6)
        )
        let depreciation = number(result)
        // Should be a positive number (the remaining depreciation in the last half year)
        #expect(depreciation > 0)
    }

    // MARK: - Cross-Function Consistency Tests

    @Test func fv_PV_Roundtrip() throws {
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
        #expect(abs(presentValue - 0.0) <= 0.01)
    }

    @Test func pmt_FV_Consistency() throws {
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

        #expect(abs(recoveredPMT - pmt) <= 0.01)
    }

    // MARK: - Error Handling Tests

    @Test func pmt_NonNumericInput() throws {
        // PMT with a text arg that's not a number should throw
        #expect(throws: (any Error).self) { try eval(
                BuiltinFinancialFunctions.pmt,
                .text("abc"), .number(12), .number(-1000)
            ) }
    }

    @Test func npv_NonNumericInput() throws {
        // NPV with a non-numeric cash flow should throw
        #expect(throws: (any Error).self) { try eval(
                BuiltinFinancialFunctions.npv,
                .number(0.10), .text("not a number")
            ) }
    }

    // MARK: - Function Registration Tests

    @Test func allFunctionsRegistered() {
        let all = BuiltinFinancialFunctions.all
        #expect(all.count == 11)

        let names = all.map(\.name)
        #expect(names.contains("PMT"))
        #expect(names.contains("IPMT"))
        #expect(names.contains("PPMT"))
        #expect(names.contains("NPV"))
        #expect(names.contains("IRR"))
        #expect(names.contains("FV"))
        #expect(names.contains("PV"))
        #expect(names.contains("RATE"))
        #expect(names.contains("NPER"))
        #expect(names.contains("SLN"))
        #expect(names.contains("DB"))
    }

    @Test func functionArityBounds() {
        // Verify arity constraints match Excel
        let pmt = BuiltinFinancialFunctions.pmt
        #expect(pmt.minArgs == 3)
        #expect(pmt.maxArgs == 5)

        let npv = BuiltinFinancialFunctions.npv
        #expect(npv.minArgs == 2)
        #expect(npv.maxArgs == nil) // variadic

        let sln = BuiltinFinancialFunctions.sln
        #expect(sln.minArgs == 3)
        #expect(sln.maxArgs == 3)

        let irr = BuiltinFinancialFunctions.irr
        #expect(irr.minArgs == 1)
        #expect(irr.maxArgs == 2)
    }

    // MARK: - Edge Cases

    @Test func pmt_LargeValues() throws {
        // PMT with very large loan amount
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .number(0.04 / 12.0), .number(360), .number(-10_000_000)
        )
        let payment = number(result)
        // Should be a reasonable positive number
        #expect(payment > 0)
        #expect(payment < 100_000)
    }

    @Test func ipmt_WithType1() throws {
        // IPMT with type=1 (beginning of period)
        // For period 1 with type=1, interest should be 0 (payment at beginning, no interest accrued)
        let result = try eval(
            BuiltinFinancialFunctions.ipmt,
            .number(0.05 / 12.0), .number(1), .number(60), .number(-10_000),
            .number(0), .number(1)
        )
        let interest = number(result)
        #expect(abs(interest - 0.0) <= 0.01)
    }

    @Test func ipmt_PPMT_WithType1_SumEqualsPMT() throws {
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

            #expect(abs((ipmtValue + ppmtValue) - pmtValue) <= 0.01, "IPMT + PPMT should equal PMT for period \(per) with type=1")
        }
    }

    @Test func boolCoercion() throws {
        // Bool values should be coerced: true -> 1, false -> 0
        let result = try eval(
            BuiltinFinancialFunctions.sln,
            .number(10_000), .number(1000), .bool(true)
        )
        let depreciation = number(result)
        // SLN(10000, 1000, 1) = 9000
        #expect(abs(depreciation - 9000.0) <= 0.01)
    }

    @Test func blankCoercion() throws {
        // Blank values should be coerced to 0
        let result = try eval(
            BuiltinFinancialFunctions.pmt,
            .blank, .number(12), .number(-1200)
        )
        let payment = number(result)
        // PMT(0, 12, -1200) = 100
        #expect(abs(payment - 100.0) <= 0.01)
    }

    @Test func numericStringCoercion() throws {
        // Numeric strings should be parsed
        let result = try eval(
            BuiltinFinancialFunctions.sln,
            .text("10000"), .text("1000"), .text("5")
        )
        let depreciation = number(result)
        #expect(abs(depreciation - 1800.0) <= 0.01)
    }
}
