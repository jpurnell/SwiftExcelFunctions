import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

// MARK: - Mock Types

private struct MockCells: CellValueProvider {
    var data: [String: CellValue] = [:]
    var sheetData: [String: [String: CellValue]] = [:]

    func value(at ref: CellRef) -> CellValue? {
        data[ref.reference]
    }

    func value(at ref: CellRef, inSheet sheet: String) -> CellValue? {
        sheetData[sheet]?[ref.reference]
    }

    func values(in range: CellRange) -> [CellValue] {
        range.cells.compactMap { value(at: $0) }
    }

    func values(in range: CellRange, inSheet sheet: String) -> [CellValue] {
        range.cells.compactMap { value(at: $0, inSheet: sheet) }
    }
}

private struct MockNames: NameResolver {
    var targets: [String: NamedRangeTarget] = [:]

    func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? {
        targets[name.lowercased()]
    }
}

// MARK: - FormulaEvaluatorTests

final class FormulaEvaluatorTests: XCTestCase {

    // MARK: - Helpers

    private let emptyCells = MockCells()
    private let emptyNames = MockNames()

    private func eval(_ ast: FormulaAST,
                      cells: MockCells? = nil,
                      names: MockNames? = nil,
                      functions: FunctionRegistry = .builtin) throws -> CellValue {
        try FormulaEvaluator.evaluate(
            ast,
            cells: cells ?? emptyCells,
            names: names ?? emptyNames,
            functions: functions
        )
    }

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

    // MARK: - Literal Evaluation

    func testNumberLiteral() throws {
        let result = try eval(.number(42.5))
        XCTAssertEqual(result, .number(42.5))
    }

    func testTextLiteral() throws {
        let result = try eval(.text("hello"))
        XCTAssertEqual(result, .text("hello"))
    }

    func testBoolTrueLiteral() throws {
        let result = try eval(.bool(true))
        XCTAssertEqual(result, .bool(true))
    }

    func testBoolFalseLiteral() throws {
        let result = try eval(.bool(false))
        XCTAssertEqual(result, .bool(false))
    }

    func testErrorLiteral() throws {
        let result = try eval(.error(.value))
        XCTAssertEqual(result, .error(.value))
    }

    func testErrorDiv0Literal() throws {
        let result = try eval(.error(.div0))
        XCTAssertEqual(result, .error(.div0))
    }

    // MARK: - Cell Reference Lookup

    func testCellRefFound() throws {
        var cells = MockCells()
        cells.data["A1"] = .number(99)
        let result = try eval(.cellRef(CellRef("A1")), cells: cells)
        XCTAssertEqual(result, .number(99))
    }

    func testCellRefNotFoundReturnsBlank() throws {
        let result = try eval(.cellRef(CellRef("Z99")))
        XCTAssertEqual(result, .blank)
    }

    func testCellRefReturnsText() throws {
        var cells = MockCells()
        cells.data["B2"] = .text("world")
        let result = try eval(.cellRef(CellRef("B2")), cells: cells)
        XCTAssertEqual(result, .text("world"))
    }

    // MARK: - Cell Range

    func testCellRangeReturnsArray() throws {
        var cells = MockCells()
        cells.data["A1"] = .number(1)
        cells.data["A2"] = .number(2)
        cells.data["A3"] = .number(3)

        let range = CellRange(from: "A1", to: "A3")
        let result = try eval(.cellRange(range), cells: cells)

        XCTAssertEqual(result, .array([.number(1), .number(2), .number(3)]))
    }

    func testCellRangeSkipsEmpty() throws {
        var cells = MockCells()
        cells.data["A1"] = .number(1)
        // A2 is empty
        cells.data["A3"] = .number(3)

        let range = CellRange(from: "A1", to: "A3")
        let result = try eval(.cellRange(range), cells: cells)

        XCTAssertEqual(result, .array([.number(1), .number(3)]))
    }

    // MARK: - Sheet Reference Lookup

    func testSheetRefSingleCell() throws {
        var cells = MockCells()
        cells.sheetData["Sheet2"] = ["A1": .number(42)]

        let sheetRef = SheetReference(sheet: "Sheet2", cell: CellRef("A1"))
        let result = try eval(.sheetRef(sheetRef), cells: cells)
        XCTAssertEqual(result, .number(42))
    }

    func testSheetRefSingleCellNotFoundReturnsBlank() throws {
        var cells = MockCells()
        cells.sheetData["Sheet2"] = [:]

        let sheetRef = SheetReference(sheet: "Sheet2", cell: CellRef("A1"))
        let result = try eval(.sheetRef(sheetRef), cells: cells)
        XCTAssertEqual(result, .blank)
    }

    func testSheetRefRange() throws {
        var cells = MockCells()
        cells.sheetData["Sheet2"] = ["A1": .number(10), "A2": .number(20)]

        let range = CellRange(from: "A1", to: "A2")
        let sheetRef = SheetReference(sheet: "Sheet2", range: range)
        let result = try eval(.sheetRef(sheetRef), cells: cells)

        XCTAssertEqual(result, .array([.number(10), .number(20)]))
    }

    // MARK: - Arithmetic: Add

    func testAddTwoNumbers() throws {
        let result = try eval(.add(.number(2), .number(3)))
        assertNumber(result, 5)
    }

    func testAddNegativeNumbers() throws {
        let result = try eval(.add(.number(-1), .number(-2)))
        assertNumber(result, -3)
    }

    func testAddDecimalNumbers() throws {
        let result = try eval(.add(.number(1.5), .number(2.5)))
        assertNumber(result, 4.0)
    }

    // MARK: - Arithmetic: Subtract

    func testSubtractTwoNumbers() throws {
        let result = try eval(.subtract(.number(10), .number(3)))
        assertNumber(result, 7)
    }

    func testSubtractResultNegative() throws {
        let result = try eval(.subtract(.number(3), .number(10)))
        assertNumber(result, -7)
    }

    // MARK: - Arithmetic: Multiply

    func testMultiplyTwoNumbers() throws {
        let result = try eval(.multiply(.number(4), .number(5)))
        assertNumber(result, 20)
    }

    func testMultiplyByZero() throws {
        let result = try eval(.multiply(.number(100), .number(0)))
        assertNumber(result, 0)
    }

    // MARK: - Arithmetic: Divide

    func testDivideTwoNumbers() throws {
        let result = try eval(.divide(.number(10), .number(2)))
        assertNumber(result, 5)
    }

    func testDivideByZeroReturnsDiv0Error() throws {
        let result = try eval(.divide(.number(10), .number(0)))
        XCTAssertEqual(result, .error(.div0))
    }

    func testDivideDecimal() throws {
        let result = try eval(.divide(.number(7), .number(2)))
        assertNumber(result, 3.5)
    }

    // MARK: - Arithmetic: Power

    func testPowerBasic() throws {
        let result = try eval(.power(.number(2), .number(3)))
        assertNumber(result, 8)
    }

    func testPowerZeroExponent() throws {
        let result = try eval(.power(.number(5), .number(0)))
        assertNumber(result, 1)
    }

    func testPowerFractional() throws {
        let result = try eval(.power(.number(9), .number(0.5)))
        assertNumber(result, 3, accuracy: 1e-10)
    }

    // MARK: - Arithmetic: Negate

    func testNegatePositive() throws {
        let result = try eval(.negate(.number(5)))
        assertNumber(result, -5)
    }

    func testNegateNegative() throws {
        let result = try eval(.negate(.number(-3)))
        assertNumber(result, 3)
    }

    func testNegateZero() throws {
        let result = try eval(.negate(.number(0)))
        assertNumber(result, 0)
    }

    // MARK: - String Concatenation

    func testConcatenateStrings() throws {
        let result = try eval(.concatenate(.text("hello"), .text(" world")))
        XCTAssertEqual(result, .text("hello world"))
    }

    func testConcatenateNumberAndString() throws {
        let result = try eval(.concatenate(.number(5), .text(" items")))
        XCTAssertEqual(result, .text("5 items"))
    }

    func testConcatenateStringAndBool() throws {
        let result = try eval(.concatenate(.text("is: "), .bool(true)))
        XCTAssertEqual(result, .text("is: TRUE"))
    }

    func testConcatenateBlankAndText() throws {
        let result = try eval(.concatenate(.text("prefix"), .cellRef(CellRef("Z99"))))
        XCTAssertEqual(result, .text("prefix"))
    }

    // MARK: - Comparison Operators

    func testEqualTrue() throws {
        let result = try eval(.equal(.number(5), .number(5)))
        XCTAssertEqual(result, .bool(true))
    }

    func testEqualFalse() throws {
        let result = try eval(.equal(.number(5), .number(6)))
        XCTAssertEqual(result, .bool(false))
    }

    func testNotEqualTrue() throws {
        let result = try eval(.notEqual(.number(5), .number(6)))
        XCTAssertEqual(result, .bool(true))
    }

    func testNotEqualFalse() throws {
        let result = try eval(.notEqual(.number(5), .number(5)))
        XCTAssertEqual(result, .bool(false))
    }

    func testGreaterThanTrue() throws {
        let result = try eval(.greaterThan(.number(10), .number(5)))
        XCTAssertEqual(result, .bool(true))
    }

    func testGreaterThanFalse() throws {
        let result = try eval(.greaterThan(.number(3), .number(5)))
        XCTAssertEqual(result, .bool(false))
    }

    func testLessThanTrue() throws {
        let result = try eval(.lessThan(.number(3), .number(5)))
        XCTAssertEqual(result, .bool(true))
    }

    func testLessThanFalse() throws {
        let result = try eval(.lessThan(.number(10), .number(5)))
        XCTAssertEqual(result, .bool(false))
    }

    func testGreaterOrEqualWhenGreater() throws {
        let result = try eval(.greaterOrEqual(.number(10), .number(5)))
        XCTAssertEqual(result, .bool(true))
    }

    func testGreaterOrEqualWhenEqual() throws {
        let result = try eval(.greaterOrEqual(.number(5), .number(5)))
        XCTAssertEqual(result, .bool(true))
    }

    func testGreaterOrEqualFalse() throws {
        let result = try eval(.greaterOrEqual(.number(3), .number(5)))
        XCTAssertEqual(result, .bool(false))
    }

    func testLessOrEqualWhenLess() throws {
        let result = try eval(.lessOrEqual(.number(3), .number(5)))
        XCTAssertEqual(result, .bool(true))
    }

    func testLessOrEqualWhenEqual() throws {
        let result = try eval(.lessOrEqual(.number(5), .number(5)))
        XCTAssertEqual(result, .bool(true))
    }

    func testLessOrEqualFalse() throws {
        let result = try eval(.lessOrEqual(.number(10), .number(5)))
        XCTAssertEqual(result, .bool(false))
    }

    func testCompareStrings() throws {
        let result = try eval(.equal(.text("abc"), .text("ABC")))
        XCTAssertEqual(result, .bool(true)) // case-insensitive
    }

    func testCompareStringsDifferent() throws {
        let result = try eval(.lessThan(.text("apple"), .text("banana")))
        XCTAssertEqual(result, .bool(true))
    }

    // MARK: - Type Coercion in Arithmetic

    func testTextToNumberCoercion() throws {
        // "5" + 3 = 8
        let result = try eval(.add(.text("5"), .number(3)))
        assertNumber(result, 8)
    }

    func testBoolTrueToNumberCoercion() throws {
        // TRUE + 1 = 2
        let result = try eval(.add(.bool(true), .number(1)))
        assertNumber(result, 2)
    }

    func testBoolFalseToNumberCoercion() throws {
        // FALSE + 1 = 1
        let result = try eval(.add(.bool(false), .number(1)))
        assertNumber(result, 1)
    }

    func testBlankToNumberCoercion() throws {
        // blank + 5 = 5 (blank coerces to 0)
        let cells = MockCells()
        // Z99 is empty, so cellRef returns .blank
        let result = try eval(.add(.cellRef(CellRef("Z99")), .number(5)), cells: cells)
        assertNumber(result, 5)
    }

    func testNonNumericTextReturnsValueError() throws {
        // "hello" + 1 = #VALUE!
        let result = try eval(.add(.text("hello"), .number(1)))
        XCTAssertEqual(result, .error(.value))
    }

    // MARK: - Error Propagation

    func testErrorPropagationInAdd() throws {
        let result = try eval(.add(.error(.value), .number(5)))
        XCTAssertEqual(result, .error(.value))
    }

    func testErrorPropagationInAddRight() throws {
        let result = try eval(.add(.number(5), .error(.ref)))
        XCTAssertEqual(result, .error(.ref))
    }

    func testErrorPropagationInSubtract() throws {
        let result = try eval(.subtract(.error(.na), .number(1)))
        XCTAssertEqual(result, .error(.na))
    }

    func testErrorPropagationInMultiply() throws {
        let result = try eval(.multiply(.number(2), .error(.num)))
        XCTAssertEqual(result, .error(.num))
    }

    func testErrorPropagationInDivide() throws {
        let result = try eval(.divide(.error(.null), .number(1)))
        XCTAssertEqual(result, .error(.null))
    }

    func testErrorPropagationInNegate() throws {
        let result = try eval(.negate(.error(.value)))
        XCTAssertEqual(result, .error(.value))
    }

    func testErrorPropagationInConcatenate() throws {
        let result = try eval(.concatenate(.error(.div0), .text("x")))
        XCTAssertEqual(result, .error(.div0))
    }

    func testErrorPropagationInConcatenateRight() throws {
        let result = try eval(.concatenate(.text("x"), .error(.ref)))
        XCTAssertEqual(result, .error(.ref))
    }

    func testErrorPropagationInComparison() throws {
        let result = try eval(.equal(.error(.value), .number(5)))
        XCTAssertEqual(result, .error(.value))
    }

    func testErrorPropagationInComparisonRight() throws {
        let result = try eval(.greaterThan(.number(5), .error(.na)))
        XCTAssertEqual(result, .error(.na))
    }

    // MARK: - Named Range Resolution

    func testNamedRangeResolvesToCell() throws {
        var cells = MockCells()
        cells.data["B5"] = .number(100)

        var names = MockNames()
        names.targets["myrange"] = .cell(CellRef("B5"))

        let result = try eval(.namedRange("myrange"), cells: cells, names: names)
        XCTAssertEqual(result, .number(100))
    }

    func testNamedRangeResolvesToRange() throws {
        var cells = MockCells()
        cells.data["A1"] = .number(1)
        cells.data["A2"] = .number(2)

        var names = MockNames()
        names.targets["data"] = .range(CellRange(from: "A1", to: "A2"))

        let result = try eval(.namedRange("data"), cells: cells, names: names)
        XCTAssertEqual(result, .array([.number(1), .number(2)]))
    }

    func testNamedRangeResolvesToFormula() throws {
        var names = MockNames()
        names.targets["formula"] = .formula(.add(.number(10), .number(20)))

        let result = try eval(.namedRange("formula"), names: names)
        assertNumber(result, 30)
    }

    func testNamedRangeNotFoundReturnsNameError() throws {
        let result = try eval(.namedRange("doesnotexist"))
        XCTAssertEqual(result, .error(.name))
    }

    func testNamedRangeResolvesToSheetCell() throws {
        var cells = MockCells()
        cells.sheetData["Sheet2"] = ["C3": .number(77)]

        var names = MockNames()
        let sheetRef = SheetReference(sheet: "Sheet2", cell: CellRef("C3"))
        names.targets["crossref"] = .sheetCell(sheetRef)

        let result = try eval(.namedRange("crossref"), cells: cells, names: names)
        XCTAssertEqual(result, .number(77))
    }

    func testNamedRangeResolvesToSheetRange() throws {
        var cells = MockCells()
        cells.sheetData["Sheet2"] = ["A1": .number(1), "A2": .number(2)]

        var names = MockNames()
        let sheetRef = SheetReference(
            sheet: "Sheet2",
            range: CellRange(from: "A1", to: "A2")
        )
        names.targets["sheetrange"] = .sheetRange(sheetRef)

        let result = try eval(.namedRange("sheetrange"), cells: cells, names: names)
        XCTAssertEqual(result, .array([.number(1), .number(2)]))
    }

    // MARK: - Function Dispatch

    func testFunctionCallWithRegisteredFunction() throws {
        var registry = FunctionRegistry()
        registry.register(ExcelFunction(
            name: "DOUBLE",
            minArgs: 1,
            maxArgs: 1,
            evaluate: { args in
                guard case .number(let n) = args[0] else { return .error(.value) }
                return .number(n * 2)
            }
        ))

        let result = try eval(.function("DOUBLE", [.number(21)]), functions: registry)
        assertNumber(result, 42)
    }

    func testFunctionCallEvaluatesArguments() throws {
        var registry = FunctionRegistry()
        registry.register(ExcelFunction(
            name: "IDENTITY",
            minArgs: 1,
            maxArgs: 1,
            evaluate: { args in args[0] }
        ))

        // The argument is an expression that should be evaluated first
        let result = try eval(
            .function("IDENTITY", [.add(.number(1), .number(2))]),
            functions: registry
        )
        assertNumber(result, 3)
    }

    func testUnknownFunctionThrowsError() throws {
        XCTAssertThrowsError(try eval(.function("NOTAFUNCTION", [.number(1)]))) { error in
            guard let evalError = error as? FormulaEvaluator.EvaluationError else {
                XCTFail("Expected EvaluationError, got \(error)")
                return
            }
            if case .unknownFunction(let name) = evalError {
                XCTAssertEqual(name, "NOTAFUNCTION")
            } else {
                XCTFail("Expected unknownFunction, got \(evalError)")
            }
        }
    }

    func testFunctionArgumentCountMismatch() throws {
        var registry = FunctionRegistry()
        registry.register(ExcelFunction(
            name: "ONEARG",
            minArgs: 1,
            maxArgs: 1,
            evaluate: { _ in .number(0) }
        ))

        XCTAssertThrowsError(
            try eval(.function("ONEARG", [.number(1), .number(2)]), functions: registry)
        ) { error in
            guard let evalError = error as? FormulaEvaluator.EvaluationError else {
                XCTFail("Expected EvaluationError, got \(error)")
                return
            }
            if case .argumentCount(let fn, let expected, let got) = evalError {
                XCTAssertEqual(fn, "ONEARG")
                XCTAssertEqual(expected, 1...1)
                XCTAssertEqual(got, 2)
            } else {
                XCTFail("Expected argumentCount, got \(evalError)")
            }
        }
    }

    func testBuiltinFunctionABS() throws {
        let result = try eval(.function("ABS", [.number(-7)]))
        assertNumber(result, 7)
    }

    func testBuiltinFunctionPI() throws {
        let result = try eval(.function("PI", []))
        assertNumber(result, Double.pi, accuracy: 1e-14)
    }

    // MARK: - Depth Limit

    func testDepthLimitExceeded() throws {
        // Build a deeply nested AST exceeding 256 levels
        var ast: FormulaAST = .number(1)
        for _ in 0..<257 {
            ast = .negate(ast)
        }

        XCTAssertThrowsError(try eval(ast)) { error in
            guard let evalError = error as? FormulaEvaluator.EvaluationError else {
                XCTFail("Expected EvaluationError, got \(error)")
                return
            }
            XCTAssertEqual(evalError, .evaluationDepthExceeded)
        }
    }

    func testDeepNestingBelowLimitSucceeds() throws {
        // 100 levels of nesting should succeed
        var ast: FormulaAST = .number(42)
        for _ in 0..<100 {
            ast = .negate(ast)
        }

        let result = try eval(ast)
        // 100 negations (even count) = positive
        assertNumber(result, 42)
    }

    // MARK: - Complex Expressions

    func testNestedArithmetic() throws {
        // (2 + 3) * (10 - 4) = 5 * 6 = 30
        let result = try eval(
            .multiply(
                .add(.number(2), .number(3)),
                .subtract(.number(10), .number(4))
            )
        )
        assertNumber(result, 30)
    }

    func testCellRefInArithmetic() throws {
        var cells = MockCells()
        cells.data["A1"] = .number(10)
        cells.data["B1"] = .number(20)

        let result = try eval(
            .add(.cellRef(CellRef("A1")), .cellRef(CellRef("B1"))),
            cells: cells
        )
        assertNumber(result, 30)
    }

    func testDivisionByZeroFromCellRef() throws {
        var cells = MockCells()
        cells.data["A1"] = .number(10)
        cells.data["B1"] = .number(0)

        let result = try eval(
            .divide(.cellRef(CellRef("A1")), .cellRef(CellRef("B1"))),
            cells: cells
        )
        XCTAssertEqual(result, .error(.div0))
    }

    // MARK: - Coercion in String Concatenation

    func testConcatenateBoolFalse() throws {
        let result = try eval(.concatenate(.text("val: "), .bool(false)))
        XCTAssertEqual(result, .text("val: FALSE"))
    }

    func testConcatenateDecimalNumber() throws {
        let result = try eval(.concatenate(.text("$"), .number(3.50)))
        XCTAssertEqual(result, .text("$3.5"))
    }

    // MARK: - Comparison with Blanks

    func testBlankEqualsZero() throws {
        // In Excel, blank == 0 is TRUE
        let result = try eval(.equal(.cellRef(CellRef("Z99")), .number(0)))
        XCTAssertEqual(result, .bool(true))
    }

    // MARK: - EvaluationError Equatable

    func testEvaluationErrorEquatable() {
        let err1 = FormulaEvaluator.EvaluationError.unknownFunction("FOO")
        let err2 = FormulaEvaluator.EvaluationError.unknownFunction("FOO")
        XCTAssertEqual(err1, err2)

        let err3 = FormulaEvaluator.EvaluationError.unknownFunction("BAR")
        XCTAssertNotEqual(err1, err3)
    }

    func testEvaluationErrorSendable() {
        // Compile-time check: EvaluationError must be Sendable
        let error: any Sendable = FormulaEvaluator.EvaluationError.circularReference
        XCTAssertNotNil(error)
    }

    // MARK: - Function with Variadic Args

    func testVariadicFunction() throws {
        var registry = FunctionRegistry()
        registry.register(ExcelFunction(
            name: "SUM_TEST",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { args in
                var total = 0.0
                for arg in args {
                    if case .number(let n) = arg {
                        total += n
                    }
                }
                return .number(total)
            }
        ))

        let result = try eval(
            .function("SUM_TEST", [.number(1), .number(2), .number(3), .number(4)]),
            functions: registry
        )
        assertNumber(result, 10)
    }

    // MARK: - Case-Insensitive Function Lookup

    func testFunctionLookupCaseInsensitive() throws {
        // "abs" should find "ABS"
        let result = try eval(.function("abs", [.number(-5)]))
        assertNumber(result, 5)
    }

    // MARK: - Named Range Case Insensitive

    func testNamedRangeCaseInsensitive() throws {
        var names = MockNames()
        names.targets["myrange"] = .formula(.number(42))

        let result = try eval(.namedRange("MYRANGE"), names: names)
        assertNumber(result, 42)
    }

    // MARK: - Power edge cases

    func testPowerNegativeBase() throws {
        // (-2)^3 = -8
        let result = try eval(.power(.number(-2), .number(3)))
        assertNumber(result, -8)
    }

    // MARK: - Negate with coercion

    func testNegateTextNumber() throws {
        // -"5" = -5 (text coerced to number)
        let result = try eval(.negate(.text("5")))
        assertNumber(result, -5)
    }

    func testNegateNonNumericTextReturnsError() throws {
        let result = try eval(.negate(.text("abc")))
        XCTAssertEqual(result, .error(.value))
    }

    func testNegateBool() throws {
        // -TRUE = -1
        let result = try eval(.negate(.bool(true)))
        assertNumber(result, -1)
    }

    // MARK: - Blank in comparisons

    func testBlankLessThanPositiveNumber() throws {
        // blank (=0) < 5 -> true
        let result = try eval(.lessThan(.cellRef(CellRef("Z99")), .number(5)))
        XCTAssertEqual(result, .bool(true))
    }

    // MARK: - Mixed type comparison

    func testCompareNumberAndBool() throws {
        // In Excel, numbers < booleans in type ordering
        let result = try eval(.lessThan(.number(1000), .bool(false)))
        XCTAssertEqual(result, .bool(true))
    }
}
