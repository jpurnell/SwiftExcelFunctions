import Foundation
import SwiftExcelCore
import SwiftXLSX
import XCTest
@testable import SwiftExcelFunctions

/// A defined name means different things on different sheets.
///
/// Excel scopes a name either to the workbook or to a single sheet, and a workbook may hold
/// both spellings at once. A teaching model in the corpus defines `MarketGrapeCost` three
/// times — once for each of two sheets and once for the workbook — each pointing at a
/// different cell.
///
/// The evaluator resolved names with no sheet at all, so it always found the workbook-scoped
/// definition. **31 cells in that one workbook read another sheet's number**, answering 0.3
/// where Excel answers 0.812. Nothing errored; the answers were simply from the wrong place.
final class ScopedNameResolutionTests: XCTestCase {

    /// Two sheets, each with a cell of its own, plus a third the workbook-scoped name points at.
    private struct Cells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { value(at: ref, inSheet: "") }
        func value(at ref: CellRef, inSheet: String) -> CellValue? {
            switch inSheet {
            case "Breakeven": return .number(0.812)
            case "Model": return .number(0.3)
            default: return nil
            }
        }
        func lastPopulatedCell() -> CellRef? { CellRef("A1") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("A1") }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }

    /// `Cost` defined twice: for the workbook, pointing at `Model`, and for one sheet,
    /// pointing at itself.
    private var names: NamedRangeCollection {
        var collection = NamedRangeCollection()
        collection.add(NamedRange(
            name: "Cost",
            reference: .sheetCell(SheetReference(
                sheet: "Model",
                range: CellRange(from: CellRef("A1"), to: CellRef("A1")))),
            scope: .workbook))
        collection.add(NamedRange(
            name: "Cost",
            reference: .sheetCell(SheetReference(
                sheet: "Breakeven",
                range: CellRange(from: CellRef("A1"), to: CellRef("A1")))),
            scope: .sheet("Breakeven")))
        return collection
    }

    private func evaluate(_ formula: String, onSheet sheet: String) throws -> CellValue {
        try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                      cells: Cells(), names: names, inSheet: sheet)
    }

    /// On a sheet with its own definition, that one wins.
    func testASheetScopedNameBeatsTheWorkbookOne() throws {
        XCTAssertEqual(try evaluate("Cost", onSheet: "Breakeven"), .number(0.812))
    }

    /// On any other sheet, the workbook definition is the only one there is.
    func testTheWorkbookNameIsUsedWhereNoSheetScopedOneExists() throws {
        XCTAssertEqual(try evaluate("Cost", onSheet: "Model"), .number(0.3))
        XCTAssertEqual(try evaluate("Cost", onSheet: "Somewhere Else"), .number(0.3))
    }

    /// Evaluated outside any sheet, the workbook definition still resolves.
    ///
    /// The empty sheet name is "no sheet" rather than a sheet called `""`, and passing it
    /// through as a name to match would make every scoped lookup fail.
    func testNoSheetStillFindsTheWorkbookName() throws {
        XCTAssertEqual(try evaluate("Cost", onSheet: ""), .number(0.3))
    }

    /// A name nothing defines is `#NAME?`, scoped or not.
    func testAnUndefinedNameIsStillAnError() throws {
        XCTAssertEqual(try evaluate("Nonexistent", onSheet: "Breakeven"), .error(.name))
    }
}
