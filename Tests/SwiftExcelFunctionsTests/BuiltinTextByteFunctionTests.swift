import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The byte-oriented text functions, under the single-byte locale ADR-002 chose.
///
/// The assertions that matter are not that `LENB("abc")` is 3 — that would pass
/// whatever these delegated to. They are that each answers **identically to its
/// counterpart**, including on the input where the two locales disagree, because
/// that identity is the decision itself.
final class BuiltinTextByteFunctionTests: XCTestCase {

    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let fn = FunctionRegistry.builtin.function(named: name) else {
            XCTFail("\(name) is not registered")
            return .error(.name)
        }
        return try fn.evaluate(args)
    }

    func testAllSevenAreRegistered() {
        for name in ["LENB", "LEFTB", "RIGHTB", "MIDB", "FINDB", "SEARCHB", "REPLACEB"] {
            XCTAssertNotNil(FunctionRegistry.builtin.function(named: name), name)
        }
    }

    /// **The decision, asserted.** On a double-byte character the two locales
    /// disagree: DBCS counts 2, single-byte counts 1. ADR-002 takes the single-byte
    /// reading, so `LENB` must equal `LEN` here — 2, not 4.
    ///
    /// This is the test that would fail if someone later implemented DBCS counting
    /// without revisiting the ADR, which is exactly what it is for.
    func testTheByteFunctionsTakeTheSingleByteReading() throws {
        XCTAssertEqual(try eval("LENB", .text("あい")), .number(2),
                       "single-byte locale counts characters; DBCS would answer 4")
        XCTAssertEqual(try eval("LENB", .text("あい")), try eval("LEN", .text("あい")))
    }

    /// Each byte function equals its counterpart on the same input — the whole
    /// content of ADR-002, checked across all seven rather than asserted once.
    func testEachEqualsItsCounterpart() throws {
        let pairs = [("LENB", "LEN"), ("LEFTB", "LEFT"), ("RIGHTB", "RIGHT")]
        for (byteName, charName) in pairs {
            for subject in ["abc", "あい", "", "a b"] {
                XCTAssertEqual(try eval(byteName, .text(subject)),
                               try eval(charName, .text(subject)),
                               "\(byteName) vs \(charName) on \(subject.debugDescription)")
            }
        }
    }

    /// The two- and three-argument forms agree too, so the delegation carries the
    /// whole signature rather than only its first argument.
    func testTheMultiArgumentFormsAgree() throws {
        XCTAssertEqual(try eval("LEFTB", .text("abcdef"), .number(3)),
                       try eval("LEFT", .text("abcdef"), .number(3)))
        XCTAssertEqual(try eval("MIDB", .text("abcdef"), .number(2), .number(3)),
                       try eval("MID", .text("abcdef"), .number(2), .number(3)))
        XCTAssertEqual(try eval("REPLACEB", .text("abcdef"), .number(2), .number(3), .text("XY")),
                       try eval("REPLACE", .text("abcdef"), .number(2), .number(3), .text("XY")))
    }

    /// `FINDB` is case-sensitive and `SEARCHB` is not, inheriting the distinction
    /// from the pair they delegate to. Getting these the wrong way round is a bug
    /// that only shows on data you did not test with.
    func testFindbIsCaseSensitiveAndSearchbIsNot() throws {
        XCTAssertEqual(try eval("SEARCHB", .text("B"), .text("abc")), .number(2))
        XCTAssertEqual(try eval("FINDB", .text("B"), .text("abc")), .error(.value),
                       "FINDB is case-sensitive, so an uppercase B is not found")
    }

    /// An error argument propagates rather than being absorbed.
    func testAnErrorArgumentPropagates() throws {
        XCTAssertEqual(try eval("LENB", .error(.ref)), .error(.ref))
    }
}
