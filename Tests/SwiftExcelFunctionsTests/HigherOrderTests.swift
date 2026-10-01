import Foundation
import Testing
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// The six functions that take a `LAMBDA` and do something with it.
///
/// `MAP`, `REDUCE`, `SCAN`, `BYROW`, `BYCOL` and `MAKEARRAY`. Step 6, and the payoff for the
/// five before it: each one is a handful of lines once a lambda is a value that can be called.
///
/// `REDUCE` is also the one whose bound was measured directly — it reached 8,192 without
/// complaint, answering 33,558,528, which is 8192 × 8193 ÷ 2 to the digit. It iterates rather
/// than recursing, and whatever bounds recursion does not bound it.
@Suite struct HigherOrderTests {

    private struct Cells: CellValueProvider {
        var data: [String: CellValue] = [:]
        func value(at ref: CellRef) -> CellValue? { data[ref.reference] }
        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet sheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { range.cells.compactMap { value(at: $0) } }
        func values(in range: CellRange, inSheet sheet: String) -> [CellValue] { [] }
    }
    private struct Names: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func eval(_ ast: FormulaAST, cells: Cells = Cells()) throws -> CellValue {
        try FormulaEvaluator.evaluate(ast, cells: cells, names: Names(), functions: .builtin)
    }

    private func lambda(_ parameters: [String], _ body: FormulaAST) -> FormulaAST {
        .function("LAMBDA", parameters.map { .namedRange($0) } + [body])
    }

    private func numbers(_ value: CellValue) -> [Double]? {
        guard case .array(let matrix) = value else { return nil }
        return matrix.elements.map { if case .number(let n) = $0 { return n } else { return .nan } }
    }

    private func shape(_ value: CellValue) -> (rows: Int, columns: Int)? {
        guard case .array(let matrix) = value else { return nil }
        return (matrix.rows, matrix.columns)
    }

    /// A1:A4 = 1, 2, 3, 4 — a column.
    private var column: Cells {
        Cells(data: ["A1": .number(1), "A2": .number(2), "A3": .number(3), "A4": .number(4)])
    }
    private var columnRef: FormulaAST { .cellRange(CellRange(from: "A1", to: "A4")) }

    /// A1:C2 = 1 2 3 / 4 5 6 — a block.
    private var block: Cells {
        Cells(data: ["A1": .number(1), "B1": .number(2), "C1": .number(3),
                     "A2": .number(4), "B2": .number(5), "C2": .number(6)])
    }
    private var blockRef: FormulaAST { .cellRange(CellRange(from: "A1", to: "C2")) }

    // MARK: - MAP

    @Test func mapAppliesToEveryElement() throws {
        let result = try eval(
            .function("MAP", [columnRef, lambda(["v"], .multiply(.namedRange("v"), .number(10)))]),
            cells: column)
        #expect(numbers(result)?.isElementwiseEqual(to: [10, 20, 30, 40]) == true)
    }

    /// The result keeps the shape it was given.
    @Test func mapKeepsTheShape() throws {
        let result = try eval(
            .function("MAP", [blockRef, lambda(["v"], .add(.namedRange("v"), .number(1)))]),
            cells: block)
        #expect(shape(result)?.rows == 2)
        #expect(shape(result)?.columns == 3)
        #expect(numbers(result)?.isElementwiseEqual(to: [2, 3, 4, 5, 6, 7]) == true)
    }

    /// Two arrays, and the lambda takes two parameters.
    @Test func mapOverTwoArrays() throws {
        let cells = Cells(data: ["A1": .number(1), "A2": .number(2),
                                 "B1": .number(10), "B2": .number(20)])
        let result = try eval(.function("MAP", [
            .cellRange(CellRange(from: "A1", to: "A2")),
            .cellRange(CellRange(from: "B1", to: "B2")),
            lambda(["a", "b"], .multiply(.namedRange("a"), .namedRange("b"))),
        ]), cells: cells)
        #expect(numbers(result)?.isElementwiseEqual(to: [10, 40]) == true)
    }

    /// Arrays of different shapes cannot be walked together.
    @Test func mapRefusesMismatchedShapes() throws {
        let cells = Cells(data: ["A1": .number(1), "A2": .number(2), "B1": .number(10)])
        let result = try eval(.function("MAP", [
            .cellRange(CellRange(from: "A1", to: "A2")),
            .cellRange(CellRange(from: "B1", to: "B1")),
            lambda(["a", "b"], .add(.namedRange("a"), .namedRange("b"))),
        ]), cells: cells)
        #expect(result == .error(.value))
    }

    // MARK: - REDUCE

    @Test func reduceFolds() throws {
        let result = try eval(.function("REDUCE", [
            .number(0), columnRef,
            lambda(["acc", "v"], .add(.namedRange("acc"), .namedRange("v"))),
        ]), cells: column)
        #expect(result == .number(10))
    }

    /// The initial value is the accumulator's starting point, not an element.
    @Test func reduceUsesItsInitialValue() throws {
        let result = try eval(.function("REDUCE", [
            .number(100), columnRef,
            lambda(["acc", "v"], .add(.namedRange("acc"), .namedRange("v"))),
        ]), cells: column)
        #expect(result == .number(110))
    }

    /// The measured shape: `REDUCE` over `SEQUENCE(n)` is n(n+1)/2, and it iterates rather
    /// than recursing — the conformance round reached 8,192 without complaint.
    @Test func reduceIteratesRatherThanRecursing() throws {
        let n = 2_000
        let cells = Cells(data: Dictionary(
            uniqueKeysWithValues: (1...n).map { ("A\($0)", CellValue.number(Double($0))) }))
        let result = try eval(.function("REDUCE", [
            .number(0), .cellRange(CellRange(from: "A1", to: "A\(n)")),
            lambda(["acc", "v"], .add(.namedRange("acc"), .namedRange("v"))),
        ]), cells: cells)
        #expect(result == .number(Double(n * (n + 1) / 2)), "2,000 iterations is far past the ~160 levels recursion reaches")
    }

    // MARK: - SCAN

    /// `SCAN` is `REDUCE` that keeps its working.
    @Test func scanKeepsEveryIntermediateValue() throws {
        let result = try eval(.function("SCAN", [
            .number(0), columnRef,
            lambda(["acc", "v"], .add(.namedRange("acc"), .namedRange("v"))),
        ]), cells: column)
        #expect(numbers(result)?.isElementwiseEqual(to: [1, 3, 6, 10]) == true)
        #expect(shape(result)?.rows == 4)
        #expect(shape(result)?.columns == 1)
    }

    // MARK: - BYROW / BYCOL

    @Test func byRowGivesOneAnswerPerRow() throws {
        let result = try eval(.function("BYROW", [
            blockRef, lambda(["r"], .function("SUM", [.namedRange("r")])),
        ]), cells: block)
        #expect(numbers(result)?.isElementwiseEqual(to: [6, 15]) == true)
        #expect(shape(result)?.columns == 1, "a column of answers, one per row")
    }

    @Test func byColGivesOneAnswerPerColumn() throws {
        let result = try eval(.function("BYCOL", [
            blockRef, lambda(["c"], .function("SUM", [.namedRange("c")])),
        ]), cells: block)
        #expect(numbers(result)?.isElementwiseEqual(to: [5, 7, 9]) == true)
        #expect(shape(result)?.rows == 1, "a row of answers, one per column")
    }

    /// The lambda is handed the whole row, not its first cell.
    @Test func byRowPassesTheWholeRow() throws {
        let result = try eval(.function("BYROW", [
            blockRef, lambda(["r"], .function("COUNT", [.namedRange("r")])),
        ]), cells: block)
        #expect(numbers(result)?.isElementwiseEqual(to: [3, 3]) == true)
    }

    // MARK: - MAKEARRAY

    @Test func makeArrayBuildsFromItsIndices() throws {
        let result = try eval(.function("MAKEARRAY", [
            .number(2), .number(3),
            lambda(["r", "c"], .add(.multiply(.namedRange("r"), .number(10)),
                                    .namedRange("c"))),
        ]))
        #expect(numbers(result)?.isElementwiseEqual(to: [11, 12, 13, 21, 22, 23]) == true)
        #expect(shape(result)?.rows == 2)
        #expect(shape(result)?.columns == 3)
    }

    /// The indices are one-based, as everything in a spreadsheet is.
    @Test func makeArrayIndicesAreOneBased() throws {
        let result = try eval(.function("MAKEARRAY", [
            .number(1), .number(1), lambda(["r", "c"], .add(.namedRange("r"), .namedRange("c"))),
        ]))
        #expect(numbers(result)?.isElementwiseEqual(to: [2]) == true)
    }

    @Test func makeArrayRefusesANonPositiveSize() throws {
        #expect(try eval(.function("MAKEARRAY", [.number(0), .number(2), lambda(["r", "c"], .number(1))])) == .error(.value))
    }

    // MARK: - The lambda argument

    /// A named lambda works as the argument, which is how the corpus writes it.
    @Test func theLambdaMayBeANamedOne() throws {
        struct Named: NameResolver {
            func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? {
                name.lowercased() == "twice"
                    ? .formula(.function("LAMBDA", [
                        .namedRange("v"), .multiply(.namedRange("v"), .number(2))]))
                    : nil
            }
        }
        let result = try FormulaEvaluator.evaluate(
            .function("MAP", [columnRef, .namedRange("twice")]),
            cells: column, names: Named(), functions: .builtin)
        #expect(numbers(result)?.isElementwiseEqual(to: [2, 4, 6, 8]) == true)
    }

    /// Anything that is not a function in the lambda position is `#VALUE!`.
    @Test func aNonLambdaIsRefused() throws {
        #expect(try eval(.function("MAP", [columnRef, .number(3)]), cells: column) == .error(.value))
    }

    /// A lambda whose arity does not match what the function will pass it.
    @Test func theArityMustMatch() throws {
        #expect(try eval(.function("MAP", [columnRef, lambda(["a", "b"], .number(1))]),
                     cells: column) == .error(.value))
    }
}
