import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// `VLOOKUP` against a **table written as an array constant**.
///
/// Round sixteen asks Excel about a blank lookup value, and it has to ask with a table it can
/// carry in the formula — `{0,"zero";10,"ten"}` — because a conformance case is one string.
/// Emitting the round showed this package answering `#N/A` to the *control* row, where the
/// key is really there, so the question could not have been asked honestly.
final class VlookupArrayConstantTests: XCTestCase {

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
                                      cells: NoCells(), names: NoNames(), inSheet: "S")
    }

    /// The constant is two rows of two columns — `;` separates rows, `,` columns.
    func testTheConstantsShape() throws {
        XCTAssertEqual(try evaluate("ROWS({0,\"zero\";10,\"ten\"})"), .number(2))
        XCTAssertEqual(try evaluate("COLUMNS({0,\"zero\";10,\"ten\"})"), .number(2))
    }

    func testAnExactHitAgainstAConstantTable() throws {
        XCTAssertEqual(try evaluate("VLOOKUP(10,{0,\"zero\";10,\"ten\"},2,FALSE)"), .text("ten"))
        XCTAssertEqual(try evaluate("VLOOKUP(0,{0,\"zero\";10,\"ten\"},2,FALSE)"), .text("zero"))
    }

    func testAnApproximateHitAgainstAConstantTable() throws {
        XCTAssertEqual(try evaluate("VLOOKUP(10,{0,\"zero\";10,\"ten\"},2,TRUE)"), .text("ten"))
        XCTAssertEqual(try evaluate("VLOOKUP(7,{0,\"zero\";10,\"ten\"},2,TRUE)"), .text("zero"),
                       "the largest key not exceeding 7")
    }
}
