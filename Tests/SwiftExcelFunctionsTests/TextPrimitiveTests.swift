import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The text primitives from the unreviewed bucket.
///
/// Expected values are Microsoft's published examples. The interesting ones are where
/// Excel's behaviour is *not* the obvious behaviour — `T` of a number, `EXACT`'s case
/// sensitivity, `TEXTAFTER`'s negative instance.
final class TextPrimitiveTests: XCTestCase {

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        let fn = try XCTUnwrap(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
        return try fn.evaluate(args)
    }

    // MARK: - Characters and codes

    /// Published: `CHAR(65)` is `A`, `CODE("A")` is 65. `CODE` reads only the first
    /// character, so it is not the inverse of a whole string.
    func testCharacterAndCode() throws {
        XCTAssertEqual(try call("CHAR", .number(65)), .text("A"))
        XCTAssertEqual(try call("CODE", .text("A")), .number(65))
        XCTAssertEqual(try call("CODE", .text("Alphabet")), .number(65))
    }

    /// `CHAR` is defined on 1–255. Zero and beyond are `#VALUE!`.
    func testCharacterOutOfRange() throws {
        XCTAssertEqual(try call("CHAR", .number(0)), .error(.value))
        XCTAssertEqual(try call("CHAR", .number(256)), .error(.value))
        XCTAssertEqual(try call("CODE", .text("")), .error(.value))
    }

    // MARK: - Comparison

    /// **`EXACT` is case-sensitive, and `=` is not.** That difference is the entire reason
    /// the function exists. Published: `EXACT("word","word")` is TRUE,
    /// `EXACT("Word","word")` is FALSE.
    func testExactIsCaseSensitive() throws {
        XCTAssertEqual(try call("EXACT", .text("word"), .text("word")), .bool(true))
        XCTAssertEqual(try call("EXACT", .text("Word"), .text("word")), .bool(false))
        XCTAssertEqual(try call("EXACT", .text("w ord"), .text("word")), .bool(false))
    }

    // MARK: - Building strings

    /// Published: `REPT("*-", 3)` is `*-*-*-`. A count of zero is the empty string, not an
    /// error.
    func testRepeat() throws {
        XCTAssertEqual(try call("REPT", .text("*-"), .number(3)), .text("*-*-*-"))
        XCTAssertEqual(try call("REPT", .text("x"), .number(0)), .text(""))
        XCTAssertEqual(try call("REPT", .text("x"), .number(-1)), .error(.value))
    }

    /// `CONCAT` joins everything with no separator; `TEXTJOIN` takes one and can skip
    /// blanks. Published: `TEXTJOIN(" ", TRUE, "The","sun","will","come","up")` is
    /// `The sun will come up`.
    func testJoining() throws {
        XCTAssertEqual(try call("CONCAT", .text("a"), .text("b"), .text("c")), .text("abc"))
        XCTAssertEqual(
            try call("TEXTJOIN", .text(" "), .bool(true),
                     .text("The"), .text("sun"), .text("will"), .text("come"), .text("up")),
            .text("The sun will come up"))
    }

    /// **`ignore_empty` is the whole point of the third argument.** With `FALSE` the blank
    /// contributes a delimiter; with `TRUE` it contributes nothing.
    func testTextJoinHonoursIgnoreEmpty() throws {
        XCTAssertEqual(
            try call("TEXTJOIN", .text("-"), .bool(false), .text("a"), .text(""), .text("b")),
            .text("a--b"))
        XCTAssertEqual(
            try call("TEXTJOIN", .text("-"), .bool(true), .text("a"), .text(""), .text("b")),
            .text("a-b"))
    }

    // MARK: - Splitting

    /// Published: `TEXTBEFORE("Red riding hood's, red hood", " ")` is `Red`, and
    /// `TEXTAFTER` of the same is `riding hood's, red hood`.
    func testTextBeforeAndAfter() throws {
        let sentence = CellValue.text("Red riding hood")
        XCTAssertEqual(try call("TEXTBEFORE", sentence, .text(" ")), .text("Red"))
        XCTAssertEqual(try call("TEXTAFTER", sentence, .text(" ")), .text("riding hood"))
    }

    /// **A negative instance counts from the end.** `TEXTAFTER(text, " ", -1)` takes the
    /// last space, which is how you get a final word without knowing how many there are.
    func testNegativeInstanceCountsFromTheEnd() throws {
        let sentence = CellValue.text("one two three")
        XCTAssertEqual(try call("TEXTAFTER", sentence, .text(" "), .number(-1)), .text("three"))
        XCTAssertEqual(try call("TEXTBEFORE", sentence, .text(" "), .number(-1)), .text("one two"))
    }

    /// A delimiter that does not occur is `#N/A` — the question is well-formed and the
    /// answer does not exist.
    func testMissingDelimiterIsNotAvailable() throws {
        XCTAssertEqual(try call("TEXTAFTER", .text("abc"), .text("|")), .error(.na))
    }

    // MARK: - Replacing by position

    /// Published: `REPLACE("abcdefghijk", 6, 5, "*")` is `abcde*k`. Position is 1-based.
    func testReplaceByPosition() throws {
        XCTAssertEqual(
            try call("REPLACE", .text("abcdefghijk"), .number(6), .number(5), .text("*")),
            .text("abcde*k"))
        XCTAssertEqual(
            try call("REPLACE", .text("2009"), .number(3), .number(2), .text("10")),
            .text("2010"))
    }

    // MARK: - Numbers as text, and back

    /// **`T` returns text unchanged and everything else as empty.** Published: `T("Rainfall")`
    /// is `Rainfall`, `T(19)` is empty — *not* "19". It tests a type rather than converting one.
    func testTReturnsOnlyText() throws {
        XCTAssertEqual(try call("T", .text("Rainfall")), .text("Rainfall"))
        XCTAssertEqual(try call("T", .number(19)), .text(""))
        XCTAssertEqual(try call("T", .bool(true)), .text(""))
    }

    /// Published: `VALUE("$1,000")` is 1000, `VALUE("16:48:00")` is a time serial. Text
    /// that is not a number is `#VALUE!`.
    func testValueParsesNumbers() throws {
        XCTAssertEqual(try call("VALUE", .text("1000")), .number(1000))
        XCTAssertEqual(try call("VALUE", .text("$1,000")), .number(1000))
        XCTAssertEqual(try call("VALUE", .text("  42  ")), .number(42))
        XCTAssertEqual(try call("VALUE", .text("abc")), .error(.value))
    }

    /// Published: `FIXED(1234.567, 1)` is `1,234.6`, and with `no_commas` TRUE it is
    /// `1234.6`. Rounding happens before formatting.
    func testFixedFormatsWithRounding() throws {
        XCTAssertEqual(try call("FIXED", .number(1234.567), .number(1)), .text("1,234.6"))
        XCTAssertEqual(
            try call("FIXED", .number(1234.567), .number(1), .bool(true)), .text("1234.6"))
        XCTAssertEqual(try call("FIXED", .number(1234.567), .number(-1)), .text("1,230"))
    }
}
