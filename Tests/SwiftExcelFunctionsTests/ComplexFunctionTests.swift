import Foundation
import SwiftExcelCore
import XCTest
@testable import SwiftExcelFunctions

/// Excel's complex family — `COMPLEX` and the twenty-five `IM*` functions.
///
/// ## Relationships, not constants
///
/// `IMTAN("1+1i")` is `0.271752585319512+1.08392332733869i`, and nobody can check that by
/// eye. A table of such values tests the transcription. These tests assert the identities
/// instead — that `IMEXP` undoes `IMLN`, that sine squared plus cosine squared is one, that
/// `IMSEC` is the reciprocal of `IMCOS` — because an implementation cannot satisfy those by
/// accident and a misremembered digit cannot break them.
///
/// ## What is Excel's, and therefore ours
///
/// The arithmetic is swift-numerics'. The *text* is Excel's, and that is where this family
/// goes wrong: the suffix must be `i` or `j` and never `I` or `J`, a result carries the
/// suffix its arguments used, and a complex number with no imaginary part is written as a
/// bare real with no suffix at all.
final class ComplexFunctionTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        let function = try XCTUnwrap(registry.function(named: name), "\(name) is not registered")
        return try function.evaluate(args)
    }

    private func text(_ name: String, _ args: CellValue...) throws -> String {
        let function = try XCTUnwrap(registry.function(named: name), "\(name) is not registered")
        let result = try function.evaluate(args)
        guard case .text(let s) = result else {
            XCTFail("\(name) returned \(result), not text"); return ""
        }
        return s
    }

    private func number(_ name: String, _ args: CellValue...) throws -> Double {
        let function = try XCTUnwrap(registry.function(named: name), "\(name) is not registered")
        let result = try function.evaluate(args)
        guard case .number(let v) = result else {
            XCTFail("\(name) returned \(result), not a number"); return .nan
        }
        return v
    }

    /// The real and imaginary parts of whatever a function returned.
    private func parts(_ value: CellValue) throws -> (Double, Double) {
        (try number("IMREAL", value), try number("IMAGINARY", value))
    }

    private func assertSame(_ a: CellValue, _ b: CellValue,
                            accuracy: Double = 1e-9, _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let (ar, ai) = try parts(a), (br, bi) = try parts(b)
        XCTAssertEqual(ar, br, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(ai, bi, accuracy: accuracy, message, file: file, line: line)
    }

    // MARK: - Registration

    func testAllTwentySixComplexFunctionsAreRegistered() {
        let names = ["COMPLEX", "IMABS", "IMAGINARY", "IMARGUMENT", "IMCONJUGATE", "IMCOS",
                     "IMCOSH", "IMCOT", "IMCSC", "IMCSCH", "IMDIV", "IMEXP", "IMLN", "IMLOG10",
                     "IMLOG2", "IMPOWER", "IMPRODUCT", "IMREAL", "IMSEC", "IMSECH", "IMSIN",
                     "IMSINH", "IMSQRT", "IMSUB", "IMSUM", "IMTAN"]
        XCTAssertEqual(names.count, 26)
        for name in names {
            XCTAssertNotNil(registry.function(named: name), "\(name) is not registered")
        }
    }

    // MARK: - The text format, which is the Excel-specific part

    func testComplexBuildsTheTextFormAndTheAccessorsTakeItApart() throws {
        XCTAssertEqual(try text("COMPLEX", .number(3), .number(4)), "3+4i")
        XCTAssertEqual(try text("COMPLEX", .number(3), .number(-4)), "3-4i")
        XCTAssertEqual(try number("IMREAL", .text("3+4i")), 3)
        XCTAssertEqual(try number("IMAGINARY", .text("3+4i")), 4)
    }

    /// A complex number with no imaginary part is a bare real, with no suffix at all.
    func testAZeroImaginaryPartIsWrittenWithoutASuffix() throws {
        XCTAssertEqual(try text("COMPLEX", .number(7), .number(0)), "7")
        XCTAssertEqual(try text("IMSUM", .text("3"), .text("4")), "7")
    }

    /// A zero real part leaves the imaginary term standing alone, and the unit is bare.
    func testAZeroRealPartLeavesTheImaginaryTermAlone() throws {
        XCTAssertEqual(try text("COMPLEX", .number(0), .number(4)), "4i")
        XCTAssertEqual(try text("COMPLEX", .number(0), .number(1)), "i")
    }

    func testTheJSuffixIsAcceptedAndCarriedThrough() throws {
        XCTAssertEqual(try text("COMPLEX", .number(3), .number(4), .text("j")), "3+4j")
        XCTAssertEqual(try text("IMSUM", .text("1+1j"), .text("2+2j")), "3+3j")
        XCTAssertEqual(try text("IMCONJUGATE", .text("3+4j")), "3-4j")
    }

    /// Microsoft: *"All complex number functions accept 'i' and 'j' for suffix, but neither
    /// 'I' nor 'J'. Using uppercase results in the #VALUE! error value."*
    func testAnUppercaseSuffixIsAValueError() throws {
        XCTAssertEqual(try call("IMABS", .text("3+4I")), .error(.value))
        XCTAssertEqual(try call("IMABS", .text("3+4J")), .error(.value))
        XCTAssertEqual(try call("COMPLEX", .number(3), .number(4), .text("I")), .error(.value))
    }

    func testTextThatIsNotAComplexNumberIsANumError() throws {
        XCTAssertEqual(try call("IMABS", .text("banana")), .error(.num))
        // A missing suffix is not an implied one.
        XCTAssertEqual(try call("IMABS", .text("3+4")), .error(.num))
    }

    func testAPlainNumberIsAComplexNumberWithNoImaginaryPart() throws {
        XCTAssertEqual(try number("IMREAL", .number(5)), 5)
        XCTAssertEqual(try number("IMAGINARY", .number(5)), 0)
    }

    // MARK: - Arithmetic, asserted as inverses

    func testSubtractionUndoesAddition() throws {
        let z: CellValue = .text("3+4i"), w: CellValue = .text("-1.5+2.25i")
        let sum = try call("IMSUM", z, w)
        try assertSame(try call("IMSUB", sum, w), z, "IMSUB must undo IMSUM")
    }

    func testDivisionUndoesMultiplication() throws {
        let z: CellValue = .text("3+4i"), w: CellValue = .text("-1.5+2.25i")
        let product = try call("IMPRODUCT", z, w)
        try assertSame(try call("IMDIV", product, w), z, "IMDIV must undo IMPRODUCT")
    }

    func testSumAndProductAreVariadic() throws {
        XCTAssertEqual(try text("IMSUM", .text("1+1i"), .text("2+2i"), .text("3+3i")), "6+6i")
        try assertSame(try call("IMPRODUCT", .text("1+1i"), .text("1+1i"), .text("1+1i")),
                       try call("IMPOWER", .text("1+1i"), .number(3)))
    }

    // MARK: - The transcendental identities

    func testExponentialUndoesLogarithm() throws {
        for z in ["3+4i", "-2+0.5i", "0.25-1.75i"] {
            try assertSame(try call("IMEXP", try call("IMLN", .text(z))), .text(z),
                           accuracy: 1e-9, "IMEXP must undo IMLN for \(z)")
        }
    }

    func testSquareRootSquaresBack() throws {
        for z in ["3+4i", "-2+0.5i"] {
            try assertSame(try call("IMPOWER", try call("IMSQRT", .text(z)), .number(2)),
                           .text(z), accuracy: 1e-9, "IMSQRT then square must return \(z)")
        }
    }

    func testThePythagoreanIdentityHolds() throws {
        for z in ["1+1i", "0.5-2i"] {
            let sin2 = try call("IMPOWER", try call("IMSIN", .text(z)), .number(2))
            let cos2 = try call("IMPOWER", try call("IMCOS", .text(z)), .number(2))
            try assertSame(try call("IMSUM", sin2, cos2), .text("1"),
                           accuracy: 1e-9, "sin² + cos² must be 1 at \(z)")
        }
    }

    func testTheHyperbolicIdentityHolds() throws {
        // cosh² − sinh² = 1.
        for z in ["1+1i", "0.5-2i"] {
            let cosh2 = try call("IMPOWER", try call("IMCOSH", .text(z)), .number(2))
            let sinh2 = try call("IMPOWER", try call("IMSINH", .text(z)), .number(2))
            try assertSame(try call("IMSUB", cosh2, sinh2), .text("1"),
                           accuracy: 1e-9, "cosh² − sinh² must be 1 at \(z)")
        }
    }

    /// The five reciprocal spellings are exactly that, and nothing more.
    func testTheReciprocalFunctionsAreReciprocals() throws {
        let z: CellValue = .text("1+1i")
        let pairs = [("IMSEC", "IMCOS"), ("IMCSC", "IMSIN"), ("IMCOT", "IMTAN"),
                     ("IMSECH", "IMCOSH"), ("IMCSCH", "IMSINH")]
        for (reciprocal, base) in pairs {
            let expected = try call("IMDIV", .text("1"), try call(base, z))
            try assertSame(try call(reciprocal, z), expected,
                           accuracy: 1e-9, "\(reciprocal) must be 1/\(base)")
        }
    }

    func testTheLogarithmBasesAreChangesOfBase() throws {
        let z: CellValue = .text("3+4i")
        let ln = try call("IMLN", z)
        try assertSame(try call("IMLOG10", z),
                       try call("IMDIV", ln, .number(log(10.0))), accuracy: 1e-9)
        try assertSame(try call("IMLOG2", z),
                       try call("IMDIV", ln, .number(log(2.0))), accuracy: 1e-9)
    }

    // MARK: - Modulus, argument, conjugate

    func testAbsoluteValueIsTheHypotenuse() throws {
        XCTAssertEqual(try number("IMABS", .text("3+4i")), 5, accuracy: 1e-12)
    }

    func testTheArgumentRecoversTheAngleItWasBuiltFrom() throws {
        for theta in [0.3, 1.0, -2.0, 3.0] {
            let z = try call("COMPLEX", .number(cos(theta)), .number(sin(theta)))
            XCTAssertEqual(try number("IMARGUMENT", z), theta, accuracy: 1e-9)
        }
    }

    func testConjugatingTwiceReturnsTheOriginal() throws {
        let z: CellValue = .text("3-4i")
        try assertSame(try call("IMCONJUGATE", try call("IMCONJUGATE", z)), z)
    }

    // MARK: - The domains Excel refuses

    func testTheLogarithmOfZeroIsRefused() throws {
        XCTAssertEqual(try call("IMLN", .text("0")), .error(.num))
        XCTAssertEqual(try call("IMLOG10", .text("0")), .error(.num))
        XCTAssertEqual(try call("IMLOG2", .text("0")), .error(.num))
    }

    func testDivisionByZeroIsRefused() throws {
        XCTAssertEqual(try call("IMDIV", .text("3+4i"), .text("0")), .error(.num))
    }

    func testTheArgumentOfZeroIsRefused() throws {
        XCTAssertEqual(try call("IMARGUMENT", .text("0")), .error(.div0))
    }

    func testAnErrorArgumentPropagates() throws {
        XCTAssertEqual(try call("IMABS", .error(.na)), .error(.na))
        XCTAssertEqual(try call("IMSUM", .text("1+1i"), .error(.div0)), .error(.div0))
    }
}
