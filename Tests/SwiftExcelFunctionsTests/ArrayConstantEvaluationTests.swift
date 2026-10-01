import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// Array constants, evaluated: `{1,2,3;4,5,6}`.
///
/// Parsing landed in SwiftXLSX 0.31.0 with `FormulaAST.arrayConstant` from SwiftExcelCore
/// 0.13.0. This is the other half — turning one into a `CellMatrix` so every function that
/// already takes an array takes one written in the formula.
///
/// The syntax was missing rather than declined: the lexer had no `{` token, so the first
/// brace ended parsing and the gap read as a decision nobody had got to.
@Suite struct ArrayConstantEvaluationTests {

    private struct NoCells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }
    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    private func evaluate(_ formula: String) throws -> CellValue {
        try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                      cells: NoCells(), names: NoNames())
    }

    private func number(_ formula: String) throws -> Double {
        let value = try evaluate(formula)
        guard case .number(let d) = value else {
            Issue.record("\(formula) gave \(value), expected a number")
            return .nan
        }
        return d
    }

    private func matrix(_ formula: String) throws -> CellMatrix {
        let value = try evaluate(formula)
        guard case .array(let matrix) = value else {
            Issue.record("\(formula) gave \(value), expected an array")
            throw CocoaError(.featureUnsupported)
        }
        return matrix
    }

    // MARK: - Shape

    @Test func theShapeIsRowsByColumns() throws {
        let wide = try matrix("{1,2,3;4,5,6}")
        #expect(wide.rows == 2)
        #expect(wide.columns == 3)

        let column = try matrix("{1;2;3}")
        #expect(column.rows == 3)
        #expect(column.columns == 1)

        let row = try matrix("{1,2,3}")
        #expect(row.rows == 1)
        #expect(row.columns == 3)
    }

    /// Row-major order, which is what every consumer of `CellMatrix` already assumes.
    @Test func elementsAreInRowMajorOrder() throws {
        #expect(try matrix("{1,2,3;4,5,6}").elements == [.number(1), .number(2), .number(3),
                        .number(4), .number(5), .number(6)])
    }

    @Test func mixedTypesSurvive() throws {
        #expect(try matrix("{1,\"a\";TRUE,#N/A}").elements == [.number(1), .text("a"), .bool(true), .error(.na)])
    }

    @Test func negativesSurvive() throws {
        #expect(try matrix("{-1,2,-3.5}").elements == [.number(-1), .number(2), .number(-3.5)])
    }

    // MARK: - As an argument

    /// The point of the feature: functions that take an array now take a written one.
    @Test func aggregatesOverAWrittenArray() throws {
        #expect(try number("SUM({1,2,3})").isEqual(to: 6))
        #expect(try number("SUM({1,2,3;4,5,6})").isEqual(to: 21))
        #expect(try number("COUNT({1,2,3;4,5,6})").isEqual(to: 6))
        #expect(try number("MAX({1,9,3})").isEqual(to: 9))
        #expect(try number("MIN({1,9,3})").isEqual(to: 1))
        #expect(try number("AVERAGE({2,4,6})").isEqual(to: 4))
    }

    @Test func sumProductOverTwoWrittenArrays() throws {
        #expect(try number("SUMPRODUCT({1,2,3},{4,5,6})").isEqual(to: 32))
    }

    /// `ROWS` and `COLUMNS` count an array from its values, not from a reference.
    ///
    /// This is the test that wanted an array literal and could not spell one — the whole
    /// reason the gap was found. It is spelled properly now.
    @Test func rowsAndColumnsCountTheArray() throws {
        #expect(try number("ROWS({1,2,3;4,5,6})").isEqual(to: 2))
        #expect(try number("COLUMNS({1,2,3;4,5,6})").isEqual(to: 3))
        #expect(try number("ROWS({1;2;3})").isEqual(to: 3))
        #expect(try number("COLUMNS({1;2;3})").isEqual(to: 1))
    }

    @Test func lookupIntoAWrittenArray() throws {
        #expect(try number("INDEX({10,20,30},1,2)").isEqual(to: 20))
        #expect(try number("INDEX({1,2;3,4},2,1)").isEqual(to: 3))
    }

    // MARK: - Errors inside

    /// An error element is a value, not a failure to build the array.
    ///
    /// `COUNT` skips it because `COUNT` counts numbers; `SUM` propagates it because summing
    /// an error is an error. Both follow from the element being an ordinary `CellValue`.
    @Test func anErrorElementBehavesLikeAnErrorCell() throws {
        #expect(try number("COUNT({1,#N/A,3})").isEqual(to: 2))
        #expect(try evaluate("SUM({1,#N/A,3})") == .error(.na))
    }
}
