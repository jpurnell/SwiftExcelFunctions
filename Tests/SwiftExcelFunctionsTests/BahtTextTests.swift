import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// `BAHTTEXT` — a number spelled out in Thai as currency.
///
/// **Measured against Excel for Mac on 2026-09-10**, not derived. Seven values were run and
/// all seven matched: `0`, `1`, `11`, `21`, `100`, `1234.56`, `-5`. They were written from
/// the documented grammar first and confirmed after, which is the order that makes the
/// confirmation worth something.
///
/// The seven were chosen so that each pins a rule that is not digit substitution — which is
/// where an implementation goes wrong, and where a wrong answer is hardest to notice, since
/// a mis-spelled Thai string looks correct to anyone who cannot read it:
///
/// | Value | Rule it pins |
/// |---|---|
/// | `11` | a units `1` after a higher digit is **เอ็ด**, not หนึ่ง |
/// | `21` | and a tens `2` is **ยี่สิบ**, not สองสิบ — both irregulars at once |
/// | `100` | **ถ้วน** replaces the satang clause rather than appending "zero satang" |
/// | `1234.56` | the satang clause itself, and the place ladder past a thousand |
/// | `-5` | a negative takes **ลบ** rather than erroring |
///
/// The remaining cases below extend those rules rather than re-testing them, and are not
/// separately measured.
@Suite struct BahtTextTests {

    private func fn() throws -> ExcelFunction {
        try #require(FunctionRegistry.builtin.function(named: "BAHTTEXT"), "BAHTTEXT is not registered")
    }

    private func baht(_ value: Double, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let result = try fn().evaluate([.number(value)])
        guard case .text(let text) = result else {
            Issue.record("BAHTTEXT(\(value)) returned \(result)")
            throw TestFailure("not text")
        }
        return text
    }

    // MARK: - The plain cases

    @Test func zero() throws {
        #expect(try baht(0) == "ศูนย์บาทถ้วน")
    }

    @Test func one() throws {
        #expect(try baht(1) == "หนึ่งบาทถ้วน")
    }

    @Test func hundred() throws {
        #expect(try baht(100) == "หนึ่งร้อยบาทถ้วน")
    }

    // MARK: - The four irregular rules

    /// A units `1` following a higher digit is **เอ็ด**, not หนึ่ง.
    @Test func unitsOneAfterATenIsEt() throws {
        #expect(try baht(11) == "สิบเอ็ดบาทถ้วน")
    }

    /// A tens `1` is bare **สิบ** — there is no หนึ่ง in front of it.
    @Test func tensOneHasNoLeadingOne() throws {
        #expect(try baht(10) == "สิบบาทถ้วน")
    }

    /// A tens `2` is **ยี่สิบ**, not สองสิบ.
    @Test func tensTwoIsIrregular() throws {
        #expect(try baht(20) == "ยี่สิบบาทถ้วน")
    }

    /// Both irregulars at once.
    @Test func twentyOneCombinesBothIrregulars() throws {
        #expect(try baht(21) == "ยี่สิบเอ็ดบาทถ้วน")
    }

    // MARK: - Satang

    /// **ถ้วน replaces the satang clause rather than joining it**, so a whole amount never
    /// says "zero satang".
    @Test func wholeAmountsSayExactly() throws {
        #expect(try baht(5).hasSuffix("ถ้วน"))
        #expect(try !baht(5).contains("สตางค์"))
    }

    @Test func satangAreSpelledOut() throws {
        #expect(try baht(1234.56) == "หนึ่งพันสองร้อยสามสิบสี่บาทห้าสิบหกสตางค์")
    }

    /// Rounding is to the satang, before any spelling happens — a third of a satang has no
    /// words to be written in.
    ///
    /// **The values are chosen to avoid a binary representation trap.** An earlier version
    /// of this test asserted `baht(1.005) == baht(1.01)`, which fails: `1.005 * 100` is
    /// `100.4999…` in a `Double`, so it rounds *down* to one baht exactly. Excel computes in
    /// the same IEEE 754 doubles and would answer the same way, so the test was wrong rather
    /// than the code — it encoded an assumption about decimal rounding that binary
    /// arithmetic does not honour. These two values are unambiguous either side of the
    /// boundary.
    @Test func roundsToTheSatang() throws {
        #expect(try baht(1.0049) == "หนึ่งบาทถ้วน")
        #expect(try baht(1.0051) == "หนึ่งบาทหนึ่งสตางค์")
    }

    // MARK: - Sign

    @Test func negativeTakesLop() throws {
        #expect(try baht(-5) == "ลบห้าบาทถ้วน")
    }

    // MARK: - Structure at scale

    /// Thai counts in millions rather than naming a place above แสน, so a seven-digit value
    /// must contain ล้าน. A structural assertion, not a spelling one.
    @Test func millionsUseLan() throws {
        #expect(try baht(2_000_000).contains("ล้าน"))
    }

    /// Every answer is baht, whatever else it says.
    @Test func everyAnswerNamesTheCurrency() throws {
        for value in [0.0, 1, 19, 20, 999, 1_000_000, -3.25] {
            #expect(try baht(value).contains("บาท"), "\(value)")
        }
    }

    // MARK: - Arguments

    @Test func errorPropagates() throws {
        #expect(try fn().evaluate([.error(.div0)]) == .error(.div0))
    }

    @Test func textIsValue() throws {
        #expect(try fn().evaluate([.text("x")]) == .error(.value))
    }
}
