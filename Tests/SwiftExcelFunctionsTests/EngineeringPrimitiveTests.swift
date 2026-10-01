import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The engineering primitives — base conversion, bitwise, step functions, the error
/// function.
///
/// Every expected value below is one Microsoft publishes on the function's own reference
/// page. ADR-001: reading a specification and asserting our reading of it proves only that
/// we read it the same way twice.
@Suite struct EngineeringPrimitiveTests {

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        let fn = try #require(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
        return try fn.evaluate(args)
    }

    private func text(_ value: CellValue) throws -> String {
        guard case .text(let t) = value else { throw TestFailure("expected text, got \(value)") }
        return t
    }

    // MARK: - Base conversion

    /// Published: `BIN2HEX(11111011, 4)` is `00FB`, `BIN2HEX(1110)` is `E`.
    @Test func binaryToHexadecimal() throws {
        #expect(try text(try call("BIN2HEX", .text("11111011"), .number(4))) == "00FB")
        #expect(try text(try call("BIN2HEX", .text("1110"))) == "E")
    }

    /// Published: `BIN2OCT(1001, 3)` is `011`, `BIN2OCT(1100100)` is `144`.
    @Test func binaryToOctal() throws {
        #expect(try text(try call("BIN2OCT", .text("1001"), .number(3))) == "011")
        #expect(try text(try call("BIN2OCT", .text("1100100"))) == "144")
    }

    /// **The tenth bit is a sign bit.** Published: `BIN2HEX(1111111111)` is `FFFFFFFFFF`
    /// and `BIN2OCT(1111111111)` is `7777777777` — both are −1 in two's complement, not
    /// 1023. Reading the input as unsigned gives a plausible number that is wrong by 1024.
    @Test func theTopBitIsASignBit() throws {
        #expect(try text(try call("BIN2HEX", .text("1111111111"))) == "FFFFFFFFFF")
        #expect(try text(try call("BIN2OCT", .text("1111111111"))) == "7777777777")
    }

    /// Published: `HEX2BIN("F", 8)` is `00001111`, `HEX2BIN("B7")` is `10110111`,
    /// `HEX2BIN("FFFFFFFFFF")` is `1111111111`.
    @Test func hexadecimalToBinary() throws {
        #expect(try text(try call("HEX2BIN", .text("F"), .number(8))) == "00001111")
        #expect(try text(try call("HEX2BIN", .text("B7"))) == "10110111")
        #expect(try text(try call("HEX2BIN", .text("FFFFFFFFFF"))) == "1111111111")
    }

    /// Published: `HEX2OCT("F", 3)` is `017`, `HEX2OCT("3B4E")` is `35516`,
    /// `HEX2OCT("FFFFFFFF00")` is `7777777400`.
    @Test func hexadecimalToOctal() throws {
        #expect(try text(try call("HEX2OCT", .text("F"), .number(3))) == "017")
        #expect(try text(try call("HEX2OCT", .text("3B4E"))) == "35516")
        #expect(try text(try call("HEX2OCT", .text("FFFFFFFF00"))) == "7777777400")
    }

    /// Published: `OCT2BIN(3, 3)` is `011`, `OCT2BIN(7777777000)` is `1000000000`.
    @Test func octalToBinary() throws {
        #expect(try text(try call("OCT2BIN", .text("3"), .number(3))) == "011")
        #expect(try text(try call("OCT2BIN", .text("7777777000"))) == "1000000000")
    }

    /// Published: `OCT2HEX(100, 4)` is `0040`, `OCT2HEX(7777777533)` is `FFFFFFFF5B`.
    @Test func octalToHexadecimal() throws {
        #expect(try text(try call("OCT2HEX", .text("100"), .number(4))) == "0040")
        #expect(try text(try call("OCT2HEX", .text("7777777533"))) == "FFFFFFFF5B")
    }

    /// A result too wide for the places requested is `#NUM!`, not a truncation.
    @Test func tooFewPlacesIsNum() throws {
        #expect(try call("BIN2HEX", .text("11111011"), .number(1)) == .error(.num))
    }

    /// An input longer than ten characters is out of range, and a digit outside the base
    /// is not a number in it.
    @Test func malformedInputIsNum() throws {
        #expect(try call("BIN2HEX", .text("11111111111")) == .error(.num))
        #expect(try call("BIN2OCT", .text("1012")) == .error(.num))
        #expect(try call("HEX2BIN", .text("XYZ")) == .error(.num))
    }

    // MARK: - Bitwise

    /// Published: `BITAND(13,25)` is 9, `BITOR(23,10)` is 31, `BITXOR(5,3)` is 6.
    @Test func bitwiseCombination() throws {
        #expect(try call("BITAND", .number(13), .number(25)) == .number(9))
        #expect(try call("BITOR", .number(23), .number(10)) == .number(31))
        #expect(try call("BITXOR", .number(5), .number(3)) == .number(6))
    }

    /// Published: `BITLSHIFT(4,2)` is 16, `BITRSHIFT(13,2)` is 3.
    ///
    /// A **negative** shift reverses direction, which is why `BITLSHIFT(4,-2)` is 1 rather
    /// than an error.
    @Test func bitwiseShifting() throws {
        #expect(try call("BITLSHIFT", .number(4), .number(2)) == .number(16))
        #expect(try call("BITRSHIFT", .number(13), .number(2)) == .number(3))
        #expect(try call("BITLSHIFT", .number(4), .number(-2)) == .number(1))
    }

    /// The bitwise family is defined on non-negative integers below 2⁴⁸. Anything else is
    /// `#NUM!` rather than a two's-complement reinterpretation.
    @Test func bitwiseRejectsNegativesAndFractions() throws {
        #expect(try call("BITAND", .number(-1), .number(1)) == .error(.num))
        #expect(try call("BITAND", .number(1.5), .number(1)) == .error(.num))
        #expect(try call("BITLSHIFT", .number(1), .number(54)) == .error(.num))
    }

    // MARK: - Step functions

    /// Published: `DELTA(5,4)` is 0, `DELTA(5,5)` is 1. The second argument defaults to 0.
    @Test func delta() throws {
        #expect(try call("DELTA", .number(5), .number(4)) == .number(0))
        #expect(try call("DELTA", .number(5), .number(5)) == .number(1))
        #expect(try call("DELTA", .number(0)) == .number(1))
    }

    /// Published: `GESTEP(5,4)` is 1, `GESTEP(-4,-5)` is 1, `GESTEP(-1,0)` is 0.
    @Test func geStep() throws {
        #expect(try call("GESTEP", .number(5), .number(4)) == .number(1))
        #expect(try call("GESTEP", .number(-4), .number(-5)) == .number(1))
        #expect(try call("GESTEP", .number(-1), .number(0)) == .number(0))
    }

    // MARK: - The error function

    /// Published: `ERF(1)` is 0.842700793, `ERFC(1)` is 0.157299207 — and the two sum to 1
    /// by definition, which is the relation rather than our arithmetic.
    @Test func errorFunction() throws {
        guard case .number(let erf) = try call("ERF", .number(1)),
              case .number(let erfc) = try call("ERFC", .number(1))
        else { Issue.record("expected numbers"); return }

        #expect(abs(erf - 0.842700793) <= 1e-9)
        #expect(abs(erfc - 0.157299207) <= 1e-9)
        #expect(abs((erf + erfc) - 1) <= 1e-15)
    }

    /// `ERF(lower, upper)` integrates between the two, so it is the difference of the
    /// one-argument forms. Published: `ERF(0.745)` is 0.707928921.
    ///
    /// This assertion was written with the wrong constant first — 0.678801305, which is
    /// not Microsoft's value for anything on that page — and the implementation was right.
    /// Worth leaving the note: ADR-001 guards against trusting our reading of a
    /// specification, and it cuts both ways. A misremembered "published" value fails a
    /// correct function and would have been fixed in the wrong place.
    @Test func errorFunctionBetweenLimits() throws {
        guard case .number(let single) = try call("ERF", .number(0.745)),
              case .number(let between) = try call("ERF", .number(0.745), .number(1)),
              case .number(let toOne) = try call("ERF", .number(1))
        else { Issue.record("expected numbers"); return }

        #expect(abs(single - 0.707928921) <= 1e-9)
        #expect(abs(between - (toOne - single)) <= 1e-12)
    }

    /// The `.PRECISE` spellings take a single argument and are otherwise the same.
    @Test func preciseSpellings() throws {
        #expect(try call("ERF.PRECISE", .number(1)) == call("ERF", .number(1)))
        #expect(try call("ERFC.PRECISE", .number(1)) == call("ERFC", .number(1)))
    }
}
