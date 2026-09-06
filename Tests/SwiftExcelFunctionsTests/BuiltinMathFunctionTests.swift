import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

final class BuiltinMathFunctionTests: XCTestCase {

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

    /// Assert a CellValue equals a number within accuracy.
    private func assertNumber(
        _ result: CellValue,
        _ expected: Double,
        accuracy: Double = 1e-10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .number(let value) = result else {
            XCTFail("Expected .number(\(expected)), got \(result)", file: file, line: line)
            return
        }
        XCTAssertEqual(value, expected, accuracy: accuracy, file: file, line: line)
    }

    /// Assert a CellValue is a specific Excel error.
    private func assertError(
        _ result: CellValue,
        _ expectedError: ExcelError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .error(let err) = result else {
            XCTFail("Expected .error(\(expectedError)), got \(result)", file: file, line: line)
            return
        }
        XCTAssertEqual(err, expectedError, file: file, line: line)
    }

    // MARK: - Registration count

    /// By name rather than by count: a count says something changed without
    /// saying what, and fails identically whether a function arrived or went.
    func testAllContainsEveryFunctionInTheGroup() {
        XCTAssertEqual(
            Set(BuiltinMathFunctions.all.map(\.name)),
            ["ABS", "ROUND", "ROUNDUP", "ROUNDDOWN", "SQRT", "LN", "LOG", "EXP",
             "POWER", "MOD", "INT", "CEILING", "FLOOR", "SIGN", "PI",
             "RAND", "RANDBETWEEN",
             "SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "ATAN2",
             "LOG10", "TRUNC", "PRODUCT", "GCD", "LCM",
             "DEC2HEX", "DEC2BIN", "DEC2OCT", "HEX2DEC", "BIN2DEC", "OCT2DEC",
             "BASE", "DECIMAL"])
    }

    // MARK: - ABS

    func testABSPositive() throws {
        let result = try eval("ABS", .number(5))
        assertNumber(result, 5)
    }

    func testABSNegative() throws {
        let result = try eval("ABS", .number(-3.7))
        assertNumber(result, 3.7)
    }

    func testABSZero() throws {
        let result = try eval("ABS", .number(0))
        assertNumber(result, 0)
    }

    // MARK: - ROUND

    func testROUNDPositiveDigits() throws {
        let result = try eval("ROUND", .number(1234.567), .number(2))
        assertNumber(result, 1234.57)
    }

    func testROUNDNegativeDigits() throws {
        let result = try eval("ROUND", .number(1234), .number(-2))
        assertNumber(result, 1200)
    }

    func testROUNDZeroDigits() throws {
        let result = try eval("ROUND", .number(3.5), .number(0))
        assertNumber(result, 4)
    }

    // MARK: - ROUNDUP

    func testROUNDUPPositive() throws {
        let result = try eval("ROUNDUP", .number(3.2), .number(0))
        assertNumber(result, 4)
    }

    func testROUNDUPNegative() throws {
        let result = try eval("ROUNDUP", .number(-3.2), .number(0))
        assertNumber(result, -4)
    }

    func testROUNDUPWithDigits() throws {
        let result = try eval("ROUNDUP", .number(3.14159), .number(2))
        assertNumber(result, 3.15)
    }

    // MARK: - ROUNDDOWN

    func testROUNDDOWNPositive() throws {
        let result = try eval("ROUNDDOWN", .number(3.9), .number(0))
        assertNumber(result, 3)
    }

    func testROUNDDOWNNegative() throws {
        let result = try eval("ROUNDDOWN", .number(-3.9), .number(0))
        assertNumber(result, -3)
    }

    func testROUNDDOWNWithDigits() throws {
        let result = try eval("ROUNDDOWN", .number(3.149), .number(1))
        assertNumber(result, 3.1)
    }

    // MARK: - SQRT

    func testSQRTPositive() throws {
        let result = try eval("SQRT", .number(25))
        assertNumber(result, 5)
    }

    func testSQRTZero() throws {
        let result = try eval("SQRT", .number(0))
        assertNumber(result, 0)
    }

    func testSQRTNegativeReturnsNumError() throws {
        let result = try eval("SQRT", .number(-4))
        assertError(result, .num)
    }

    // MARK: - LN

    func testLNPositive() throws {
        let result = try eval("LN", .number(1))
        assertNumber(result, 0)
    }

    func testLNEuler() throws {
        let result = try eval("LN", .number(Darwin.M_E))
        assertNumber(result, 1, accuracy: 1e-10)
    }

    func testLNZeroReturnsNumError() throws {
        let result = try eval("LN", .number(0))
        assertError(result, .num)
    }

    func testLNNegativeReturnsNumError() throws {
        let result = try eval("LN", .number(-5))
        assertError(result, .num)
    }

    // MARK: - LOG

    func testLOGOneArgBase10() throws {
        let result = try eval("LOG", .number(100))
        assertNumber(result, 2)
    }

    func testLOGTwoArgsCustomBase() throws {
        let result = try eval("LOG", .number(8), .number(2))
        assertNumber(result, 3, accuracy: 1e-10)
    }

    func testLOGBase10Explicit() throws {
        let result = try eval("LOG", .number(1000), .number(10))
        assertNumber(result, 3, accuracy: 1e-10)
    }

    // MARK: - EXP

    func testEXPBasic() throws {
        let result = try eval("EXP", .number(1))
        assertNumber(result, Darwin.M_E, accuracy: 1e-10)
    }

    func testEXPZero() throws {
        let result = try eval("EXP", .number(0))
        assertNumber(result, 1)
    }

    func testEXPNegative() throws {
        let result = try eval("EXP", .number(-1))
        assertNumber(result, 1.0 / Darwin.M_E, accuracy: 1e-10)
    }

    // MARK: - POWER

    func testPOWERBasic() throws {
        let result = try eval("POWER", .number(2), .number(10))
        assertNumber(result, 1024)
    }

    func testPOWERFractionalExponent() throws {
        let result = try eval("POWER", .number(9), .number(0.5))
        assertNumber(result, 3, accuracy: 1e-10)
    }

    func testPOWERZeroExponent() throws {
        let result = try eval("POWER", .number(5), .number(0))
        assertNumber(result, 1)
    }

    // MARK: - MOD

    func testMODPositivePositive() throws {
        let result = try eval("MOD", .number(7), .number(3))
        assertNumber(result, 1)
    }

    func testMODNegativePositive() throws {
        // Excel: MOD(-7, 3) = 2 (not -1 like Swift %)
        let result = try eval("MOD", .number(-7), .number(3))
        assertNumber(result, 2)
    }

    func testMODPositiveNegative() throws {
        // Excel: MOD(7, -3) = -2
        let result = try eval("MOD", .number(7), .number(-3))
        assertNumber(result, -2)
    }

    func testMODDivideByZero() throws {
        let result = try eval("MOD", .number(7), .number(0))
        assertError(result, .div0)
    }

    // MARK: - INT

    func testINTPositive() throws {
        // INT(3.7) = 3
        let result = try eval("INT", .number(3.7))
        assertNumber(result, 3)
    }

    func testINTNegative() throws {
        // INT(-3.7) = -4 (floor toward negative infinity)
        let result = try eval("INT", .number(-3.7))
        assertNumber(result, -4)
    }

    func testINTWholeNumber() throws {
        let result = try eval("INT", .number(5))
        assertNumber(result, 5)
    }

    // MARK: - CEILING

    func testCEILINGPositive() throws {
        // CEILING(2.1, 1) = 3
        let result = try eval("CEILING", .number(2.1), .number(1))
        assertNumber(result, 3)
    }

    func testCEILINGNegative() throws {
        // CEILING(-2.1, -1) = -3
        let result = try eval("CEILING", .number(-2.1), .number(-1))
        assertNumber(result, -3)
    }

    func testCEILINGMultiple() throws {
        // CEILING(4.42, 0.05) = 4.45
        let result = try eval("CEILING", .number(4.42), .number(0.05))
        assertNumber(result, 4.45, accuracy: 1e-10)
    }

    func testCEILINGZeroSignificance() throws {
        let result = try eval("CEILING", .number(2.5), .number(0))
        assertNumber(result, 0)
    }

    // MARK: - FLOOR

    func testFLOORPositive() throws {
        // FLOOR(2.7, 1) = 2
        let result = try eval("FLOOR", .number(2.7), .number(1))
        assertNumber(result, 2)
    }

    func testFLOORNegative() throws {
        // FLOOR(-2.7, -1) = -3 (note: Excel FLOOR requires same sign for number and significance)
        let result = try eval("FLOOR", .number(-2.7), .number(-1))
        assertNumber(result, -3, accuracy: 1e-10)
    }

    func testFLOORMultiple() throws {
        // FLOOR(4.48, 0.05) = 4.45
        let result = try eval("FLOOR", .number(4.48), .number(0.05))
        assertNumber(result, 4.45, accuracy: 1e-10)
    }

    // MARK: - SIGN

    func testSIGNPositive() throws {
        let result = try eval("SIGN", .number(42))
        assertNumber(result, 1)
    }

    func testSIGNNegative() throws {
        let result = try eval("SIGN", .number(-3.5))
        assertNumber(result, -1)
    }

    func testSIGNZero() throws {
        let result = try eval("SIGN", .number(0))
        assertNumber(result, 0)
    }

    // MARK: - PI

    func testPI() throws {
        let result = try eval("PI")
        assertNumber(result, Double.pi, accuracy: 1e-14)
    }

    // MARK: - Error propagation

    func testErrorPropagation() throws {
        // Passing an error into any function should propagate the error.
        let functions = ["ABS", "SQRT", "LN", "EXP", "SIGN", "INT"]
        for name in functions {
            let result = try eval(name, .error(.value))
            assertError(result, .value)
        }
    }

    func testErrorPropagationTwoArgs() throws {
        let functions = ["ROUND", "ROUNDUP", "ROUNDDOWN", "POWER", "MOD", "CEILING", "FLOOR"]
        for name in functions {
            let result = try eval(name, .error(.ref), .number(1))
            assertError(result, .ref)
        }
    }

    func testErrorPropagationSecondArg() throws {
        let functions = ["ROUND", "ROUNDUP", "ROUNDDOWN", "POWER", "MOD", "CEILING", "FLOOR"]
        for name in functions {
            let result = try eval(name, .number(1), .error(.na))
            assertError(result, .na)
        }
    }

    // MARK: - Type coercion

    func testTypeCoercionTextToNumber() throws {
        let result = try eval("ABS", .text("5"))
        assertNumber(result, 5)
    }

    func testTypeCoercionTextNonNumericReturnsError() throws {
        let result = try eval("ABS", .text("abc"))
        assertError(result, .value)
    }

    func testTypeCoercionBoolTrue() throws {
        let result = try eval("ABS", .bool(true))
        assertNumber(result, 1)
    }

    func testTypeCoercionBoolFalse() throws {
        let result = try eval("ABS", .bool(false))
        assertNumber(result, 0)
    }

    func testTypeCoercionBlank() throws {
        let result = try eval("ABS", .blank)
        assertNumber(result, 0)
    }

    // MARK: - ExcelFunction metadata

    func testPIHasZeroArgs() {
        let pi = function(named: "PI")
        XCTAssertEqual(pi.minArgs, 0)
        XCTAssertEqual(pi.maxArgs, 0)
    }

    func testLOGHasOptionalSecondArg() {
        let log = function(named: "LOG")
        XCTAssertEqual(log.minArgs, 1)
        XCTAssertEqual(log.maxArgs, 2)
    }

    func testABSHasExactlyOneArg() {
        let abs = function(named: "ABS")
        XCTAssertEqual(abs.minArgs, 1)
        XCTAssertEqual(abs.maxArgs, 1)
    }

    func testROUNDHasExactlyTwoArgs() {
        let round = function(named: "ROUND")
        XCTAssertEqual(round.minArgs, 2)
        XCTAssertEqual(round.maxArgs, 2)
    }
}
