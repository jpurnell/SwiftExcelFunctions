import XCTest
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
final class ArrayConstantEvaluationTests: XCTestCase {

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
            XCTFail("\(formula) gave \(value), expected a number")
            return .nan
        }
        return d
    }

    private func matrix(_ formula: String) throws -> CellMatrix {
        let value = try evaluate(formula)
        guard case .array(let matrix) = value else {
            XCTFail("\(formula) gave \(value), expected an array")
            throw CocoaError(.featureUnsupported)
        }
        return matrix
    }

    // MARK: - Shape

    func testTheShapeIsRowsByColumns() throws {
        let wide = try matrix("{1,2,3;4,5,6}")
        XCTAssertEqual(wide.rows, 2)
        XCTAssertEqual(wide.columns, 3)

        let column = try matrix("{1;2;3}")
        XCTAssertEqual(column.rows, 3)
        XCTAssertEqual(column.columns, 1)

        let row = try matrix("{1,2,3}")
        XCTAssertEqual(row.rows, 1)
        XCTAssertEqual(row.columns, 3)
    }

    /// Row-major order, which is what every consumer of `CellMatrix` already assumes.
    func testElementsAreInRowMajorOrder() throws {
        XCTAssertEqual(try matrix("{1,2,3;4,5,6}").elements,
                       [.number(1), .number(2), .number(3),
                        .number(4), .number(5), .number(6)])
    }

    func testMixedTypesSurvive() throws {
        XCTAssertEqual(try matrix("{1,\"a\";TRUE,#N/A}").elements,
                       [.number(1), .text("a"), .bool(true), .error(.na)])
    }

    func testNegativesSurvive() throws {
        XCTAssertEqual(try matrix("{-1,2,-3.5}").elements,
                       [.number(-1), .number(2), .number(-3.5)])
    }

    // MARK: - As an argument

    /// The point of the feature: functions that take an array now take a written one.
    func testAggregatesOverAWrittenArray() throws {
        XCTAssertEqual(try number("SUM({1,2,3})"), 6)
        XCTAssertEqual(try number("SUM({1,2,3;4,5,6})"), 21)
        XCTAssertEqual(try number("COUNT({1,2,3;4,5,6})"), 6)
        XCTAssertEqual(try number("MAX({1,9,3})"), 9)
        XCTAssertEqual(try number("MIN({1,9,3})"), 1)
        XCTAssertEqual(try number("AVERAGE({2,4,6})"), 4)
    }

    func testSumProductOverTwoWrittenArrays() throws {
        XCTAssertEqual(try number("SUMPRODUCT({1,2,3},{4,5,6})"), 32)
    }

    /// `ROWS` and `COLUMNS` count an array from its values, not from a reference.
    ///
    /// This is the test that wanted an array literal and could not spell one — the whole
    /// reason the gap was found. It is spelled properly now.
    func testRowsAndColumnsCountTheArray() throws {
        XCTAssertEqual(try number("ROWS({1,2,3;4,5,6})"), 2)
        XCTAssertEqual(try number("COLUMNS({1,2,3;4,5,6})"), 3)
        XCTAssertEqual(try number("ROWS({1;2;3})"), 3)
        XCTAssertEqual(try number("COLUMNS({1;2;3})"), 1)
    }

    func testLookupIntoAWrittenArray() throws {
        XCTAssertEqual(try number("INDEX({10,20,30},1,2)"), 20)
        XCTAssertEqual(try number("INDEX({1,2;3,4},2,1)"), 3)
    }

    // MARK: - Errors inside

    /// An error element is a value, not a failure to build the array.
    ///
    /// `COUNT` skips it because `COUNT` counts numbers; `SUM` propagates it because summing
    /// an error is an error. Both follow from the element being an ordinary `CellValue`.
    func testAnErrorElementBehavesLikeAnErrorCell() throws {
        XCTAssertEqual(try number("COUNT({1,#N/A,3})"), 2)
        XCTAssertEqual(try evaluate("SUM({1,#N/A,3})"), .error(.na))
    }
}
