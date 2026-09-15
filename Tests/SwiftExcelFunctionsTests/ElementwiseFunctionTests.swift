import Foundation
import SwiftExcelCore
import XCTest
@testable import SwiftExcelFunctions

/// Scalar functions applied across a range.
///
/// Excel does this without being asked: `RIGHT($BQ$1:$BW$1, 1)` is seven last-characters,
/// not an error. **The Excel oracle found 400 cells failing for want of it** — one formula
/// shape repeated down four hundred rows, and the single largest defect in the corpus.
final class ElementwiseFunctionTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ arguments: CellValue...) throws -> CellValue {
        let function = try XCTUnwrap(registry.function(named: name), "\(name) is not registered")
        return try function.evaluate(arguments)
    }

    private func row(_ values: CellValue...) -> CellValue { .array(CellMatrix(row: values)) }

    private func elements(_ value: CellValue) throws -> [CellValue] {
        guard case .array(let matrix) = value else {
            XCTFail("expected an array, got \(value)"); return []
        }
        return matrix.elements
    }

    // MARK: - The shape that prompted this

    /// The whole formula, end to end: `SUMPRODUCT(weights, VALUE(RIGHT(labels, 1)))`.
    func testTheFormulaTheOracleFound() throws {
        let labels = row(.text("a1"), .text("b2"), .text("c3"))
        let weights = row(.number(10), .number(20), .number(30))
        let digits = try call("RIGHT", labels, .number(1))
        let numbers = try call("VALUE", digits)
        // 10×1 + 20×2 + 30×3.
        XCTAssertEqual(try call("SUMPRODUCT", weights, numbers), .number(140))
    }

    func testAScalarFunctionMapsAcrossAnArray() throws {
        let values = row(.text("a1"), .text("b2"), .text("c3"))
        XCTAssertEqual(try elements(try call("RIGHT", values, .number(1))),
                       [.text("1"), .text("2"), .text("3")])
        XCTAssertEqual(try elements(try call("UPPER", values)),
                       [.text("A1"), .text("B2"), .text("C3")])
        XCTAssertEqual(try elements(try call("LEN", values)),
                       [.number(2), .number(2), .number(2)])
    }

    /// A scalar argument stays scalar — the wrapper must not turn every answer into an array.
    func testAScalarCallIsUnchanged() throws {
        XCTAssertEqual(try call("RIGHT", .text("xyz"), .number(1)), .text("z"))
        XCTAssertEqual(try call("LEN", .text("xyz")), .number(3))
        XCTAssertEqual(try call("VALUE", .text("42")), .number(42))
    }

    // MARK: - Shapes

    /// A single value broadcasts against a range, which is how a scalar argument behaves.
    func testASingleElementArrayBroadcasts() throws {
        let values = row(.text("abc"), .text("defg"))
        let one: CellValue = .array(CellMatrix(row: [.number(2)]))
        XCTAssertEqual(try elements(try call("RIGHT", values, one)),
                       [.text("bc"), .text("fg")])
    }

    /// Two genuinely different shapes are refused rather than clipped to the shorter.
    ///
    /// Clipping would answer, and the answer would be the wrong length — which is the sort
    /// of wrong that reads as right.
    func testMismatchedShapesAreRefused() throws {
        let three = row(.text("abc"), .text("def"), .text("ghi"))
        let two: CellValue = .array(CellMatrix(row: [.number(1), .number(2)]))
        XCTAssertEqual(try call("RIGHT", three, two), .error(.value))
    }

    /// The result keeps the input's rectangle rather than flattening it.
    func testTheResultKeepsItsShape() throws {
        let block = CellValue.array(CellMatrix(elements: [.text("ab"), .text("cd"),
                                                          .text("ef"), .text("gh")],
                                               rows: 2, columns: 2) ?? CellMatrix(row: []))
        guard case .array(let result) = try call("UPPER", block) else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(result.rows, 2)
        XCTAssertEqual(result.columns, 2)
    }

    /// Joining functions are deliberately not mapped: handing `CONCAT` a range is a
    /// different request, not the same one repeated.
    ///
    /// The property under test is that the answer is **not an array** — mapping `CONCAT`
    /// elementwise would turn one joined string into a row of unjoined ones.
    ///
    /// It does not assert what `CONCAT` returns, because `CONCAT` does not flatten a range
    /// at all: it answers `""` where Excel answers `"abc"`. That is a separate defect, it
    /// predates this change, and no cell in the corpus exercises it — so it is recorded
    /// rather than quietly fixed under cover of something else.
    func testJoiningFunctionsAreNotMapped() throws {
        let values = row(.text("a"), .text("b"), .text("c"))
        let result = try call("CONCAT", values)
        if case .array = result {
            XCTFail("CONCAT was mapped elementwise; it joins rather than repeating")
        }
    }
}
