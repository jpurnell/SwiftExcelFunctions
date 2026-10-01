import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The text primitives from the unreviewed bucket.
///
/// Expected values are Microsoft's published examples. The interesting ones are where
/// Excel's behaviour is *not* the obvious behaviour — `T` of a number, `EXACT`'s case
/// sensitivity, `TEXTAFTER`'s negative instance.
@Suite struct TextPrimitiveTests {

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        let fn = try #require(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
        return try fn.evaluate(args)
    }

    // MARK: - Characters and codes

    /// Published: `CHAR(65)` is `A`, `CODE("A")` is 65. `CODE` reads only the first
    /// character, so it is not the inverse of a whole string.
    @Test func characterAndCode() throws {
        #expect(try call("CHAR", .number(65)) == .text("A"))
        #expect(try call("CODE", .text("A")) == .number(65))
        #expect(try call("CODE", .text("Alphabet")) == .number(65))
    }

    /// `CHAR` is defined on 1–255. Zero and beyond are `#VALUE!`.
    @Test func characterOutOfRange() throws {
        #expect(try call("CHAR", .number(0)) == .error(.value))
        #expect(try call("CHAR", .number(256)) == .error(.value))
        #expect(try call("CODE", .text("")) == .error(.value))
    }

    // MARK: - Comparison

    /// **`EXACT` is case-sensitive, and `=` is not.** That difference is the entire reason
    /// the function exists. Published: `EXACT("word","word")` is TRUE,
    /// `EXACT("Word","word")` is FALSE.
    @Test func exactIsCaseSensitive() throws {
        #expect(try call("EXACT", .text("word"), .text("word")) == .bool(true))
        #expect(try call("EXACT", .text("Word"), .text("word")) == .bool(false))
        #expect(try call("EXACT", .text("w ord"), .text("word")) == .bool(false))
    }

    // MARK: - Building strings

    /// Published: `REPT("*-", 3)` is `*-*-*-`. A count of zero is the empty string, not an
    /// error.
    @Test func repetition() throws {
        #expect(try call("REPT", .text("*-"), .number(3)) == .text("*-*-*-"))
        #expect(try call("REPT", .text("x"), .number(0)) == .text(""))
        #expect(try call("REPT", .text("x"), .number(-1)) == .error(.value))
    }

    /// `CONCAT` joins everything with no separator; `TEXTJOIN` takes one and can skip
    /// blanks. Published: `TEXTJOIN(" ", TRUE, "The","sun","will","come","up")` is
    /// `The sun will come up`.
    @Test func joining() throws {
        #expect(try call("CONCAT", .text("a"), .text("b"), .text("c")) == .text("abc"))
        #expect(try call("TEXTJOIN", .text(" "), .bool(true),
                     .text("The"), .text("sun"), .text("will"), .text("come"), .text("up")) == .text("The sun will come up"))
    }

    /// **`ignore_empty` is the whole point of the third argument.** With `FALSE` the blank
    /// contributes a delimiter; with `TRUE` it contributes nothing.
    @Test func textJoinHonoursIgnoreEmpty() throws {
        #expect(try call("TEXTJOIN", .text("-"), .bool(false), .text("a"), .text(""), .text("b")) == .text("a--b"))
        #expect(try call("TEXTJOIN", .text("-"), .bool(true), .text("a"), .text(""), .text("b")) == .text("a-b"))
    }

    // MARK: - Splitting

    /// Published: `TEXTBEFORE("Red riding hood's, red hood", " ")` is `Red`, and
    /// `TEXTAFTER` of the same is `riding hood's, red hood`.
    @Test func textBeforeAndAfter() throws {
        let sentence = CellValue.text("Red riding hood")
        #expect(try call("TEXTBEFORE", sentence, .text(" ")) == .text("Red"))
        #expect(try call("TEXTAFTER", sentence, .text(" ")) == .text("riding hood"))
    }

    /// **A negative instance counts from the end.** `TEXTAFTER(text, " ", -1)` takes the
    /// last space, which is how you get a final word without knowing how many there are.
    @Test func negativeInstanceCountsFromTheEnd() throws {
        let sentence = CellValue.text("one two three")
        #expect(try call("TEXTAFTER", sentence, .text(" "), .number(-1)) == .text("three"))
        #expect(try call("TEXTBEFORE", sentence, .text(" "), .number(-1)) == .text("one two"))
    }

    /// A delimiter that does not occur is `#N/A` — the question is well-formed and the
    /// answer does not exist.
    @Test func missingDelimiterIsNotAvailable() throws {
        #expect(try call("TEXTAFTER", .text("abc"), .text("|")) == .error(.na))
    }

    // MARK: - Replacing by position

    /// Published: `REPLACE("abcdefghijk", 6, 5, "*")` is `abcde*k`. Position is 1-based.
    @Test func replaceByPosition() throws {
        #expect(try call("REPLACE", .text("abcdefghijk"), .number(6), .number(5), .text("*")) == .text("abcde*k"))
        #expect(try call("REPLACE", .text("2009"), .number(3), .number(2), .text("10")) == .text("2010"))
    }

    // MARK: - Numbers as text, and back

    /// **`T` returns text unchanged and everything else as empty.** Published: `T("Rainfall")`
    /// is `Rainfall`, `T(19)` is empty — *not* "19". It tests a type rather than converting one.
    @Test func tReturnsOnlyText() throws {
        #expect(try call("T", .text("Rainfall")) == .text("Rainfall"))
        #expect(try call("T", .number(19)) == .text(""))
        #expect(try call("T", .bool(true)) == .text(""))
    }

    /// Published: `VALUE("$1,000")` is 1000, `VALUE("16:48:00")` is a time serial. Text
    /// that is not a number is `#VALUE!`.
    @Test func valueParsesNumbers() throws {
        #expect(try call("VALUE", .text("1000")) == .number(1000))
        #expect(try call("VALUE", .text("$1,000")) == .number(1000))
        #expect(try call("VALUE", .text("  42  ")) == .number(42))
        #expect(try call("VALUE", .text("abc")) == .error(.value))
    }

    /// Published: `FIXED(1234.567, 1)` is `1,234.6`, and with `no_commas` TRUE it is
    /// `1234.6`. Rounding happens before formatting.
    @Test func fixedFormatsWithRounding() throws {
        #expect(try call("FIXED", .number(1234.567), .number(1)) == .text("1,234.6"))
        #expect(try call("FIXED", .number(1234.567), .number(1), .bool(true)) == .text("1234.6"))
        #expect(try call("FIXED", .number(1234.567), .number(-1)) == .text("1,230"))
    }
}
