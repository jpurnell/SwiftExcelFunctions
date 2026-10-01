import Foundation
import Testing
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

    func lastPopulatedCell() -> CellRef? {
        let refs = data.keys.map { CellRef($0) }
        guard let column = refs.map(\.column).max(),
              let row = refs.map(\.row).max() else { return nil }
        return CellRef(column: column, row: row)
    }

    func lastPopulatedCell(inSheet sheet: String) -> CellRef? {
        let refs = (sheetData[sheet] ?? [:]).keys.map { CellRef($0) }
        guard let column = refs.map(\.column).max(),
              let row = refs.map(\.row).max() else { return nil }
        return CellRef(column: column, row: row)
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

@Suite struct FormulaEvaluatorTests {

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


    // MARK: - Literal Evaluation

    @Test func numberLiteral() throws {
        let result = try eval(.number(42.5))
        #expect(result == .number(42.5))
    }

    @Test func textLiteral() throws {
        let result = try eval(.text("hello"))
        #expect(result == .text("hello"))
    }

    @Test func boolTrueLiteral() throws {
        let result = try eval(.bool(true))
        #expect(result == .bool(true))
    }

    @Test func boolFalseLiteral() throws {
        let result = try eval(.bool(false))
        #expect(result == .bool(false))
    }

    @Test func errorLiteral() throws {
        let result = try eval(.error(.value))
        #expect(result == .error(.value))
    }

    @Test func errorDiv0Literal() throws {
        let result = try eval(.error(.div0))
        #expect(result == .error(.div0))
    }

    // MARK: - Cell Reference Lookup

    @Test func cellRefFound() throws {
        var cells = MockCells()
        cells.data["A1"] = .number(99)
        let result = try eval(.cellRef(CellRef("A1")), cells: cells)
        #expect(result == .number(99))
    }

    @Test func cellRefNotFoundReturnsBlank() throws {
        let result = try eval(.cellRef(CellRef("Z99")))
        #expect(result == .blank)
    }

    @Test func cellRefReturnsText() throws {
        var cells = MockCells()
        cells.data["B2"] = .text("world")
        let result = try eval(.cellRef(CellRef("B2")), cells: cells)
        #expect(result == .text("world"))
    }

    // MARK: - Cell Range

    @Test func cellRangeReturnsArray() throws {
        var cells = MockCells()
        cells.data["A1"] = .number(1)
        cells.data["A2"] = .number(2)
        cells.data["A3"] = .number(3)

        let range = CellRange(from: "A1", to: "A3")
        let result = try eval(.cellRange(range), cells: cells)

        #expect(result == .array(CellMatrix(column: [.number(1), .number(2), .number(3)])))
    }

    /// An empty cell inside a range is a blank in its own place.
    ///
    /// This test previously asserted the opposite — that the gap closed up — and
    /// that was the defect: `INDEX(A1:A3, 3)` then reached past the end of its
    /// own range and answered with whatever had shuffled into third place.
    @Test func cellRangeKeepsEmptyCellsInPlace() throws {
        var cells = MockCells()
        cells.data["A1"] = .number(1)
        // A2 is empty
        cells.data["A3"] = .number(3)

        let range = CellRange(from: "A1", to: "A3")
        let result = try eval(.cellRange(range), cells: cells)

        #expect(result == .array(CellMatrix(column: [.number(1), .blank, .number(3)])))
    }

    // MARK: - Sheet Reference Lookup

    @Test func sheetRefSingleCell() throws {
        var cells = MockCells()
        cells.sheetData["Sheet2"] = ["A1": .number(42)]

        let sheetRef = SheetReference(sheet: "Sheet2", cell: CellRef("A1"))
        let result = try eval(.sheetRef(sheetRef), cells: cells)
        #expect(result == .number(42))
    }

    @Test func sheetRefSingleCellNotFoundReturnsBlank() throws {
        var cells = MockCells()
        cells.sheetData["Sheet2"] = [:]

        let sheetRef = SheetReference(sheet: "Sheet2", cell: CellRef("A1"))
        let result = try eval(.sheetRef(sheetRef), cells: cells)
        #expect(result == .blank)
    }

    @Test func sheetRefRange() throws {
        var cells = MockCells()
        cells.sheetData["Sheet2"] = ["A1": .number(10), "A2": .number(20)]

        let range = CellRange(from: "A1", to: "A2")
        let sheetRef = SheetReference(sheet: "Sheet2", range: range)
        let result = try eval(.sheetRef(sheetRef), cells: cells)

        #expect(result == .array(CellMatrix(column: [.number(10), .number(20)])))
    }

    // MARK: - Arithmetic: Add

    @Test func addTwoNumbers() throws {
        let result = try eval(.add(.number(2), .number(3)))
        #expect(result.isNumber(5))
    }

    @Test func addNegativeNumbers() throws {
        let result = try eval(.add(.number(-1), .number(-2)))
        #expect(result.isNumber(-3))
    }

    @Test func addDecimalNumbers() throws {
        let result = try eval(.add(.number(1.5), .number(2.5)))
        #expect(result.isNumber(4.0))
    }

    // MARK: - Arithmetic: Subtract

    @Test func subtractTwoNumbers() throws {
        let result = try eval(.subtract(.number(10), .number(3)))
        #expect(result.isNumber(7))
    }

    @Test func subtractResultNegative() throws {
        let result = try eval(.subtract(.number(3), .number(10)))
        #expect(result.isNumber(-7))
    }

    // MARK: - Arithmetic: Multiply

    @Test func multiplyTwoNumbers() throws {
        let result = try eval(.multiply(.number(4), .number(5)))
        #expect(result.isNumber(20))
    }

    @Test func multiplyByZero() throws {
        let result = try eval(.multiply(.number(100), .number(0)))
        #expect(result.isNumber(0))
    }

    // MARK: - Arithmetic: Divide

    @Test func divideTwoNumbers() throws {
        let result = try eval(.divide(.number(10), .number(2)))
        #expect(result.isNumber(5))
    }

    @Test func divideByZeroReturnsDiv0Error() throws {
        let result = try eval(.divide(.number(10), .number(0)))
        #expect(result == .error(.div0))
    }

    @Test func divideDecimal() throws {
        let result = try eval(.divide(.number(7), .number(2)))
        #expect(result.isNumber(3.5))
    }

    // MARK: - Arithmetic: Power

    @Test func powerBasic() throws {
        let result = try eval(.power(.number(2), .number(3)))
        #expect(result.isNumber(8))
    }

    @Test func powerZeroExponent() throws {
        let result = try eval(.power(.number(5), .number(0)))
        #expect(result.isNumber(1))
    }

    @Test func powerFractional() throws {
        let result = try eval(.power(.number(9), .number(0.5)))
        #expect(result.isNumber(3, within: 1e-10))
    }

    // MARK: - Arithmetic: Negate

    @Test func negatePositive() throws {
        let result = try eval(.negate(.number(5)))
        #expect(result.isNumber(-5))
    }

    @Test func negateNegative() throws {
        let result = try eval(.negate(.number(-3)))
        #expect(result.isNumber(3))
    }

    @Test func negateZero() throws {
        let result = try eval(.negate(.number(0)))
        #expect(result.isNumber(0))
    }

    // MARK: - String Concatenation

    @Test func concatenateStrings() throws {
        let result = try eval(.concatenate(.text("hello"), .text(" world")))
        #expect(result == .text("hello world"))
    }

    @Test func concatenateNumberAndString() throws {
        let result = try eval(.concatenate(.number(5), .text(" items")))
        #expect(result == .text("5 items"))
    }

    @Test func concatenateStringAndBool() throws {
        let result = try eval(.concatenate(.text("is: "), .bool(true)))
        #expect(result == .text("is: TRUE"))
    }

    @Test func concatenateBlankAndText() throws {
        let result = try eval(.concatenate(.text("prefix"), .cellRef(CellRef("Z99"))))
        #expect(result == .text("prefix"))
    }

    // MARK: - Comparison Operators

    @Test func equalTrue() throws {
        let result = try eval(.equal(.number(5), .number(5)))
        #expect(result == .bool(true))
    }

    @Test func equalFalse() throws {
        let result = try eval(.equal(.number(5), .number(6)))
        #expect(result == .bool(false))
    }

    @Test func notEqualTrue() throws {
        let result = try eval(.notEqual(.number(5), .number(6)))
        #expect(result == .bool(true))
    }

    @Test func notEqualFalse() throws {
        let result = try eval(.notEqual(.number(5), .number(5)))
        #expect(result == .bool(false))
    }

    @Test func greaterThanTrue() throws {
        let result = try eval(.greaterThan(.number(10), .number(5)))
        #expect(result == .bool(true))
    }

    @Test func greaterThanFalse() throws {
        let result = try eval(.greaterThan(.number(3), .number(5)))
        #expect(result == .bool(false))
    }

    @Test func lessThanTrue() throws {
        let result = try eval(.lessThan(.number(3), .number(5)))
        #expect(result == .bool(true))
    }

    @Test func lessThanFalse() throws {
        let result = try eval(.lessThan(.number(10), .number(5)))
        #expect(result == .bool(false))
    }

    @Test func greaterOrEqualWhenGreater() throws {
        let result = try eval(.greaterOrEqual(.number(10), .number(5)))
        #expect(result == .bool(true))
    }

    @Test func greaterOrEqualWhenEqual() throws {
        let result = try eval(.greaterOrEqual(.number(5), .number(5)))
        #expect(result == .bool(true))
    }

    @Test func greaterOrEqualFalse() throws {
        let result = try eval(.greaterOrEqual(.number(3), .number(5)))
        #expect(result == .bool(false))
    }

    @Test func lessOrEqualWhenLess() throws {
        let result = try eval(.lessOrEqual(.number(3), .number(5)))
        #expect(result == .bool(true))
    }

    @Test func lessOrEqualWhenEqual() throws {
        let result = try eval(.lessOrEqual(.number(5), .number(5)))
        #expect(result == .bool(true))
    }

    @Test func lessOrEqualFalse() throws {
        let result = try eval(.lessOrEqual(.number(10), .number(5)))
        #expect(result == .bool(false))
    }

    @Test func compareStrings() throws {
        let result = try eval(.equal(.text("abc"), .text("ABC")))
        #expect(result == .bool(true)) // case-insensitive
    }

    @Test func compareStringsDifferent() throws {
        let result = try eval(.lessThan(.text("apple"), .text("banana")))
        #expect(result == .bool(true))
    }

    // MARK: - Type Coercion in Arithmetic

    @Test func textToNumberCoercion() throws {
        // "5" + 3 = 8
        let result = try eval(.add(.text("5"), .number(3)))
        #expect(result.isNumber(8))
    }

    @Test func boolTrueToNumberCoercion() throws {
        // TRUE + 1 = 2
        let result = try eval(.add(.bool(true), .number(1)))
        #expect(result.isNumber(2))
    }

    @Test func boolFalseToNumberCoercion() throws {
        // FALSE + 1 = 1
        let result = try eval(.add(.bool(false), .number(1)))
        #expect(result.isNumber(1))
    }

    @Test func blankToNumberCoercion() throws {
        // blank + 5 = 5 (blank coerces to 0)
        let cells = MockCells()
        // Z99 is empty, so cellRef returns .blank
        let result = try eval(.add(.cellRef(CellRef("Z99")), .number(5)), cells: cells)
        #expect(result.isNumber(5))
    }

    @Test func nonNumericTextReturnsValueError() throws {
        // "hello" + 1 = #VALUE!
        let result = try eval(.add(.text("hello"), .number(1)))
        #expect(result == .error(.value))
    }

    // MARK: - Error Propagation

    @Test func errorPropagationInAdd() throws {
        let result = try eval(.add(.error(.value), .number(5)))
        #expect(result == .error(.value))
    }

    @Test func errorPropagationInAddRight() throws {
        let result = try eval(.add(.number(5), .error(.ref)))
        #expect(result == .error(.ref))
    }

    @Test func errorPropagationInSubtract() throws {
        let result = try eval(.subtract(.error(.na), .number(1)))
        #expect(result == .error(.na))
    }

    @Test func errorPropagationInMultiply() throws {
        let result = try eval(.multiply(.number(2), .error(.num)))
        #expect(result == .error(.num))
    }

    @Test func errorPropagationInDivide() throws {
        let result = try eval(.divide(.error(.null), .number(1)))
        #expect(result == .error(.null))
    }

    @Test func errorPropagationInNegate() throws {
        let result = try eval(.negate(.error(.value)))
        #expect(result == .error(.value))
    }

    @Test func errorPropagationInConcatenate() throws {
        let result = try eval(.concatenate(.error(.div0), .text("x")))
        #expect(result == .error(.div0))
    }

    @Test func errorPropagationInConcatenateRight() throws {
        let result = try eval(.concatenate(.text("x"), .error(.ref)))
        #expect(result == .error(.ref))
    }

    @Test func errorPropagationInComparison() throws {
        let result = try eval(.equal(.error(.value), .number(5)))
        #expect(result == .error(.value))
    }

    @Test func errorPropagationInComparisonRight() throws {
        let result = try eval(.greaterThan(.number(5), .error(.na)))
        #expect(result == .error(.na))
    }

    // MARK: - Named Range Resolution

    @Test func namedRangeResolvesToCell() throws {
        var cells = MockCells()
        cells.data["B5"] = .number(100)

        var names = MockNames()
        names.targets["myrange"] = .cell(CellRef("B5"))

        let result = try eval(.namedRange("myrange"), cells: cells, names: names)
        #expect(result == .number(100))
    }

    @Test func namedRangeResolvesToRange() throws {
        var cells = MockCells()
        cells.data["A1"] = .number(1)
        cells.data["A2"] = .number(2)

        var names = MockNames()
        names.targets["data"] = .range(CellRange(from: "A1", to: "A2"))

        let result = try eval(.namedRange("data"), cells: cells, names: names)
        #expect(result == .array(CellMatrix(column: [.number(1), .number(2)])))
    }

    @Test func namedRangeResolvesToFormula() throws {
        var names = MockNames()
        names.targets["formula"] = .formula(.add(.number(10), .number(20)))

        let result = try eval(.namedRange("formula"), names: names)
        #expect(result.isNumber(30))
    }

    @Test func namedRangeNotFoundReturnsNameError() throws {
        let result = try eval(.namedRange("doesnotexist"))
        #expect(result == .error(.name))
    }

    @Test func namedRangeResolvesToSheetCell() throws {
        var cells = MockCells()
        cells.sheetData["Sheet2"] = ["C3": .number(77)]

        var names = MockNames()
        let sheetRef = SheetReference(sheet: "Sheet2", cell: CellRef("C3"))
        names.targets["crossref"] = .sheetCell(sheetRef)

        let result = try eval(.namedRange("crossref"), cells: cells, names: names)
        #expect(result == .number(77))
    }

    @Test func namedRangeResolvesToSheetRange() throws {
        var cells = MockCells()
        cells.sheetData["Sheet2"] = ["A1": .number(1), "A2": .number(2)]

        var names = MockNames()
        let sheetRef = SheetReference(
            sheet: "Sheet2",
            range: CellRange(from: "A1", to: "A2")
        )
        names.targets["sheetrange"] = .sheetRange(sheetRef)

        let result = try eval(.namedRange("sheetrange"), cells: cells, names: names)
        #expect(result == .array(CellMatrix(column: [.number(1), .number(2)])))
    }

    // MARK: - Function Dispatch

    @Test func functionCallWithRegisteredFunction() throws {
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
        #expect(result.isNumber(42))
    }

    @Test func functionCallEvaluatesArguments() throws {
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
        #expect(result.isNumber(3))
    }

    /// An unknown name is `#NAME?`, and `#NAME?` is a **value**.
    ///
    /// This threw, and a throw kills the enclosing formula before anything can catch it — so
    /// `IFERROR(NOSUCHFN(1), "x")` produced nothing whatever where Excel produces `"x"`.
    ///
    /// Found by the corpus oracle in **751 cells** across two workbooks exported from Google
    /// Sheets. Every one of them reads `IFERROR(__XLUDF.DUMMYFUNCTION("<the Sheets formula>"),
    /// <fallback>)` — Sheets writes that placeholder for a formula Excel cannot express, Excel
    /// answers `#NAME?`, and catching it is the entire purpose of the wrapper the exporter
    /// wrote. We threw instead, and lost the cell.
    ///
    /// The same shape is recorded in the `PSI` work: an unregistered `PsiTruncate` failed the
    /// enclosing `PsiNormal` call rather than yielding an error the caller could see. That was
    /// treated by registering the name; this is the behaviour underneath it.
    @Test func unknownFunctionIsANameErrorRatherThanAThrow() throws {
        #expect(try eval(.function("NOTAFUNCTION", [.number(1)])) == .error(.name), "Excel's answer for a name it does not know")
    }

    /// And because it is a value, the wrapper the exporter wrote does its job.
    @Test func anUnknownFunctionCanBeCaughtByIFERROR() throws {
        let formula = FormulaAST.function("IFERROR", [
            .function("__XLUDF.DUMMYFUNCTION", [.text("ARRAY_CONSTRAIN(…)")]),
            .text("the fallback the exporter recorded"),
        ])
        #expect(try eval(formula) == .text("the fallback the exporter recorded"))
    }

    @Test func functionArgumentCountMismatch() throws {
        var registry = FunctionRegistry()
        registry.register(ExcelFunction(
            name: "ONEARG",
            minArgs: 1,
            maxArgs: 1,
            evaluate: { _ in .number(0) }
        ))

        if let error = #expect(throws: (any Error).self, performing: { try eval(.function("ONEARG", [.number(1), .number(2)]), functions: registry) }) {
            guard let evalError = error as? FormulaEvaluator.EvaluationError else {
                Issue.record("Expected EvaluationError, got \(error)")
                return
            }
            if case .argumentCount(let fn, let expected, let got) = evalError {
                #expect(fn == "ONEARG")
                #expect(expected == 1...1)
                #expect(got == 2)
            } else {
                Issue.record("Expected argumentCount, got \(evalError)")
            }
        }
    }

    @Test func builtinFunctionABS() throws {
        let result = try eval(.function("ABS", [.number(-7)]))
        #expect(result.isNumber(7))
    }

    @Test func builtinFunctionPI() throws {
        let result = try eval(.function("PI", []))
        #expect(result.isNumber(Double.pi, within: 1e-14))
    }

    // MARK: - Depth Limit

    /// 257 negations are **not** too deep, and asserting that they were is what this test
    /// used to do.
    ///
    /// It was pinning `maxDepth = 256`, a single counter incremented once per AST node. The
    /// conformance rounds in `ExcelEvaluationLimits.md` established that Excel counts
    /// function calls and stops at 65, keeps a second counter for `LAMBDA` recursion at
    /// 4,096, and does not count operators at all — so this formula is one Excel computes
    /// without complaint and the old expectation was a defect written down as a test.
    ///
    /// The bounds now live in `EvaluationDepthTests`. What remains here is the reversal, kept
    /// rather than deleted so the change is visible where the old claim was made.
    @Test func aStackOfNegationsIsNotTooDeep() async throws {
        var ast: FormulaAST = .number(1)
        for _ in 0..<257 {
            ast = .negate(ast)
        }
        let stack = ast
        #expect(try await (onMeasuredStack { try eval(stack) }).isNumber(-1, within: 1e-12))
    }

    @Test func deepNestingBelowLimitSucceeds() async throws {
        // 100 levels of nesting should succeed
        var ast: FormulaAST = .number(42)
        for _ in 0..<100 {
            ast = .negate(ast)
        }

        let stack = ast
        let result = try await onMeasuredStack { try eval(stack) }
        // 100 negations (even count) = positive
        #expect(result.isNumber(42))
    }

    // MARK: - Complex Expressions

    @Test func nestedArithmetic() throws {
        // (2 + 3) * (10 - 4) = 5 * 6 = 30
        let result = try eval(
            .multiply(
                .add(.number(2), .number(3)),
                .subtract(.number(10), .number(4))
            )
        )
        #expect(result.isNumber(30))
    }

    @Test func cellRefInArithmetic() throws {
        var cells = MockCells()
        cells.data["A1"] = .number(10)
        cells.data["B1"] = .number(20)

        let result = try eval(
            .add(.cellRef(CellRef("A1")), .cellRef(CellRef("B1"))),
            cells: cells
        )
        #expect(result.isNumber(30))
    }

    @Test func divisionByZeroFromCellRef() throws {
        var cells = MockCells()
        cells.data["A1"] = .number(10)
        cells.data["B1"] = .number(0)

        let result = try eval(
            .divide(.cellRef(CellRef("A1")), .cellRef(CellRef("B1"))),
            cells: cells
        )
        #expect(result == .error(.div0))
    }

    // MARK: - Coercion in String Concatenation

    @Test func concatenateBoolFalse() throws {
        let result = try eval(.concatenate(.text("val: "), .bool(false)))
        #expect(result == .text("val: FALSE"))
    }

    @Test func concatenateDecimalNumber() throws {
        let result = try eval(.concatenate(.text("$"), .number(3.50)))
        #expect(result == .text("$3.5"))
    }

    // MARK: - Comparison with Blanks

    @Test func blankEqualsZero() throws {
        // In Excel, blank == 0 is TRUE
        let result = try eval(.equal(.cellRef(CellRef("Z99")), .number(0)))
        #expect(result == .bool(true))
    }

    // MARK: - EvaluationError Equatable

    @Test func evaluationErrorEquatable() {
        let err1 = FormulaEvaluator.EvaluationError.unknownFunction("FOO")
        let err2 = FormulaEvaluator.EvaluationError.unknownFunction("FOO")
        #expect(err1 == err2)

        let err3 = FormulaEvaluator.EvaluationError.unknownFunction("BAR")
        #expect(err1 != err3)
    }

    @Test func evaluationErrorSendable() {
        // Compile-time check: EvaluationError must be Sendable
        let error: any Sendable = FormulaEvaluator.EvaluationError.circularReference
        #expect(error is FormulaEvaluator.EvaluationError)
    }

    // MARK: - Function with Variadic Args

    @Test func variadicFunction() throws {
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
        #expect(result.isNumber(10))
    }

    // MARK: - Case-Insensitive Function Lookup

    @Test func functionLookupCaseInsensitive() throws {
        // "abs" should find "ABS"
        let result = try eval(.function("abs", [.number(-5)]))
        #expect(result.isNumber(5))
    }

    // MARK: - Named Range Case Insensitive

    @Test func namedRangeCaseInsensitive() throws {
        var names = MockNames()
        names.targets["myrange"] = .formula(.number(42))

        let result = try eval(.namedRange("MYRANGE"), names: names)
        #expect(result.isNumber(42))
    }

    // MARK: - Power edge cases

    @Test func powerNegativeBase() throws {
        // (-2)^3 = -8
        let result = try eval(.power(.number(-2), .number(3)))
        #expect(result.isNumber(-8))
    }

    // MARK: - Negate with coercion

    @Test func negateTextNumber() throws {
        // -"5" = -5 (text coerced to number)
        let result = try eval(.negate(.text("5")))
        #expect(result.isNumber(-5))
    }

    @Test func negateNonNumericTextReturnsError() throws {
        let result = try eval(.negate(.text("abc")))
        #expect(result == .error(.value))
    }

    @Test func negateBool() throws {
        // -TRUE = -1
        let result = try eval(.negate(.bool(true)))
        #expect(result.isNumber(-1))
    }

    // MARK: - Blank in comparisons

    @Test func blankLessThanPositiveNumber() throws {
        // blank (=0) < 5 -> true
        let result = try eval(.lessThan(.cellRef(CellRef("Z99")), .number(5)))
        #expect(result == .bool(true))
    }

    // MARK: - Mixed type comparison

    @Test func compareNumberAndBool() throws {
        // In Excel, numbers < booleans in type ordering
        let result = try eval(.lessThan(.number(1000), .bool(false)))
        #expect(result == .bool(true))
    }
}
