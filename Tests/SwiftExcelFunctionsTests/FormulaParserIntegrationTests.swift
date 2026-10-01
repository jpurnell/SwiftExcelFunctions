import Foundation
import Testing
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

@Suite struct FormulaParserIntegrationTests {

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


    // MARK: - Arithmetic Literals

    @Test func addLiterals() throws {
        #expect(try parseAndEval("1+2").isNumber(3))
    }

    @Test func subtractLiterals() throws {
        #expect(try parseAndEval("10-3").isNumber(7))
    }

    @Test func multiplyLiterals() throws {
        #expect(try parseAndEval("4*5").isNumber(20))
    }

    @Test func divideLiterals() throws {
        #expect(try parseAndEval("15/3").isNumber(5))
    }

    @Test func powerLiterals() throws {
        #expect(try parseAndEval("2^10").isNumber(1024))
    }

    @Test func negation() throws {
        #expect(try parseAndEval("-5+8").isNumber(3))
    }

    @Test func precedenceAddMul() throws {
        #expect(try parseAndEval("2+3*4").isNumber(14))
    }

    @Test func parensOverride() throws {
        #expect(try parseAndEval("(2+3)*4").isNumber(20))
    }

    @Test func leftAssocSubtract() throws {
        #expect(try parseAndEval("10-3-2").isNumber(5))
    }

    @Test func leftAssocDivide() throws {
        #expect(try parseAndEval("100/5/4").isNumber(5))
    }

    @Test func complexPrecedence() throws {
        #expect(try parseAndEval("1+2*3^2").isNumber(19))
    }

    // MARK: - Cell References

    @Test func cellRefAdd() throws {
        let cells = MockCells(data: ["A1": .number(10), "B1": .number(20)])
        #expect(try parseAndEval("A1+B1", cells: cells).isNumber(30))
    }

    @Test func cellRefMultiply() throws {
        let cells = MockCells(data: ["A1": .number(5), "B1": .number(3)])
        #expect(try parseAndEval("A1*B1+1", cells: cells).isNumber(16))
    }

    @Test func absoluteCellRef() throws {
        let cells = MockCells(data: ["$A$1": .number(42)])
        #expect(try parseAndEval("$A$1*2", cells: cells).isNumber(84))
    }

    @Test func blankCellDefaultsToZero() throws {
        #expect(try parseAndEval("A1+5").isNumber(5))
    }

    // MARK: - String Operations

    @Test func concatenateStrings() throws {
        let result = try parseAndEval("\"hello\"&\" \"&\"world\"")
        #expect(result == .text("hello world"))
    }

    @Test func concatenateWithNumber() throws {
        let cells = MockCells(data: ["A1": .number(42)])
        let result = try parseAndEval("\"Value: \"&A1", cells: cells)
        #expect(result == .text("Value: 42"))
    }

    // MARK: - Comparisons

    @Test func equalTrue() throws {
        let result = try parseAndEval("1+1=2")
        #expect(result == .bool(true))
    }

    @Test func equalFalse() throws {
        let result = try parseAndEval("1+1=3")
        #expect(result == .bool(false))
    }

    @Test func greaterThan() throws {
        let result = try parseAndEval("5>3")
        #expect(result == .bool(true))
    }

    @Test func lessThan() throws {
        let result = try parseAndEval("3<5")
        #expect(result == .bool(true))
    }

    @Test func notEqual() throws {
        let result = try parseAndEval("1<>2")
        #expect(result == .bool(true))
    }

    @Test func greaterOrEqual() throws {
        let result = try parseAndEval("5>=5")
        #expect(result == .bool(true))
    }

    @Test func lessOrEqual() throws {
        let result = try parseAndEval("3<=5")
        #expect(result == .bool(true))
    }

    // MARK: - Boolean Literals

    @Test func boolLiteralTrue() throws {
        let result = try parseAndEval("TRUE")
        #expect(result == .bool(true))
    }

    @Test func boolLiteralFalse() throws {
        let result = try parseAndEval("FALSE")
        #expect(result == .bool(false))
    }

    @Test func boolInArithmetic() throws {
        #expect(try parseAndEval("TRUE+1").isNumber(2))
    }

    // MARK: - Error Literals

    @Test func errorLiteral() throws {
        let result = try parseAndEval("#VALUE!")
        #expect(result == .error(.value))
    }

    @Test func errorPropagation() throws {
        let result = try parseAndEval("#VALUE!+1")
        #expect(result == .error(.value))
    }

    @Test func div0ErrorLiteral() throws {
        let result = try parseAndEval("#DIV/0!")
        #expect(result == .error(.div0))
    }

    // MARK: - Division by Zero

    @Test func divisionByZero() throws {
        let result = try parseAndEval("1/0")
        #expect(result == .error(.div0))
    }

    // MARK: - Function Calls

    @Test func sumRange() throws {
        let cells = MockCells(data: [
            "A1": .number(1), "A2": .number(2), "A3": .number(3),
            "A4": .number(4), "A5": .number(5),
        ])
        #expect(try parseAndEval("SUM(A1:A5)", cells: cells).isNumber(15))
    }

    @Test func averageRange() throws {
        let cells = MockCells(data: [
            "A1": .number(10), "A2": .number(20), "A3": .number(30),
        ])
        #expect(try parseAndEval("AVERAGE(A1:A3)", cells: cells).isNumber(20))
    }

    @Test func countRange() throws {
        let cells = MockCells(data: [
            "A1": .number(1), "A2": .number(2), "A3": .number(3),
        ])
        #expect(try parseAndEval("COUNT(A1:A3)", cells: cells).isNumber(3))
    }

    @Test func minMax() throws {
        let cells = MockCells(data: [
            "A1": .number(5), "A2": .number(2), "A3": .number(8),
        ])
        #expect(try parseAndEval("MIN(A1:A3)", cells: cells).isNumber(2))
        #expect(try parseAndEval("MAX(A1:A3)", cells: cells).isNumber(8))
    }

    @Test func sumDividedByCount() throws {
        let cells = MockCells(data: [
            "A1": .number(10), "A2": .number(20), "A3": .number(30),
        ])
        #expect(try parseAndEval("SUM(A1:A3)/COUNT(A1:A3)", cells: cells).isNumber(20))
    }

    @Test func nestedFunction() throws {
        let cells = MockCells(data: [
            "A1": .number(4), "A2": .number(9), "A3": .number(16),
        ])
        #expect(try parseAndEval("SUM(A1:A3)+1", cells: cells).isNumber(30))
    }

    @Test func ifFunction() throws {
        let cells = MockCells(data: ["A1": .number(10)])
        let result = try parseAndEval("IF(A1>5,\"big\",\"small\")", cells: cells)
        #expect(result == .text("big"))

        let cells2 = MockCells(data: ["A1": .number(3)])
        let result2 = try parseAndEval("IF(A1>5,\"big\",\"small\")", cells: cells2)
        #expect(result2 == .text("small"))
    }

    @Test func functionCaseInsensitive() throws {
        let cells = MockCells(data: ["A1": .number(5), "A2": .number(10)])
        #expect(try parseAndEval("sum(A1:A2)", cells: cells).isNumber(15))
    }

    // MARK: - Sheet References

    @Test func sheetRefEval() throws {
        let cells = MockCells(
            data: [:],
            sheetData: ["Sheet2": ["A1": .number(99)]]
        )
        #expect(try parseAndEval("'Sheet2'!A1", cells: cells).isNumber(99))
    }

    @Test func sheetRefInExpression() throws {
        let cells = MockCells(
            data: ["A1": .number(10)],
            sheetData: ["Other": ["A1": .number(5)]]
        )
        #expect(try parseAndEval("A1+'Other'!A1", cells: cells).isNumber(15))
    }

    // MARK: - Leading Equals

    @Test func leadingEqualsStripped() throws {
        #expect(try parseAndEval("=1+2").isNumber(3))
    }

    @Test func leadingEqualsWithFunction() throws {
        let cells = MockCells(data: ["A1": .number(5), "A2": .number(10)])
        #expect(try parseAndEval("=SUM(A1:A2)", cells: cells).isNumber(15))
    }

    // MARK: - Complex Real-World Formulas

    @Test func pmtFormulaEval() throws {
        let cells = MockCells(data: [
            "B1": .number(100000),
            "B2": .number(0.06),
            "B3": .number(360),
        ])
        let result = try parseAndEval("PMT(B2/12,B3,-B1)", cells: cells)
        guard case .number(let pmt) = result else {
            Issue.record("Expected number, got \(result)")
            return
        }
        #expect(abs(pmt - 599.55) <= 0.01)
    }

    @Test func normalizedRangeFormula() throws {
        let cells = MockCells(data: [
            "A1": .number(5), "A2": .number(3),
            "A3": .number(8), "A4": .number(2),
            "A5": .number(7),
        ])
        let formula = "(MAX(A1:A5)-MIN(A1:A5))"
        #expect(try parseAndEval(formula, cells: cells).isNumber(6))
    }

    @Test func percentageCalculation() throws {
        let cells = MockCells(data: ["A1": .number(80), "B1": .number(100)])
        #expect(try parseAndEval("A1/B1*100", cells: cells).isNumber(80))
    }

    @Test func weightedAverage() throws {
        let cells = MockCells(data: [
            "A1": .number(90), "B1": .number(0.3),
            "A2": .number(80), "B2": .number(0.7),
        ])
        #expect(try parseAndEval("A1*B1+A2*B2", cells: cells).isNumber(83))
    }

    @Test func writeFormulaIntegration() throws {
        let wb = Workbook()
        let ws = wb.addSheet(name: "Sheet1")
        ws.write(100000.0, to: "B1")
        ws.write(0.06, to: "B2")
        ws.write(360, to: "B3")
        ws.writeFormula("PMT(B2/12,B3,-B1)", to: "B4")

        let cellValue = ws.cell(at: "B4")
        guard case .formula(let ast, _) = cellValue else {
            Issue.record("Expected formula cell, got \(String(describing: cellValue))")
            return
        }
        let expected: FormulaAST = .function("PMT", [
            .divide(.cellRef(CellRef("B2")), .number(12)),
            .cellRef(CellRef("B3")),
            .negate(.cellRef(CellRef("B1"))),
        ])
        #expect(ast == expected)
    }

    @Test func writeFormulaFallback() throws {
        let wb = Workbook()
        let ws = wb.addSheet(name: "Sheet1")
        ws.writeFormula("!!!invalid!!!", to: "A1")

        let cellValue = ws.cell(at: "A1")
        guard case .formula(let ast, _) = cellValue else {
            Issue.record("Expected formula cell, got \(String(describing: cellValue))")
            return
        }
        #expect(ast == .function("_RAW", [.text("!!!invalid!!!")]))
    }
}
