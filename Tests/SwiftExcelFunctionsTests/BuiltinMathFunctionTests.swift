import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

@Suite struct BuiltinMathFunctionTests {

    // MARK: - Helpers

    /// Look up a function by name from the built-in math set.
    private func function(named name: String) -> ExcelFunction {
        guard let fn = BuiltinMathFunctions.all.first(where: { $0.name == name }) else {
            fatalError("Function \(name) not found in BuiltinMathFunctions.all")
        }
        return fn
    }

    /// Evaluate a function by name with the given arguments.
    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        try function(named: name).evaluate(args)
    }



    // MARK: - Registration count

    /// By name rather than by count: a count says something changed without
    /// saying what, and fails identically whether a function arrived or went.
    @Test func allContainsEveryFunctionInTheGroup() {
        #expect(Set(BuiltinMathFunctions.all.map(\.name)) == ["ABS", "ROUND", "ROUNDUP", "ROUNDDOWN", "SQRT", "LN", "LOG", "EXP",
             "POWER", "MOD", "INT", "CEILING", "FLOOR", "SIGN", "PI",
             "RAND", "RANDBETWEEN",
             "SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "ATAN2",
             "LOG10", "TRUNC", "PRODUCT", "GCD", "LCM",
             "DEC2HEX", "DEC2BIN", "DEC2OCT", "HEX2DEC", "BIN2DEC", "OCT2DEC",
             "BASE", "DECIMAL"])
    }

    // MARK: - ABS

    @Test func absPositive() throws {
        let result = try eval("ABS", .number(5))
        #expect(result.isNumber(5))
    }

    @Test func absNegative() throws {
        let result = try eval("ABS", .number(-3.7))
        #expect(result.isNumber(3.7))
    }

    @Test func absZero() throws {
        let result = try eval("ABS", .number(0))
        #expect(result.isNumber(0))
    }

    // MARK: - ROUND

    @Test func roundPositiveDigits() throws {
        let result = try eval("ROUND", .number(1234.567), .number(2))
        #expect(result.isNumber(1234.57))
    }

    @Test func roundNegativeDigits() throws {
        let result = try eval("ROUND", .number(1234), .number(-2))
        #expect(result.isNumber(1200))
    }

    @Test func roundZeroDigits() throws {
        let result = try eval("ROUND", .number(3.5), .number(0))
        #expect(result.isNumber(4))
    }

    // MARK: - ROUNDUP

    @Test func roundupPositive() throws {
        let result = try eval("ROUNDUP", .number(3.2), .number(0))
        #expect(result.isNumber(4))
    }

    @Test func roundupNegative() throws {
        let result = try eval("ROUNDUP", .number(-3.2), .number(0))
        #expect(result.isNumber(-4))
    }

    @Test func roundupWithDigits() throws {
        let result = try eval("ROUNDUP", .number(3.14159), .number(2))
        #expect(result.isNumber(3.15))
    }

    // MARK: - ROUNDDOWN

    @Test func rounddownPositive() throws {
        let result = try eval("ROUNDDOWN", .number(3.9), .number(0))
        #expect(result.isNumber(3))
    }

    @Test func rounddownNegative() throws {
        let result = try eval("ROUNDDOWN", .number(-3.9), .number(0))
        #expect(result.isNumber(-3))
    }

    @Test func rounddownWithDigits() throws {
        let result = try eval("ROUNDDOWN", .number(3.149), .number(1))
        #expect(result.isNumber(3.1))
    }

    // MARK: - SQRT

    @Test func sqrtPositive() throws {
        let result = try eval("SQRT", .number(25))
        #expect(result.isNumber(5))
    }

    @Test func sqrtZero() throws {
        let result = try eval("SQRT", .number(0))
        #expect(result.isNumber(0))
    }

    @Test func sqrtNegativeReturnsNumError() throws {
        let result = try eval("SQRT", .number(-4))
        #expect(result == .error(.num))
    }

    // MARK: - LN

    @Test func lnPositive() throws {
        let result = try eval("LN", .number(1))
        #expect(result.isNumber(0))
    }

    @Test func lnEuler() throws {
        let result = try eval("LN", .number(Darwin.M_E))
        #expect(result.isNumber(1, within: 1e-10))
    }

    @Test func lnZeroReturnsNumError() throws {
        let result = try eval("LN", .number(0))
        #expect(result == .error(.num))
    }

    @Test func lnNegativeReturnsNumError() throws {
        let result = try eval("LN", .number(-5))
        #expect(result == .error(.num))
    }

    // MARK: - LOG

    @Test func logOneArgBase10() throws {
        let result = try eval("LOG", .number(100))
        #expect(result.isNumber(2))
    }

    @Test func logTwoArgsCustomBase() throws {
        let result = try eval("LOG", .number(8), .number(2))
        #expect(result.isNumber(3, within: 1e-10))
    }

    @Test func logBase10Explicit() throws {
        let result = try eval("LOG", .number(1000), .number(10))
        #expect(result.isNumber(3, within: 1e-10))
    }

    // MARK: - EXP

    @Test func expBasic() throws {
        let result = try eval("EXP", .number(1))
        #expect(result.isNumber(Darwin.M_E, within: 1e-10))
    }

    @Test func expZero() throws {
        let result = try eval("EXP", .number(0))
        #expect(result.isNumber(1))
    }

    @Test func expNegative() throws {
        let result = try eval("EXP", .number(-1))
        #expect(result.isNumber(1.0 / Darwin.M_E, within: 1e-10))
    }

    // MARK: - POWER

    @Test func powerBasic() throws {
        let result = try eval("POWER", .number(2), .number(10))
        #expect(result.isNumber(1024))
    }

    @Test func powerFractionalExponent() throws {
        let result = try eval("POWER", .number(9), .number(0.5))
        #expect(result.isNumber(3, within: 1e-10))
    }

    @Test func powerZeroExponent() throws {
        let result = try eval("POWER", .number(5), .number(0))
        #expect(result.isNumber(1))
    }

    // MARK: - MOD

    @Test func modPositivePositive() throws {
        let result = try eval("MOD", .number(7), .number(3))
        #expect(result.isNumber(1))
    }

    @Test func modNegativePositive() throws {
        // Excel: MOD(-7, 3) = 2 (not -1 like Swift %)
        let result = try eval("MOD", .number(-7), .number(3))
        #expect(result.isNumber(2))
    }

    @Test func modPositiveNegative() throws {
        // Excel: MOD(7, -3) = -2
        let result = try eval("MOD", .number(7), .number(-3))
        #expect(result.isNumber(-2))
    }

    @Test func modDivideByZero() throws {
        let result = try eval("MOD", .number(7), .number(0))
        #expect(result == .error(.div0))
    }

    // MARK: - INT

    @Test func intPositive() throws {
        // INT(3.7) = 3
        let result = try eval("INT", .number(3.7))
        #expect(result.isNumber(3))
    }

    @Test func intNegative() throws {
        // INT(-3.7) = -4 (floor toward negative infinity)
        let result = try eval("INT", .number(-3.7))
        #expect(result.isNumber(-4))
    }

    @Test func intWholeNumber() throws {
        let result = try eval("INT", .number(5))
        #expect(result.isNumber(5))
    }

    // MARK: - CEILING

    @Test func ceilingPositive() throws {
        // CEILING(2.1, 1) = 3
        let result = try eval("CEILING", .number(2.1), .number(1))
        #expect(result.isNumber(3))
    }

    @Test func ceilingNegative() throws {
        // CEILING(-2.1, -1) = -3
        let result = try eval("CEILING", .number(-2.1), .number(-1))
        #expect(result.isNumber(-3))
    }

    @Test func ceilingMultiple() throws {
        // CEILING(4.42, 0.05) = 4.45
        let result = try eval("CEILING", .number(4.42), .number(0.05))
        #expect(result.isNumber(4.45, within: 1e-10))
    }

    @Test func ceilingZeroSignificance() throws {
        let result = try eval("CEILING", .number(2.5), .number(0))
        #expect(result.isNumber(0))
    }

    // MARK: - FLOOR

    @Test func floorPositive() throws {
        // FLOOR(2.7, 1) = 2
        let result = try eval("FLOOR", .number(2.7), .number(1))
        #expect(result.isNumber(2))
    }

    @Test func floorNegative() throws {
        // FLOOR(-2.7, -1) = -3 (note: Excel FLOOR requires same sign for number and significance)
        let result = try eval("FLOOR", .number(-2.7), .number(-1))
        #expect(result.isNumber(-3, within: 1e-10))
    }

    @Test func floorMultiple() throws {
        // FLOOR(4.48, 0.05) = 4.45
        let result = try eval("FLOOR", .number(4.48), .number(0.05))
        #expect(result.isNumber(4.45, within: 1e-10))
    }

    // MARK: - SIGN

    @Test func signPositive() throws {
        let result = try eval("SIGN", .number(42))
        #expect(result.isNumber(1))
    }

    @Test func signNegative() throws {
        let result = try eval("SIGN", .number(-3.5))
        #expect(result.isNumber(-1))
    }

    @Test func signZero() throws {
        let result = try eval("SIGN", .number(0))
        #expect(result.isNumber(0))
    }

    // MARK: - PI

    @Test func pi() throws {
        let result = try eval("PI")
        #expect(result.isNumber(Double.pi, within: 1e-14))
    }

    // MARK: - Error propagation

    @Test func errorPropagation() throws {
        // Passing an error into any function should propagate the error.
        let functions = ["ABS", "SQRT", "LN", "EXP", "SIGN", "INT"]
        for name in functions {
            let result = try eval(name, .error(.value))
            #expect(result == .error(.value))
        }
    }

    @Test func errorPropagationTwoArgs() throws {
        let functions = ["ROUND", "ROUNDUP", "ROUNDDOWN", "POWER", "MOD", "CEILING", "FLOOR"]
        for name in functions {
            let result = try eval(name, .error(.ref), .number(1))
            #expect(result == .error(.ref))
        }
    }

    @Test func errorPropagationSecondArg() throws {
        let functions = ["ROUND", "ROUNDUP", "ROUNDDOWN", "POWER", "MOD", "CEILING", "FLOOR"]
        for name in functions {
            let result = try eval(name, .number(1), .error(.na))
            #expect(result == .error(.na))
        }
    }

    // MARK: - Type coercion

    @Test func typeCoercionTextToNumber() throws {
        let result = try eval("ABS", .text("5"))
        #expect(result.isNumber(5))
    }

    @Test func typeCoercionTextNonNumericReturnsError() throws {
        let result = try eval("ABS", .text("abc"))
        #expect(result == .error(.value))
    }

    @Test func typeCoercionBoolTrue() throws {
        let result = try eval("ABS", .bool(true))
        #expect(result.isNumber(1))
    }

    @Test func typeCoercionBoolFalse() throws {
        let result = try eval("ABS", .bool(false))
        #expect(result.isNumber(0))
    }

    @Test func typeCoercionBlank() throws {
        let result = try eval("ABS", .blank)
        #expect(result.isNumber(0))
    }

    // MARK: - ExcelFunction metadata

    @Test func piHasZeroArgs() {
        let pi = function(named: "PI")
        #expect(pi.minArgs == 0)
        #expect(pi.maxArgs == 0)
    }

    @Test func logHasOptionalSecondArg() {
        let log = function(named: "LOG")
        #expect(log.minArgs == 1)
        #expect(log.maxArgs == 2)
    }

    @Test func absHasExactlyOneArg() {
        let abs = function(named: "ABS")
        #expect(abs.minArgs == 1)
        #expect(abs.maxArgs == 1)
    }

    @Test func roundHasExactlyTwoArgs() {
        let round = function(named: "ROUND")
        #expect(round.minArgs == 2)
        #expect(round.maxArgs == 2)
    }
}
