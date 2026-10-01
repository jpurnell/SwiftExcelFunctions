import Foundation
import SwiftExcelCore
import Foundation
import Testing
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
@Suite struct ComplexFunctionTests {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        let function = try #require(registry.function(named: name), "\(name) is not registered")
        return try function.evaluate(args)
    }

    private func text(_ name: String, _ args: CellValue...) throws -> String {
        let function = try #require(registry.function(named: name), "\(name) is not registered")
        let result = try function.evaluate(args)
        guard case .text(let s) = result else {
            Issue.record("\(name) returned \(result), not text"); return ""
        }
        return s
    }

    private func number(_ name: String, _ args: CellValue...) throws -> Double {
        let function = try #require(registry.function(named: name), "\(name) is not registered")
        let result = try function.evaluate(args)
        guard case .number(let v) = result else {
            Issue.record("\(name) returned \(result), not a number"); return .nan
        }
        return v
    }

    /// The real and imaginary parts of whatever a function returned.
    private func parts(_ value: CellValue) throws -> (Double, Double) {
        (try number("IMREAL", value), try number("IMAGINARY", value))
    }

    /// Whether two complex results agree, part by part, within `accuracy`.
    private func isSame(_ a: CellValue, _ b: CellValue, accuracy: Double = 1e-9) throws -> Bool {
        let (ar, ai) = try parts(a), (br, bi) = try parts(b)
        return ar.isClose(to: br, within: accuracy) && ai.isClose(to: bi, within: accuracy)
    }

    // MARK: - Registration

    @Test func allTwentySixComplexFunctionsAreRegistered() {
        let names = ["COMPLEX", "IMABS", "IMAGINARY", "IMARGUMENT", "IMCONJUGATE", "IMCOS",
                     "IMCOSH", "IMCOT", "IMCSC", "IMCSCH", "IMDIV", "IMEXP", "IMLN", "IMLOG10",
                     "IMLOG2", "IMPOWER", "IMPRODUCT", "IMREAL", "IMSEC", "IMSECH", "IMSIN",
                     "IMSINH", "IMSQRT", "IMSUB", "IMSUM", "IMTAN"]
        #expect(names.count == 26)
        for name in names {
            #expect(registry.resolvedName(name) == FunctionRegistry.canonical(name), "\(name) is not registered")
        }
    }

    // MARK: - The text format, which is the Excel-specific part

    @Test func complexBuildsTheTextFormAndTheAccessorsTakeItApart() throws {
        #expect(try text("COMPLEX", .number(3), .number(4)) == "3+4i")
        #expect(try text("COMPLEX", .number(3), .number(-4)) == "3-4i")
        #expect(try number("IMREAL", .text("3+4i")).isEqual(to: 3))
        #expect(try number("IMAGINARY", .text("3+4i")).isEqual(to: 4))
    }

    /// A complex number with no imaginary part is a bare real, with no suffix at all.
    @Test func aZeroImaginaryPartIsWrittenWithoutASuffix() throws {
        #expect(try text("COMPLEX", .number(7), .number(0)) == "7")
        #expect(try text("IMSUM", .text("3"), .text("4")) == "7")
    }

    /// A zero real part leaves the imaginary term standing alone, and the unit is bare.
    @Test func aZeroRealPartLeavesTheImaginaryTermAlone() throws {
        #expect(try text("COMPLEX", .number(0), .number(4)) == "4i")
        #expect(try text("COMPLEX", .number(0), .number(1)) == "i")
    }

    @Test func theJSuffixIsAcceptedAndCarriedThrough() throws {
        #expect(try text("COMPLEX", .number(3), .number(4), .text("j")) == "3+4j")
        #expect(try text("IMSUM", .text("1+1j"), .text("2+2j")) == "3+3j")
        #expect(try text("IMCONJUGATE", .text("3+4j")) == "3-4j")
    }

    /// Uppercase is refused — but the two ways of writing it give *different* errors.
    ///
    /// Microsoft says both are `#VALUE!`. Measured against Excel for Mac, an uppercase
    /// suffix inside an `inumber` is **`#NUM!`**, while an uppercase `suffix` argument to
    /// `COMPLEX` really is `#VALUE!`. The documentation is right about the refusal and
    /// wrong about half the error codes.
    ///
    /// The distinction is coherent once seen: text that cannot be read as a complex number
    /// is `#NUM!` however it fails, and `"banana"` and `"3+4"` already returned that. An
    /// argument of the wrong kind is `#VALUE!`, and `COMPLEX`'s suffix is an argument.
    @Test func anUppercaseSuffixIsRefused() throws {
        #expect(try call("IMABS", .text("3+4I")) == .error(.num))
        #expect(try call("IMABS", .text("3+4J")) == .error(.num))
        #expect(try call("COMPLEX", .number(3), .number(4), .text("I")) == .error(.value))
    }

    /// Excel writes the exponent marker in upper case.
    ///
    /// Measured on `IMPOWER("i", 2)`, which at the time produced an exponent in both. It no
    /// longer does — integer powers are multiplied out now — so the rule is pinned on a
    /// component small enough to need the notation on its own.
    @Test func anExponentMarkerIsUppercase() throws {
        #expect(try text("COMPLEX", .number(1e-20), .number(1)) == "1E-20+i")
        #expect(try text("COMPLEX", .number(1), .number(1e-20)) == "1+1E-20i")
    }

    /// Two routes to one answer must not disagree, which is this package's first principle.
    ///
    /// `IMPOWER("i", 2)` used to return `"-1+1.22464679914735E-16i"` while
    /// `IMPRODUCT("i", "i")` returned `"-1"`. Excel returns the artefact too, so this is a
    /// place where agreeing with Excel would have meant disagreeing with ourselves.
    ///
    /// The cause was swift-numerics: its `pow(z, n: Int)` is `exp(log(z) · n)` despite
    /// taking an `Int`, and `exp(iπ)` carries `sin` of the nearest `Double` to π, which is
    /// `1.2246e-16` rather than nought.
    @Test func anIntegerPowerIsTheProductAndNotALogarithm() throws {
        #expect(try text("IMPOWER", .text("i"), .number(2)) == "-1")
        #expect(try text("IMPOWER", .text("i"), .number(2)) == text("IMPRODUCT", .text("i"), .text("i")))
        #expect(try text("IMPOWER", .text("1+1i"), .number(3)) == text("IMPRODUCT", .text("1+1i"), .text("1+1i"), .text("1+1i")))
    }

    @Test func anIntegerPowerHandlesZeroAndNegativeExponents() throws {
        #expect(try text("IMPOWER", .text("2+3i"), .number(0)) == "1")
        // (1+i)² is 2i, so its reciprocal is −0.5i.
        #expect(try text("IMPOWER", .text("1+1i"), .number(-2)) == "-0.5i")
    }

    /// Excel writes each component to fifteen significant digits, and these return text, so
    /// the digits are the value rather than a presentation of it.
    @Test func componentsAreWrittenToFifteenSignificantDigits() throws {
        // Measured: Excel gives "-2+2i" here, not "-1.9999999999999996+2i".
        #expect(try text("IMPOWER", .text("1+1i"), .number(3)) == "-2+2i")
        #expect(try text("IMEXP", .text("1+1i")) == "1.46869393991589+2.28735528717884i")
        #expect(try text("IMLOG2", .text("3+4i")) == "2.32192809488736+1.33780421245098i")
    }

    @Test func textThatIsNotAComplexNumberIsANumError() throws {
        #expect(try call("IMABS", .text("banana")) == .error(.num))
        // A missing suffix is not an implied one.
        #expect(try call("IMABS", .text("3+4")) == .error(.num))
    }

    @Test func aPlainNumberIsAComplexNumberWithNoImaginaryPart() throws {
        #expect(try number("IMREAL", .number(5)).isEqual(to: 5))
        #expect(try number("IMAGINARY", .number(5)) == 0)
    }

    // MARK: - Arithmetic, asserted as inverses

    @Test func subtractionUndoesAddition() throws {
        let z: CellValue = .text("3+4i"), w: CellValue = .text("-1.5+2.25i")
        let sum = try call("IMSUM", z, w)
        #expect(try isSame(call("IMSUB", sum, w), z), "IMSUB must undo IMSUM")
    }

    @Test func divisionUndoesMultiplication() throws {
        let z: CellValue = .text("3+4i"), w: CellValue = .text("-1.5+2.25i")
        let product = try call("IMPRODUCT", z, w)
        #expect(try isSame(call("IMDIV", product, w), z), "IMDIV must undo IMPRODUCT")
    }

    @Test func sumAndProductAreVariadic() throws {
        #expect(try text("IMSUM", .text("1+1i"), .text("2+2i"), .text("3+3i")) == "6+6i")
        #expect(try isSame(call("IMPRODUCT", .text("1+1i"), .text("1+1i"), .text("1+1i")), call("IMPOWER", .text("1+1i"), .number(3))))
    }

    // MARK: - The transcendental identities

    @Test func exponentialUndoesLogarithm() throws {
        for z in ["3+4i", "-2+0.5i", "0.25-1.75i"] {
            #expect(try isSame(call("IMEXP", try call("IMLN", .text(z))), .text(z), accuracy: 1e-9), "IMEXP must undo IMLN for \(z)")
        }
    }

    @Test func squareRootSquaresBack() throws {
        for z in ["3+4i", "-2+0.5i"] {
            #expect(try isSame(call("IMPOWER", try call("IMSQRT", .text(z)), .number(2)), .text(z), accuracy: 1e-9), "IMSQRT then square must return \(z)")
        }
    }

    @Test func thePythagoreanIdentityHolds() throws {
        for z in ["1+1i", "0.5-2i"] {
            let sin2 = try call("IMPOWER", try call("IMSIN", .text(z)), .number(2))
            let cos2 = try call("IMPOWER", try call("IMCOS", .text(z)), .number(2))
            #expect(try isSame(call("IMSUM", sin2, cos2), .text("1"), accuracy: 1e-9), "sin² + cos² must be 1 at \(z)")
        }
    }

    @Test func theHyperbolicIdentityHolds() throws {
        // cosh² − sinh² = 1.
        for z in ["1+1i", "0.5-2i"] {
            let cosh2 = try call("IMPOWER", try call("IMCOSH", .text(z)), .number(2))
            let sinh2 = try call("IMPOWER", try call("IMSINH", .text(z)), .number(2))
            #expect(try isSame(call("IMSUB", cosh2, sinh2), .text("1"), accuracy: 1e-9), "cosh² − sinh² must be 1 at \(z)")
        }
    }

    /// The five reciprocal spellings are exactly that, and nothing more.
    @Test func theReciprocalFunctionsAreReciprocals() throws {
        let z: CellValue = .text("1+1i")
        let pairs = [("IMSEC", "IMCOS"), ("IMCSC", "IMSIN"), ("IMCOT", "IMTAN"),
                     ("IMSECH", "IMCOSH"), ("IMCSCH", "IMSINH")]
        for (reciprocal, base) in pairs {
            let expected = try call("IMDIV", .text("1"), try call(base, z))
            #expect(try isSame(call(reciprocal, z), expected, accuracy: 1e-9), "\(reciprocal) must be 1/\(base)")
        }
    }

    @Test func theLogarithmBasesAreChangesOfBase() throws {
        let z: CellValue = .text("3+4i")
        let ln = try call("IMLN", z)
        #expect(try isSame(call("IMLOG10", z), call("IMDIV", ln, .number(log(10.0))), accuracy: 1e-9))
        #expect(try isSame(call("IMLOG2", z), call("IMDIV", ln, .number(log(2.0))), accuracy: 1e-9))
    }

    // MARK: - Modulus, argument, conjugate

    @Test func absoluteValueIsTheHypotenuse() throws {
        #expect(try abs(number("IMABS", .text("3+4i")) - 5) <= 1e-12)
    }

    @Test func theArgumentRecoversTheAngleItWasBuiltFrom() throws {
        for theta in [0.3, 1.0, -2.0, 3.0] {
            let z = try call("COMPLEX", .number(cos(theta)), .number(sin(theta)))
            #expect(try abs(number("IMARGUMENT", z) - theta) <= 1e-9)
        }
    }

    @Test func conjugatingTwiceReturnsTheOriginal() throws {
        let z: CellValue = .text("3-4i")
        #expect(try isSame(call("IMCONJUGATE", try call("IMCONJUGATE", z)), z))
    }

    // MARK: - The domains Excel refuses

    @Test func theLogarithmOfZeroIsRefused() throws {
        #expect(try call("IMLN", .text("0")) == .error(.num))
        #expect(try call("IMLOG10", .text("0")) == .error(.num))
        #expect(try call("IMLOG2", .text("0")) == .error(.num))
    }

    @Test func divisionByZeroIsRefused() throws {
        #expect(try call("IMDIV", .text("3+4i"), .text("0")) == .error(.num))
    }

    @Test func theArgumentOfZeroIsRefused() throws {
        #expect(try call("IMARGUMENT", .text("0")) == .error(.div0))
    }

    @Test func anErrorArgumentPropagates() throws {
        #expect(try call("IMABS", .error(.na)) == .error(.na))
        #expect(try call("IMSUM", .text("1+1i"), .error(.div0)) == .error(.div0))
    }
}
