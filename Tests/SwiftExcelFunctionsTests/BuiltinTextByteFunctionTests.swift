import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The byte-oriented text functions, under the single-byte locale ADR-002 chose.
///
/// The assertions that matter are not that `LENB("abc")` is 3 — that would pass
/// whatever these delegated to. They are that each answers **identically to its
/// counterpart**, including on the input where the two locales disagree, because
/// that identity is the decision itself.
@Suite struct BuiltinTextByteFunctionTests {

    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let fn = FunctionRegistry.builtin.function(named: name) else {
            Issue.record("\(name) is not registered")
            return .error(.name)
        }
        return try fn.evaluate(args)
    }

    @Test func allSevenAreRegistered() {
        for name in ["LENB", "LEFTB", "RIGHTB", "MIDB", "FINDB", "SEARCHB", "REPLACEB"] {
            #expect(FunctionRegistry.builtin.resolvedName(name) == FunctionRegistry.canonical(name), "\(name)")
        }
    }

    /// **The decision, asserted.** On a double-byte character the two locales
    /// disagree: DBCS counts 2, single-byte counts 1. ADR-002 takes the single-byte
    /// reading, so `LENB` must equal `LEN` here — 2, not 4.
    ///
    /// This is the test that would fail if someone later implemented DBCS counting
    /// without revisiting the ADR, which is exactly what it is for.
    @Test func theByteFunctionsTakeTheSingleByteReading() throws {
        #expect(try eval("LENB", .text("あい")) == .number(2), "single-byte locale counts characters; DBCS would answer 4")
        #expect(try eval("LENB", .text("あい")) == eval("LEN", .text("あい")))
    }

    /// Each byte function equals its counterpart on the same input — the whole
    /// content of ADR-002, checked across all seven rather than asserted once.
    @Test func eachEqualsItsCounterpart() throws {
        let pairs = [("LENB", "LEN"), ("LEFTB", "LEFT"), ("RIGHTB", "RIGHT")]
        for (byteName, charName) in pairs {
            for subject in ["abc", "あい", "", "a b"] {
                #expect(try eval(byteName, .text(subject)) == eval(charName, .text(subject)), "\(byteName) vs \(charName) on \(subject.debugDescription)")
            }
        }
    }

    /// The two- and three-argument forms agree too, so the delegation carries the
    /// whole signature rather than only its first argument.
    @Test func theMultiArgumentFormsAgree() throws {
        #expect(try eval("LEFTB", .text("abcdef"), .number(3)) == eval("LEFT", .text("abcdef"), .number(3)))
        #expect(try eval("MIDB", .text("abcdef"), .number(2), .number(3)) == eval("MID", .text("abcdef"), .number(2), .number(3)))
        #expect(try eval("REPLACEB", .text("abcdef"), .number(2), .number(3), .text("XY")) == eval("REPLACE", .text("abcdef"), .number(2), .number(3), .text("XY")))
    }

    /// `FINDB` is case-sensitive and `SEARCHB` is not, inheriting the distinction
    /// from the pair they delegate to. Getting these the wrong way round is a bug
    /// that only shows on data you did not test with.
    @Test func findbIsCaseSensitiveAndSearchbIsNot() throws {
        #expect(try eval("SEARCHB", .text("B"), .text("abc")) == .number(2))
        #expect(try eval("FINDB", .text("B"), .text("abc")) == .error(.value), "FINDB is case-sensitive, so an uppercase B is not found")
    }

    /// An error argument propagates rather than being absorbed.
    @Test func anErrorArgumentPropagates() throws {
        #expect(try eval("LENB", .error(.ref)) == .error(.ref))
    }
}
