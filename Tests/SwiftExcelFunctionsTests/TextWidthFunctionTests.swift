import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// `DBCS`, `JIS` and `ASC` — the width conversions, in both directions.
///
/// `DBCS` and `JIS` are **one function under two names**, which is Microsoft's own account:
/// "the name of the function (and the characters that it converts) depends upon your
/// language settings." `JIS` is what Japanese-language Excel calls `DBCS`. Both spellings
/// register, because a workbook may carry either, and both reach one implementation, because
/// two would drift. `ASC` is the inverse.
///
/// **Neither direction is a per-character map**, which is the fact the whole file is
/// arranged around. Widening composes — `ｶ` + `ﾞ` becomes the single `ガ`, so the string gets
/// shorter — and narrowing decomposes it again, so the string gets longer. A space is
/// asymmetric too: its wide form is the ideographic space `U+3000`, in a different block
/// from the rest. An implementation written as "add `0xFEE0` to every printable scalar" gets
/// Latin text entirely right and both of these wrong.
final class TextWidthFunctionTests: XCTestCase {

    private func fn(_ name: String) throws -> ExcelFunction {
        try XCTUnwrap(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
    }

    private func text(_ name: String, _ input: CellValue, line: UInt = #line) throws -> String {
        let result = try fn(name).evaluate([input])
        guard case .text(let value) = result else {
            XCTFail("\(name) returned \(result)", line: line)
            throw XCTSkip("not text")
        }
        return value
    }

    // MARK: - Latin

    func testLatinLettersBecomeFullWidth() throws {
        XCTAssertEqual(try text("DBCS", .text("abc")), "ａｂｃ")
        XCTAssertEqual(try text("DBCS", .text("XYZ")), "ＸＹＺ")
    }

    func testDigitsBecomeFullWidth() throws {
        XCTAssertEqual(try text("DBCS", .text("123")), "１２３")
    }

    /// **A space is not `U+FF00 + 0x20`.** The arithmetic that maps the rest of ASCII into
    /// the full-width block does not apply to the space: its full-width form is the
    /// ideographic space `U+3000`, which sits in a different block entirely. An
    /// implementation written as "add `0xFEE0` to everything printable" gets every other
    /// character right and this one wrong.
    func testSpaceBecomesTheIdeographicSpace() throws {
        XCTAssertEqual(try text("DBCS", .text(" ")), "\u{3000}")
        XCTAssertEqual(try text("DBCS", .text("a b")), "ａ\u{3000}ｂ")
    }

    func testPunctuationBecomesFullWidth() throws {
        XCTAssertEqual(try text("DBCS", .text("!?")), "！？")
    }

    // MARK: - Katakana

    /// Half-width katakana have full-width counterparts in a different block again.
    func testHalfWidthKatakanaBecomeFullWidth() throws {
        XCTAssertEqual(try text("DBCS", .text("ｱｲｳ")), "アイウ")
    }

    /// **The voiced mark composes rather than converting.** Half-width writes `ｶ` followed
    /// by a separate `ﾞ`; full-width writes the single character `ガ`. So the conversion is
    /// not character-by-character — two code points become one, and the string gets shorter.
    func testVoicedKatakanaComposeIntoOneCharacter() throws {
        let converted = try text("DBCS", .text("ｶﾞ"))
        XCTAssertEqual(converted, "ガ")
        XCTAssertEqual(converted.unicodeScalars.count, 1)
    }

    /// The semi-voiced mark likewise: `ﾊ` + `ﾟ` becomes `パ`.
    func testSemiVoicedKatakanaCompose() throws {
        XCTAssertEqual(try text("DBCS", .text("ﾊﾟ")), "パ")
    }

    // MARK: - What is left alone

    /// Already full-width input is unchanged — the function widens, it does not toggle.
    func testFullWidthInputIsUnchanged() throws {
        XCTAssertEqual(try text("DBCS", .text("ＡＢＣ")), "ＡＢＣ")
        XCTAssertEqual(try text("DBCS", .text("アイウ")), "アイウ")
    }

    /// Characters with no half-width form pass through.
    func testUnaffectedCharactersPassThrough() throws {
        XCTAssertEqual(try text("DBCS", .text("日本語")), "日本語")
        XCTAssertEqual(try text("DBCS", .text("")), "")
    }

    // MARK: - The two names

    /// **The assertion that defends the decision.** On Latin text either implementation
    /// looks right; on composing katakana a naive per-character mapping diverges. Testing
    /// the two names agree *there* is what would catch someone later giving `JIS` its own
    /// implementation.
    func testJISAndDBCSAgreeOnTheHardCase() throws {
        for input in ["ｶﾞｷﾞｸﾞ", "ﾊﾟﾋﾟﾌﾟ", "a b!", "ｱｲｳ"] {
            XCTAssertEqual(try text("JIS", .text(input)),
                           try text("DBCS", .text(input)),
                           "disagreed on \(input)")
        }
    }

    // MARK: - ASC, the inverse

    func testASCNarrowsLatin() throws {
        XCTAssertEqual(try text("ASC", .text("ＡＢＣ")), "ABC")
        XCTAssertEqual(try text("ASC", .text("１２３")), "123")
    }

    /// The ideographic space narrows back to an ordinary one — the same asymmetry as
    /// widening, in reverse.
    func testASCNarrowsTheIdeographicSpace() throws {
        XCTAssertEqual(try text("ASC", .text("\u{3000}")), " ")
    }

    /// **The mirror of the composing case, and the reason it is worth its own test.**
    /// Widening turns two scalars into one; narrowing turns one into two, so the string
    /// gets *longer*. `ガ` becomes `ｶ` followed by a separate `ﾞ`.
    func testASCDecomposesVoicedKatakana() throws {
        let narrowed = try text("ASC", .text("ガ"))
        XCTAssertEqual(narrowed, "ｶﾞ")
        XCTAssertEqual(narrowed.unicodeScalars.count, 2)
    }

    func testASCLeavesHalfWidthAlone() throws {
        XCTAssertEqual(try text("ASC", .text("abc")), "abc")
        XCTAssertEqual(try text("ASC", .text("ｱｲｳ")), "ｱｲｳ")
    }

    func testASCLeavesKanjiAlone() throws {
        XCTAssertEqual(try text("ASC", .text("日本語")), "日本語")
    }

    /// **The relationship that ties the two together.** For any half-width input, widening
    /// then narrowing returns it — including the composing katakana, where each direction
    /// changes the scalar count and only a correct pair puts it back. Asserting the
    /// round-trip catches a mismatched pair that two independent one-way tests would not.
    func testWideningThenNarrowingRoundTrips() throws {
        for input in ["abc", "123", "a b!", "ｱｲｳ", "ｶﾞｷﾞ", "ﾊﾟﾋﾟ"] {
            let widened = try text("DBCS", .text(input))
            XCTAssertEqual(try text("ASC", .text(widened)), input, "round trip of \(input)")
        }
    }

    // MARK: - Coercion

    /// A number is rendered before widening, as it is everywhere else in the text family.
    func testNumbersAreCoercedToText() throws {
        XCTAssertEqual(try text("DBCS", .number(42)), "４２")
    }

    /// An error propagates rather than being widened into nonsense.
    func testErrorPropagates() throws {
        XCTAssertEqual(try fn("DBCS").evaluate([.error(.na)]), .error(.na))
    }
}
