import Foundation
import Testing
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// Functions over the shape of a rectangle rather than its contents.
@Suite struct BuiltinArrayFunctionTests {

    // MARK: - Helpers

    private struct Cells: CellValueProvider {
        var stored: [CellRef: CellValue] = [:]
        func value(at ref: CellRef) -> CellValue? { stored[ref] }
        func lastPopulatedCell() -> CellRef? {
            guard let column = stored.keys.map(\.column).max(),
                  let row = stored.keys.map(\.row).max() else { return nil }
            return CellRef(column: column, row: row)
        }

        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { stored[ref] }
        func values(in range: CellRange) -> [CellValue] { range.cells.compactMap { stored[$0] } }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
    }

    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let fn = BuiltinArrayFunctions.all.first(where: { $0.name == name }) else {
            Issue.record("\(name) is not registered")
            return .error(.name)
        }
        return try fn.evaluate(args)
    }

    private func grid(_ rows: [[CellValue]],
                      sourceLocation: SourceLocation = #_sourceLocation) -> CellValue {
        let width = rows.first?.count ?? 0
        guard rows.allSatisfy({ $0.count == width }),
              let matrix = CellMatrix(elements: rows.flatMap { $0 },
                                      rows: rows.count, columns: width) else {
            Issue.record("ragged table")
            return .error(.value)
        }
        return .array(matrix)
    }

    private func matrix(of value: CellValue,
                        sourceLocation: SourceLocation = #_sourceLocation) throws -> CellMatrix {
        guard case .array(let matrix) = value else {
            Issue.record("expected an array, got \(value)")
            return CellMatrix(row: [])
        }
        return matrix
    }

    // MARK: - Registration

    @Test func allContainsEveryFunctionInTheGroup() {
        #expect(Set(BuiltinArrayFunctions.all.map(\.name)) == ["TRANSPOSE", "COUNTBLANK"])
    }

    // MARK: - TRANSPOSE

    /// A column becomes a row.
    ///
    /// The shape is the whole result: both flatten to the same three values, and
    /// under the old representation this function could not have been written.
    @Test func transposeAColumnIntoARow() throws {
        let column = CellValue.array(CellMatrix(column: [.number(1), .number(2), .number(3)]))
        let result = try matrix(of: try eval("TRANSPOSE", column))
        #expect(result.rows == 1)
        #expect(result.columns == 3)
        #expect(result.elements == [.number(1), .number(2), .number(3)])
    }

    @Test func transposeARowIntoAColumn() throws {
        let row = CellValue.array(CellMatrix(row: [.text("a"), .text("b")]))
        let result = try matrix(of: try eval("TRANSPOSE", row))
        #expect(result.rows == 2)
        #expect(result.columns == 1)
    }

    /// A block, where elements actually move.
    @Test func transposeABlock() throws {
        // 1 2 3        1 4
        // 4 5 6   ->   2 5
        //              3 6
        let block = grid([[.number(1), .number(2), .number(3)],
                          [.number(4), .number(5), .number(6)]])
        let result = try matrix(of: try eval("TRANSPOSE", block))
        #expect(result.rows == 3)
        #expect(result.columns == 2)
        #expect(result[0, 1] == .number(4))
        #expect(result[2, 0] == .number(3))
    }

    @Test func transposeBlanksKeepTheirPlace() throws {
        let block = grid([[.number(1), .blank], [.blank, .number(4)]])
        let result = try matrix(of: try eval("TRANSPOSE", block))
        #expect(result[0, 1] == .blank)
        #expect(result[1, 0] == .blank)
    }

    /// A lone value is a 1×1 rectangle, and transposing it changes nothing.
    @Test func transposeASingleValue() throws {
        let result = try matrix(of: try eval("TRANSPOSE", .number(7)))
        #expect(result.rows == 1)
        #expect(result.columns == 1)
        #expect(result[0, 0] == .number(7))
    }

    @Test func transposeTwiceIsTheIdentity() throws {
        let block = grid([[.number(1), .number(2), .number(3)],
                          [.number(4), .number(5), .number(6)]])
        #expect(try eval("TRANSPOSE", try eval("TRANSPOSE", block)) == block)
    }

    /// End to end, the shape the corpus's own formulas ask for.
    ///
    /// `TRANSPOSE(Assumptions!B11:B32)` is a column read across a row. Here in
    /// miniature: `A1:A3` down the sheet, coming back 1×3.
    @Test func transposeARangeReadFromTheSheet() throws {
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
            Issue.record("expected an array, got \(result)"); return
        }
        #expect(transposed.rows == 1)
        #expect(transposed.columns == 3)
        #expect(transposed.elements == [.number(10), .number(20), .number(30)])
    }

    /// Nested inside another function, which is where a transposed value is
    /// actually usable without spilling it across cells.
    @Test func transposeNestedInAnAggregate() throws {
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
        #expect(result == .number(6))
    }

    @Test func transposePropagatesAnError() throws {
        #expect(try eval("TRANSPOSE", .error(.na)) == .error(.na))
    }

    // MARK: - COUNTBLANK

    /// Counts the holes — which was not merely absent before but impossible,
    /// since blanks never reached a function.
    @Test func countBlankCountsEmptyCells() throws {
        let block = grid([[.number(1), .blank, .number(3)],
                          [.blank, .blank, .number(6)]])
        #expect(try eval("COUNTBLANK", block) == .number(3))
    }

    @Test func countBlankOverARangeReadFromTheSheet() throws {
        var cells = Cells()
        cells.stored[CellRef("A1")] = .number(10)
        // A2, A3 empty
        cells.stored[CellRef("A4")] = .number(40)

        let result = try FormulaEvaluator.evaluate(
            .function("COUNTBLANK", [
                .cellRange(CellRange(from: CellRef("A1"), to: CellRef("A4"))),
            ]),
            cells: cells, names: NamedRangeCollection())
        #expect(result == .number(2))
    }

    @Test func countBlankOfNothingIsZero() throws {
        #expect(try eval("COUNTBLANK", .number(1)) == .number(0))
    }

    /// Excel counts the empty string as blank here, which is the one place it
    /// does. Text of any other length is not.
    @Test func countBlankCountsTheEmptyString() throws {
        let row = CellValue.array(CellMatrix(row: [.text(""), .text("a"), .blank]))
        #expect(try eval("COUNTBLANK", row) == .number(2))
    }

    // MARK: - Registry

    @Test func theseFunctionsAreInTheDefaultRegistry() {
        let registry = FunctionRegistry.builtin
        #expect(registry.resolvedName("TRANSPOSE") == "TRANSPOSE")
        #expect(registry.resolvedName("COUNTBLANK") == "COUNTBLANK")
    }
}
