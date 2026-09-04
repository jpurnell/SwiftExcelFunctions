import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
// The parser lives in SwiftXLSX; the evaluator lives here. This suite is the
// seam between them, so it is the one place that needs both — and only in
// tests. The library target does not depend on SwiftXLSX and must not.
import SwiftXLSX

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

final class FormulaParserIntegrationTests: XCTestCase {

    // MARK: - Helpers

    private let emptyNames = MockNames()

    private func parseAndEval(
        _ formula: String,
        cells: MockCells = MockCells(),
        names: MockNames? = nil
    ) throws -> CellValue {
        let ast = try FormulaParser.parse(formula)
        return try FormulaEvaluator.evaluate(
            ast,
            cells: cells,
            names: names ?? emptyNames
        )
    }

    private func assertNumericResult(
        _ formula: String,
        cells: MockCells = MockCells(),
        expected: Double,
        accuracy: Double = 1e-10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let result = try parseAndEval(formula, cells: cells)
        guard case .number(let actual) = result else {
            XCTFail("Expected number(\(expected)), got \(result)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, accuracy: accuracy, file: file, line: line)
    }

    // MARK: - Arithmetic Literals

    func testAddLiterals() throws {
        try assertNumericResult("1+2", expected: 3)
    }

    func testSubtractLiterals() throws {
        try assertNumericResult("10-3", expected: 7)
    }

    func testMultiplyLiterals() throws {
        try assertNumericResult("4*5", expected: 20)
    }

    func testDivideLiterals() throws {
        try assertNumericResult("15/3", expected: 5)
    }

    func testPowerLiterals() throws {
        try assertNumericResult("2^10", expected: 1024)
    }

    func testNegation() throws {
        try assertNumericResult("-5+8", expected: 3)
    }

    func testPrecedenceAddMul() throws {
        try assertNumericResult("2+3*4", expected: 14)
    }

    func testParensOverride() throws {
        try assertNumericResult("(2+3)*4", expected: 20)
    }

    func testLeftAssocSubtract() throws {
        try assertNumericResult("10-3-2", expected: 5)
    }

    func testLeftAssocDivide() throws {
        try assertNumericResult("100/5/4", expected: 5)
    }

    func testComplexPrecedence() throws {
        try assertNumericResult("1+2*3^2", expected: 19)
    }

    // MARK: - Cell References

    func testCellRefAdd() throws {
        let cells = MockCells(data: ["A1": .number(10), "B1": .number(20)])
        try assertNumericResult("A1+B1", cells: cells, expected: 30)
    }

    func testCellRefMultiply() throws {
        let cells = MockCells(data: ["A1": .number(5), "B1": .number(3)])
        try assertNumericResult("A1*B1+1", cells: cells, expected: 16)
    }

    func testAbsoluteCellRef() throws {
        let cells = MockCells(data: ["$A$1": .number(42)])
        try assertNumericResult("$A$1*2", cells: cells, expected: 84)
    }

    func testBlankCellDefaultsToZero() throws {
        try assertNumericResult("A1+5", expected: 5)
    }

    // MARK: - String Operations

    func testConcatenateStrings() throws {
        let result = try parseAndEval("\"hello\"&\" \"&\"world\"")
        XCTAssertEqual(result, .text("hello world"))
    }

    func testConcatenateWithNumber() throws {
        let cells = MockCells(data: ["A1": .number(42)])
        let result = try parseAndEval("\"Value: \"&A1", cells: cells)
        XCTAssertEqual(result, .text("Value: 42"))
    }

    // MARK: - Comparisons

    func testEqualTrue() throws {
        let result = try parseAndEval("1+1=2")
        XCTAssertEqual(result, .bool(true))
    }

    func testEqualFalse() throws {
        let result = try parseAndEval("1+1=3")
        XCTAssertEqual(result, .bool(false))
    }

    func testGreaterThan() throws {
        let result = try parseAndEval("5>3")
        XCTAssertEqual(result, .bool(true))
    }

    func testLessThan() throws {
        let result = try parseAndEval("3<5")
        XCTAssertEqual(result, .bool(true))
    }

    func testNotEqual() throws {
        let result = try parseAndEval("1<>2")
        XCTAssertEqual(result, .bool(true))
    }

    func testGreaterOrEqual() throws {
        let result = try parseAndEval("5>=5")
        XCTAssertEqual(result, .bool(true))
    }

    func testLessOrEqual() throws {
        let result = try parseAndEval("3<=5")
        XCTAssertEqual(result, .bool(true))
    }

    // MARK: - Boolean Literals

    func testBoolLiteralTrue() throws {
        let result = try parseAndEval("TRUE")
        XCTAssertEqual(result, .bool(true))
    }

    func testBoolLiteralFalse() throws {
        let result = try parseAndEval("FALSE")
        XCTAssertEqual(result, .bool(false))
    }

    func testBoolInArithmetic() throws {
        try assertNumericResult("TRUE+1", expected: 2)
    }

    // MARK: - Error Literals

    func testErrorLiteral() throws {
        let result = try parseAndEval("#VALUE!")
        XCTAssertEqual(result, .error(.value))
    }

    func testErrorPropagation() throws {
        let result = try parseAndEval("#VALUE!+1")
        XCTAssertEqual(result, .error(.value))
    }

    func testDiv0ErrorLiteral() throws {
        let result = try parseAndEval("#DIV/0!")
        XCTAssertEqual(result, .error(.div0))
    }

    // MARK: - Division by Zero

    func testDivisionByZero() throws {
        let result = try parseAndEval("1/0")
        XCTAssertEqual(result, .error(.div0))
    }

    // MARK: - Function Calls

    func testSumRange() throws {
        let cells = MockCells(data: [
            "A1": .number(1), "A2": .number(2), "A3": .number(3),
            "A4": .number(4), "A5": .number(5),
        ])
        try assertNumericResult("SUM(A1:A5)", cells: cells, expected: 15)
    }

    func testAverageRange() throws {
        let cells = MockCells(data: [
            "A1": .number(10), "A2": .number(20), "A3": .number(30),
        ])
        try assertNumericResult("AVERAGE(A1:A3)", cells: cells, expected: 20)
    }

    func testCountRange() throws {
        let cells = MockCells(data: [
            "A1": .number(1), "A2": .number(2), "A3": .number(3),
        ])
        try assertNumericResult("COUNT(A1:A3)", cells: cells, expected: 3)
    }

    func testMinMax() throws {
        let cells = MockCells(data: [
            "A1": .number(5), "A2": .number(2), "A3": .number(8),
        ])
        try assertNumericResult("MIN(A1:A3)", cells: cells, expected: 2)
        try assertNumericResult("MAX(A1:A3)", cells: cells, expected: 8)
    }

    func testSumDividedByCount() throws {
        let cells = MockCells(data: [
            "A1": .number(10), "A2": .number(20), "A3": .number(30),
        ])
        try assertNumericResult("SUM(A1:A3)/COUNT(A1:A3)", cells: cells, expected: 20)
    }

    func testNestedFunction() throws {
        let cells = MockCells(data: [
            "A1": .number(4), "A2": .number(9), "A3": .number(16),
        ])
        try assertNumericResult("SUM(A1:A3)+1", cells: cells, expected: 30)
    }

    func testIfFunction() throws {
        let cells = MockCells(data: ["A1": .number(10)])
        let result = try parseAndEval("IF(A1>5,\"big\",\"small\")", cells: cells)
        XCTAssertEqual(result, .text("big"))

        let cells2 = MockCells(data: ["A1": .number(3)])
        let result2 = try parseAndEval("IF(A1>5,\"big\",\"small\")", cells: cells2)
        XCTAssertEqual(result2, .text("small"))
    }

    func testFunctionCaseInsensitive() throws {
        let cells = MockCells(data: ["A1": .number(5), "A2": .number(10)])
        try assertNumericResult("sum(A1:A2)", cells: cells, expected: 15)
    }

    // MARK: - Sheet References

    func testSheetRefEval() throws {
        let cells = MockCells(
            data: [:],
            sheetData: ["Sheet2": ["A1": .number(99)]]
        )
        try assertNumericResult("'Sheet2'!A1", cells: cells, expected: 99)
    }

    func testSheetRefInExpression() throws {
        let cells = MockCells(
            data: ["A1": .number(10)],
            sheetData: ["Other": ["A1": .number(5)]]
        )
        try assertNumericResult("A1+'Other'!A1", cells: cells, expected: 15)
    }

    // MARK: - Leading Equals

    func testLeadingEqualsStripped() throws {
        try assertNumericResult("=1+2", expected: 3)
    }

    func testLeadingEqualsWithFunction() throws {
        let cells = MockCells(data: ["A1": .number(5), "A2": .number(10)])
        try assertNumericResult("=SUM(A1:A2)", cells: cells, expected: 15)
    }

    // MARK: - Complex Real-World Formulas

    func testPMTFormulaEval() throws {
        let cells = MockCells(data: [
            "B1": .number(100000),
            "B2": .number(0.06),
            "B3": .number(360),
        ])
        let result = try parseAndEval("PMT(B2/12,B3,-B1)", cells: cells)
        guard case .number(let pmt) = result else {
            XCTFail("Expected number, got \(result)")
            return
        }
        XCTAssertEqual(pmt, 599.55, accuracy: 0.01)
    }

    func testNormalizedRangeFormula() throws {
        let cells = MockCells(data: [
            "A1": .number(5), "A2": .number(3),
            "A3": .number(8), "A4": .number(2),
            "A5": .number(7),
        ])
        let formula = "(MAX(A1:A5)-MIN(A1:A5))"
        try assertNumericResult(formula, cells: cells, expected: 6)
    }

    func testPercentageCalculation() throws {
        let cells = MockCells(data: ["A1": .number(80), "B1": .number(100)])
        try assertNumericResult("A1/B1*100", cells: cells, expected: 80)
    }

    func testWeightedAverage() throws {
        let cells = MockCells(data: [
            "A1": .number(90), "B1": .number(0.3),
            "A2": .number(80), "B2": .number(0.7),
        ])
        try assertNumericResult("A1*B1+A2*B2", cells: cells, expected: 83)
    }

    func testWriteFormulaIntegration() throws {
        let wb = Workbook()
        let ws = wb.addSheet(name: "Sheet1")
        ws.write(100000.0, to: "B1")
        ws.write(0.06, to: "B2")
        ws.write(360, to: "B3")
        ws.writeFormula("PMT(B2/12,B3,-B1)", to: "B4")

        let cellValue = ws.cell(at: "B4")
        guard case .formula(let ast, _) = cellValue else {
            XCTFail("Expected formula cell, got \(String(describing: cellValue))")
            return
        }
        let expected: FormulaAST = .function("PMT", [
            .divide(.cellRef(CellRef("B2")), .number(12)),
            .cellRef(CellRef("B3")),
            .negate(.cellRef(CellRef("B1"))),
        ])
        XCTAssertEqual(ast, expected)
    }

    func testWriteFormulaFallback() throws {
        let wb = Workbook()
        let ws = wb.addSheet(name: "Sheet1")
        ws.writeFormula("!!!invalid!!!", to: "A1")

        let cellValue = ws.cell(at: "A1")
        guard case .formula(let ast, _) = cellValue else {
            XCTFail("Expected formula cell, got \(String(describing: cellValue))")
            return
        }
        XCTAssertEqual(ast, .function("_RAW", [.text("!!!invalid!!!")]))
    }
}
