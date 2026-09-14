import BusinessMath
import ComplexModule
import Foundation
// `Argument` carries a `Complex<Double>`, and naming that type in an enum's associated
// value needs the module that gives `Double` its `Real` conformance to be in scope here —
// importing `ComplexModule` alone compiles but warns on a clean build.
import RealModule
import SwiftExcelCore

/// `COMPLEX` and the twenty-five `IM*` functions.
///
/// ## Where the work actually is
///
/// Not in the arithmetic. swift-numerics has every operation this family needs, and
/// BusinessMath supplies the `a+bi` codec, so each binding is parse → call → format. The
/// mathematics is nobody's problem here.
///
/// The work is the **text**, because Excel's complex numbers are strings and the rules about
/// those strings are entirely Excel's:
///
/// - The suffix is `i` or `j`, and **never** `I` or `J` — uppercase is `#VALUE!`, which the
///   BusinessMath parser accepts happily, so the strictness has to live here.
/// - A result carries the suffix its arguments used, and arguments that disagree are refused.
/// - A number with no imaginary part is written as a bare real: `COMPLEX(7, 0)` is `"7"`, not
///   `"7+0i"`. A number with no real part is the imaginary term alone, and the unit is `"i"`.
/// - Text that is not a complex number is `#NUM!`, not `#VALUE!` — and `"3+4"` is not one,
///   because a missing suffix is not an implied suffix.
///
/// ## Provenance
///
/// The uppercase rule is Microsoft's, quoted. **That two different suffixes in one call give
/// `#VALUE!` is inferred, not documented**, and no workbook in the 2,240-file corpus calls any
/// of these functions, so nothing here was measured against Excel. It is the one rule in this
/// file worth settling with a hand-built workbook.
public enum BuiltinComplexFunctions {

    /// Every complex function, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        complexOf, imAbs, imaginaryPart, imArgument, imConjugate, imCos, imCosh, imCot,
        imCsc, imCsch, imDiv, imExp, imLn, imLog10, imLog2, imPower, imProduct, realPart,
        imSec, imSech, imSin, imSinh, imSqrt, imSub, imSum, imTan,
    ]

    // MARK: - Reading and writing Excel's text form

    /// What one complex argument parsed to.
    private enum Argument {
        /// A complex number, and the suffix it was written with if it had one.
        case ready(Complex<Double>, suffix: Character?)
        /// Not a complex number, and this is what the cell should say.
        case refused(CellValue)
    }

    /// Reads one argument as a complex number.
    private static func parse(_ value: CellValue) -> Argument {
        switch value {
        case .error:
            return .refused(value)
        case .number(let real):
            return .ready(Complex(real, 0), suffix: nil)
        case .blank:
            return .ready(Complex(0, 0), suffix: nil)
        case .text(let written):
            // Microsoft says uppercase gives #VALUE!. **Excel gives #NUM!**, measured:
            // `IMABS("3+4I")` returns #NUM! in Excel for Mac. The documentation is right
            // about the refusal and wrong about the error, which is the fifth time this
            // project has found it wrong about something checkable.
            //
            // #NUM! is also the more coherent answer. An argument of the wrong *kind* is
            // #VALUE!; text that is the right kind and cannot be read is #NUM!, which is
            // already what `"banana"` and `"3+4"` return. An uppercase suffix is the third
            // way of writing something unreadable, not a different sort of mistake.
            guard !written.contains("I"), !written.contains("J") else {
                return .refused(.error(.num))
            }
            guard let number = Complex<Double>(notation: written) else {
                // Not a complex number is #NUM!, not #VALUE! — Excel distinguishes text
                // that means nothing from an argument of the wrong kind entirely.
                return .refused(.error(.num))
            }
            let suffix = written.last.flatMap { $0 == "i" || $0 == "j" ? $0 : nil }
            return .ready(number, suffix: suffix)
        default:
            // A boolean, a date or a range is not a complex number by any reading.
            return .refused(.error(.value))
        }
    }

    /// The suffix a result should carry.
    ///
    /// - Parameter suffixes: What each argument was written with, `nil` where it was a bare
    ///   number carrying no suffix at all.
    /// - Returns: The agreed suffix, defaulting to `i`, or `nil` if two arguments disagreed.
    private static func agreedSuffix(_ suffixes: [Character?]) -> Character? {
        let stated = Set(suffixes.compactMap { $0 })
        guard stated.count <= 1 else { return nil }
        return stated.first ?? "i"
    }

    /// A component as Excel writes it: fifteen significant digits.
    ///
    /// Measured, not assumed. Excel returned `"-2+2i"` for `IMPOWER("1+1i", 3)` where this
    /// package wrote `"-1.9999999999999996+2i"`, and `"1.46869393991589+2.28735528717884i"`
    /// for `IMEXP("1+1i")` against seventeen digits here. Rounding each component to fifteen
    /// significant figures reproduces all five components of those answers exactly.
    ///
    /// It matters more than tidiness: these functions return **text**, so the digits are the
    /// value. `-1.9999999999999996+2i` and `-2+2i` are different answers, and any caller
    /// comparing strings — which is the only thing `IM*` output supports — sees two
    /// different complex numbers.
    /// Rounded through a decimal representation rather than by arithmetic, because the
    /// arithmetic is subtly wrong: scaling by a power of ten, rounding and scaling back
    /// double-rounds, and it put `1.4686939399158851` one digit out at
    /// `1.46869393991588` against Excel's `…89`. A decimal round-trip is the operation
    /// actually being asked for.
    ///
    /// The locale is fixed: this produces a number to be parsed, not read, and a decimal
    /// comma would make it unparseable in about half the world.
    private static func fifteenSignificantDigits(_ value: Double) -> Double {
        guard value.isFinite else { return value }
        let decimal = value.formatted(
            .number.precision(.significantDigits(15))
                .grouping(.never)
                .locale(Locale(identifier: "en_US_POSIX")))
        return Double(decimal) ?? value
    }

    /// Writes a complex number in Excel's text form.
    private static func written(_ number: Complex<Double>, suffix: Character) -> CellValue {
        // A non-finite result is a domain Excel reports rather than a string it writes, and
        // this is what turns `IMLN("0")` and division by zero into `#NUM!` without either
        // needing a guard of its own.
        guard number.isFinite else { return .error(.num) }
        let rounded = Complex(fifteenSignificantDigits(number.real),
                              fifteenSignificantDigits(number.imaginary))
        // Excel writes the exponent marker in upper case: `1.22464679914735E-16`, against
        // Swift's `e-16`. Measured on `IMPOWER("i", 2)`, where every digit of the two
        // answers matched and only the letter differed — and since these functions return
        // text, a letter is as much of a difference as a digit.
        //
        // `e+` and `e-` can only be an exponent here: the rest of the string is digits, a
        // sign, a point, and the suffix at the very end.
        var text = rounded.notation
            .replacingOccurrences(of: "e-", with: "E-")
            .replacingOccurrences(of: "e+", with: "E+")
        // The codec writes `i` only, by design: one canonical form. Excel lets the caller
        // choose, and the choice is only ever the final character.
        if suffix == "j", text.hasSuffix("i") {
            text.removeLast()
            text.append("j")
        }
        return .text(text)
    }

    // MARK: - Shapes

    /// A function of one complex number that returns another.
    private static func transform(
        _ name: String,
        _ compute: @escaping @Sendable (Complex<Double>) -> Complex<Double>
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 1, maxArgs: 1) { values in
            switch parse(values[0]) {
            case .refused(let error): return error
            case .ready(let number, let suffix):
                return written(compute(number), suffix: suffix ?? "i")
            }
        }
    }

    /// A function of one complex number that returns a real one.
    private static func measure(
        _ name: String,
        _ compute: @escaping @Sendable (Complex<Double>) -> CellValue
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 1, maxArgs: 1) { values in
            switch parse(values[0]) {
            case .refused(let error): return error
            case .ready(let number, _): return compute(number)
            }
        }
    }

    /// A function folding two or more complex numbers together.
    private static func fold(
        _ name: String, minArgs: Int, maxArgs: Int?,
        _ combine: @escaping @Sendable (Complex<Double>, Complex<Double>) -> Complex<Double>
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: minArgs, maxArgs: maxArgs) { values in
            var numbers: [Complex<Double>] = []
            var suffixes: [Character?] = []
            for value in values {
                switch parse(value) {
                case .refused(let error): return error
                case .ready(let number, let suffix):
                    numbers.append(number)
                    suffixes.append(suffix)
                }
            }
            guard let suffix = agreedSuffix(suffixes) else { return .error(.value) }
            guard let first = numbers.first else { return .error(.value) }
            return written(numbers.dropFirst().reduce(first, combine), suffix: suffix)
        }
    }

    // MARK: - Building and taking apart

    /// `COMPLEX(real_num, i_num, [suffix])` — the text form, from its two parts.
    public static let complexOf = ExcelFunction(
        name: "COMPLEX", minArgs: 2, maxArgs: 3
    ) { values in
        if let error = BuiltinStatisticalDistributions.firstError(values) { return error }
        guard let real = BuiltinStatisticalDistributions.real(values.first),
              let imaginary = BuiltinStatisticalDistributions.real(values[1])
        else { return .error(.value) }

        var suffix: Character = "i"
        if values.count > 2 {
            guard case .text(let requested) = values[2], requested.count == 1,
                  let character = requested.first, character == "i" || character == "j"
            else { return .error(.value) }
            suffix = character
        }
        return written(Complex(real, imaginary), suffix: suffix)
    }

    /// `IMREAL(inumber)` — the real part, as a number.
    public static let realPart = measure("IMREAL") { .number($0.real) }

    /// `IMAGINARY(inumber)` — the imaginary part, as a number.
    public static let imaginaryPart = measure("IMAGINARY") { .number($0.imaginary) }

    /// `IMABS(inumber)` — the modulus.
    public static let imAbs = measure("IMABS") { .number($0.length) }

    /// `IMARGUMENT(inumber)` — the angle in radians.
    ///
    /// Zero has no argument — every angle describes it equally — and Excel says so with
    /// `#DIV/0!` rather than returning the zero that `atan2(0, 0)` would hand back.
    public static let imArgument = measure("IMARGUMENT") { number in
        guard !number.isZero else { return .error(.div0) }
        let phase = number.phase
        guard phase.isFinite else { return .error(.num) }
        return .number(phase)
    }

    /// `IMCONJUGATE(inumber)` — the conjugate.
    public static let imConjugate = transform("IMCONJUGATE") { $0.conjugate }

    // MARK: - Arithmetic

    /// `IMSUM(inumber1, [inumber2], …)`.
    public static let imSum = fold("IMSUM", minArgs: 1, maxArgs: nil) { $0 + $1 }

    /// `IMSUB(inumber1, inumber2)`.
    public static let imSub = fold("IMSUB", minArgs: 2, maxArgs: 2) { $0 - $1 }

    /// `IMPRODUCT(inumber1, [inumber2], …)`.
    public static let imProduct = fold("IMPRODUCT", minArgs: 1, maxArgs: nil) { $0 * $1 }

    /// `IMDIV(inumber1, inumber2)` — division by zero arrives as `#NUM!`, not `#DIV/0!`.
    public static let imDiv = fold("IMDIV", minArgs: 2, maxArgs: 2) { $0 / $1 }

    /// `IMPOWER(inumber, number)` — a complex number to a **real** power.
    ///
    /// An integral exponent goes through the integer overload, which multiplies rather than
    /// taking a logarithm and back; `IMPOWER(z, 3)` and `IMPRODUCT(z, z, z)` agree exactly
    /// that way and only approximately otherwise.
    public static let imPower = ExcelFunction(
        name: "IMPOWER", minArgs: 2, maxArgs: 2
    ) { values in
        guard let exponent = BuiltinStatisticalDistributions.real(values[1]) else {
            if case .error = values[1] { return values[1] }
            return .error(.value)
        }
        switch parse(values[0]) {
        case .refused(let error):
            return error
        case .ready(let number, let suffix):
            let result: Complex<Double>
            if exponent == exponent.rounded(), abs(exponent) <= 1024 {
                result = Complex.pow(number, Int(exponent))
            } else {
                result = Complex.pow(number, Complex(exponent, 0))
            }
            return written(result, suffix: suffix ?? "i")
        }
    }

    // MARK: - Exponential and logarithmic

    /// `IMEXP(inumber)`.
    public static let imExp = transform("IMEXP") { Complex.exp($0) }

    /// `IMLN(inumber)` — the natural logarithm. `IMLN("0")` is `#NUM!`.
    public static let imLn = transform("IMLN") { Complex.log($0) }

    /// `IMLOG10(inumber)` — a change of base on ``imLn``, which is Excel's own definition.
    public static let imLog10 = transform("IMLOG10") { Complex.log($0) / Complex(log(10.0), 0) }

    /// `IMLOG2(inumber)` — likewise.
    public static let imLog2 = transform("IMLOG2") { Complex.log($0) / Complex(log(2.0), 0) }

    /// `IMSQRT(inumber)` — the principal square root.
    public static let imSqrt = transform("IMSQRT") { Complex.sqrt($0) }

    // MARK: - Trigonometric, hyperbolic, and their reciprocals

    /// `IMSIN(inumber)`.
    public static let imSin = transform("IMSIN") { Complex.sin($0) }

    /// `IMCOS(inumber)`.
    public static let imCos = transform("IMCOS") { Complex.cos($0) }

    /// `IMTAN(inumber)`.
    public static let imTan = transform("IMTAN") { Complex.tan($0) }

    /// `IMSINH(inumber)`.
    public static let imSinh = transform("IMSINH") { Complex.sinh($0) }

    /// `IMCOSH(inumber)`.
    public static let imCosh = transform("IMCOSH") { Complex.cosh($0) }

    /// `IMCSC(inumber)` — the reciprocal of ``imSin``.
    ///
    /// The five reciprocal spellings are written as divisions rather than implemented. There
    /// is no second algorithm to get wrong: a reciprocal can only disagree with the function
    /// it inverts if the division is wrong, which is why these stay here rather than going
    /// upstream the way the Bessel functions did.
    public static let imCsc = transform("IMCSC") { Complex(1, 0) / Complex.sin($0) }

    /// `IMSEC(inumber)` — the reciprocal of ``imCos``.
    public static let imSec = transform("IMSEC") { Complex(1, 0) / Complex.cos($0) }

    /// `IMCOT(inumber)` — the reciprocal of ``imTan``.
    public static let imCot = transform("IMCOT") { Complex(1, 0) / Complex.tan($0) }

    /// `IMCSCH(inumber)` — the reciprocal of ``imSinh``.
    public static let imCsch = transform("IMCSCH") { Complex(1, 0) / Complex.sinh($0) }

    /// `IMSECH(inumber)` — the reciprocal of ``imCosh``.
    public static let imSech = transform("IMSECH") { Complex(1, 0) / Complex.cosh($0) }
}
