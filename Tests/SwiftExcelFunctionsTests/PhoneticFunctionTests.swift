import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// `PHONETIC(reference)` — the furigana stored alongside a cell.
///
/// **The only function in the text family that reads a cell rather than a value.** The
/// reading is not in the cell's value — 山田 is what the cell says, ヤマダ is how to say it —
/// so it cannot arrive as an argument. It comes through the same seam `COLUMN(B5)` uses to
/// recover an address instead of the number inside it.
final class PhoneticFunctionTests: XCTestCase {

    /// A sheet that knows one reading, for one cell.
    private struct Cells: CellValueProvider {
        var readings: [String: String] = ["A1": "ヤマダ"]
        func value(at ref: CellRef) -> CellValue? {
            ref.reference == "A1" ? .text("山田") : .text("Smith")
        }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { value(at: ref) }
        func lastPopulatedCell() -> CellRef? { CellRef("B2") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
        func values(in range: CellRange) -> [CellValue] { range.cells.compactMap { value(at: $0) } }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
        func phonetic(at ref: CellRef) -> String? { readings[ref.reference] }
    }

    /// The AST is built directly rather than parsed, so this suite does not depend on
    /// SwiftXLSX's parser — the same choice ``ReferenceFunctionTests`` makes.
    private func evaluate(_ argument: FormulaAST) throws -> CellValue {
        try FormulaEvaluator.evaluate(
            .function("PHONETIC", [argument]),
            cells: Cells(), names: NamedRangeCollection(),
            at: CellAddress(sheet: "Sheet1", ref: "D7"), inSheet: "Sheet1")
    }

    func testReadsTheReadingOfTheReferencedCell() throws {
        XCTAssertEqual(try evaluate(.cellRef(CellRef("A1"))), .text("ヤマダ"))
    }

    /// **A cell with no reading answers with empty text, not an error.** Every workbook
    /// outside a Japanese locale is this case, and `#N/A` would make `PHONETIC` a landmine
    /// in any sheet that merely mentions it.
    ///
    /// Not measured against Excel — producing furigana needs a Japanese-locale editor —
    /// so this pins our answer rather than confirming theirs.
    func testCellWithoutAReadingIsEmptyText() throws {
        XCTAssertEqual(try evaluate(.cellRef(CellRef("B2"))), .text(""))
    }

    /// **It needs the reference, not the value.** `PHONETIC` given a literal has no cell to
    /// ask about, which is the same shape as `COLUMN(5)`.
    func testALiteralHasNoCellToAskAbout() throws {
        XCTAssertEqual(try evaluate(.text("山田")), .error(.value))
    }
}
