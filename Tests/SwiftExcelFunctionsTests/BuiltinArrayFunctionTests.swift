import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// Functions over the shape of a rectangle rather than its contents.
final class BuiltinArrayFunctionTests: XCTestCase {

    // MARK: - Helpers

    private struct Cells: CellValueProvider {
        var stored: [CellRef: CellValue] = [:]
        func value(at ref: CellRef) -> CellValue? { stored[ref] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { stored[ref] }
        func values(in range: CellRange) -> [CellValue] { range.cells.compactMap { stored[$0] } }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
    }

    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let fn = BuiltinArrayFunctions.all.first(where: { $0.name == name }) else {
            XCTFail("\(name) is not registered")
            return .error(.name)
        }
        return try fn.evaluate(args)
    }

    private func grid(_ rows: [[CellValue]],
                      file: StaticString = #filePath, line: UInt = #line) -> CellValue {
        let width = rows.first?.count ?? 0
        guard rows.allSatisfy({ $0.count == width }),
              let matrix = CellMatrix(elements: rows.flatMap { $0 },
                                      rows: rows.count, columns: width) else {
            XCTFail("ragged table", file: file, line: line)
            return .error(.value)
        }
        return .array(matrix)
    }

    private func matrix(of value: CellValue,
                        file: StaticString = #filePath, line: UInt = #line) throws -> CellMatrix {
        guard case .array(let matrix) = value else {
            XCTFail("expected an array, got \(value)", file: file, line: line)
            return CellMatrix(row: [])
        }
        return matrix
    }

    // MARK: - Registration

    func testAllContainsEveryFunctionInTheGroup() {
        XCTAssertEqual(Set(BuiltinArrayFunctions.all.map(\.name)), ["TRANSPOSE", "COUNTBLANK"])
    }

    // MARK: - TRANSPOSE

    /// A column becomes a row.
    ///
    /// The shape is the whole result: both flatten to the same three values, and
    /// under the old representation this function could not have been written.
    func testTransposeAColumnIntoARow() throws {
        let column = CellValue.array(CellMatrix(column: [.number(1), .number(2), .number(3)]))
        let result = try matrix(of: try eval("TRANSPOSE", column))
        XCTAssertEqual(result.rows, 1)
        XCTAssertEqual(result.columns, 3)
        XCTAssertEqual(result.elements, [.number(1), .number(2), .number(3)])
    }

    func testTransposeARowIntoAColumn() throws {
        let row = CellValue.array(CellMatrix(row: [.text("a"), .text("b")]))
        let result = try matrix(of: try eval("TRANSPOSE", row))
        XCTAssertEqual(result.rows, 2)
        XCTAssertEqual(result.columns, 1)
    }

    /// A block, where elements actually move.
    func testTransposeABlock() throws {
        // 1 2 3        1 4
        // 4 5 6   ->   2 5
        //              3 6
        let block = grid([[.number(1), .number(2), .number(3)],
                          [.number(4), .number(5), .number(6)]])
        let result = try matrix(of: try eval("TRANSPOSE", block))
        XCTAssertEqual(result.rows, 3)
        XCTAssertEqual(result.columns, 2)
        XCTAssertEqual(result[0, 1], .number(4))
        XCTAssertEqual(result[2, 0], .number(3))
    }

    func testTransposeBlanksKeepTheirPlace() throws {
        let block = grid([[.number(1), .blank], [.blank, .number(4)]])
        let result = try matrix(of: try eval("TRANSPOSE", block))
        XCTAssertEqual(result[0, 1], .blank)
        XCTAssertEqual(result[1, 0], .blank)
    }

    /// A lone value is a 1×1 rectangle, and transposing it changes nothing.
    func testTransposeASingleValue() throws {
        let result = try matrix(of: try eval("TRANSPOSE", .number(7)))
        XCTAssertEqual(result.rows, 1)
        XCTAssertEqual(result.columns, 1)
        XCTAssertEqual(result[0, 0], .number(7))
    }

    func testTransposeTwiceIsTheIdentity() throws {
        let block = grid([[.number(1), .number(2), .number(3)],
                          [.number(4), .number(5), .number(6)]])
        XCTAssertEqual(try eval("TRANSPOSE", try eval("TRANSPOSE", block)), block)
    }

    /// End to end, the shape the corpus's own formulas ask for.
    ///
    /// `TRANSPOSE(Assumptions!B11:B32)` is a column read across a row. Here in
    /// miniature: `A1:A3` down the sheet, coming back 1×3.
    func testTransposeARangeReadFromTheSheet() throws {
        var cells = Cells()
        cells.stored[CellRef("A1")] = .number(10)
        cells.stored[CellRef("A2")] = .number(20)
        cells.stored[CellRef("A3")] = .number(30)

        let result = try FormulaEvaluator.evaluate(
            .function("TRANSPOSE", [
                .cellRange(CellRange(from: CellRef("A1"), to: CellRef("A3"))),
            ]),
            cells: cells, names: NamedRangeCollection())
        guard case .array(let transposed) = result else {
            return XCTFail("expected an array, got \(result)")
        }
        XCTAssertEqual(transposed.rows, 1)
        XCTAssertEqual(transposed.columns, 3)
        XCTAssertEqual(transposed.elements, [.number(10), .number(20), .number(30)])
    }

    /// Nested inside another function, which is where a transposed value is
    /// actually usable without spilling it across cells.
    func testTransposeNestedInAnAggregate() throws {
        var cells = Cells()
        cells.stored[CellRef("A1")] = .number(1)
        cells.stored[CellRef("A2")] = .number(2)
        cells.stored[CellRef("A3")] = .number(3)

        let result = try FormulaEvaluator.evaluate(
            .function("SUM", [
                .function("TRANSPOSE", [
                    .cellRange(CellRange(from: CellRef("A1"), to: CellRef("A3"))),
                ]),
            ]),
            cells: cells, names: NamedRangeCollection())
        XCTAssertEqual(result, .number(6))
    }

    func testTransposePropagatesAnError() throws {
        XCTAssertEqual(try eval("TRANSPOSE", .error(.na)), .error(.na))
    }

    // MARK: - COUNTBLANK

    /// Counts the holes — which was not merely absent before but impossible,
    /// since blanks never reached a function.
    func testCountBlankCountsEmptyCells() throws {
        let block = grid([[.number(1), .blank, .number(3)],
                          [.blank, .blank, .number(6)]])
        XCTAssertEqual(try eval("COUNTBLANK", block), .number(3))
    }

    func testCountBlankOverARangeReadFromTheSheet() throws {
        var cells = Cells()
        cells.stored[CellRef("A1")] = .number(10)
        // A2, A3 empty
        cells.stored[CellRef("A4")] = .number(40)

        let result = try FormulaEvaluator.evaluate(
            .function("COUNTBLANK", [
                .cellRange(CellRange(from: CellRef("A1"), to: CellRef("A4"))),
            ]),
            cells: cells, names: NamedRangeCollection())
        XCTAssertEqual(result, .number(2))
    }

    func testCountBlankOfNothingIsZero() throws {
        XCTAssertEqual(try eval("COUNTBLANK", .number(1)), .number(0))
    }

    /// Excel counts the empty string as blank here, which is the one place it
    /// does. Text of any other length is not.
    func testCountBlankCountsTheEmptyString() throws {
        let row = CellValue.array(CellMatrix(row: [.text(""), .text("a"), .blank]))
        XCTAssertEqual(try eval("COUNTBLANK", row), .number(2))
    }

    // MARK: - Registry

    func testTheseFunctionsAreInTheDefaultRegistry() {
        let registry = FunctionRegistry.builtin
        XCTAssertNotNil(registry.function(named: "TRANSPOSE"))
        XCTAssertNotNil(registry.function(named: "COUNTBLANK"))
    }
}
