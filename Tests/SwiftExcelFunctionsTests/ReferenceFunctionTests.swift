import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The functions that cannot answer from their arguments alone.
///
/// `COLUMN()` asks about the cell it was written in. `INDIRECT` reads a cell
/// chosen while the formula runs. `OFFSET` displaces from a reference whose
/// *address* it needs, not the value inside it. All four are tested through the
/// evaluator rather than by calling them directly, because the wiring that hands
/// them a context is as much the subject as the arithmetic.
///
/// Measured across 79 workbooks: `COLUMN` 86,620 calls, `INDIRECT` 20,978,
/// `OFFSET` 9,798, `ROW` 1,222.
@Suite struct ReferenceFunctionTests {

    /// A sheet held as a dictionary, which is all a provider has to be.
    private struct Cells: CellValueProvider {
        var values: [String: CellValue] = [:]
        var sheets: [String: [String: CellValue]] = [:]

        func value(at ref: CellRef) -> CellValue? { values[ref.reference] }
        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? {
            sheets[sheet]?[ref.reference] ?? (sheet.isEmpty ? values[ref.reference] : nil)
        }
        func lastPopulatedCell() -> CellRef? { Self.corner(of: values) }

        func lastPopulatedCell(inSheet sheet: String) -> CellRef? {
            Self.corner(of: sheets[sheet] ?? [:])
        }

        /// The far corner of a dictionary of cells.
        private static func corner(of cells: [String: CellValue]) -> CellRef? {
            let refs = cells.keys.map { CellRef($0) }
            guard let column = refs.map(\.column).max(),
                  let row = refs.map(\.row).max() else { return nil }
            return CellRef(column: column, row: row)
        }

        func values(in range: CellRange) -> [CellValue] {
            range.cells.compactMap { values[$0.reference] }
        }
        func values(in range: CellRange, inSheet sheet: String) -> [CellValue] {
            range.cells.compactMap { sheets[sheet]?[$0.reference] }
        }
    }

    private func evaluate(
        _ formula: String,
        cells: Cells = Cells(),
        at callingCell: CellAddress? = CellAddress(sheet: "Sheet1", ref: "D7")
    ) throws -> CellValue {
        let ast = try parse(formula)
        return try FormulaEvaluator.evaluate(
            ast, cells: cells, names: NamedRangeCollection(),
            at: callingCell, inSheet: "Sheet1")
    }

    /// Built directly, so this suite does not depend on SwiftXLSX's parser.
    private func parse(_ formula: String) throws -> FormulaAST {
        switch formula {
        case "COLUMN()": return .function("COLUMN", [])
        case "ROW()": return .function("ROW", [])
        case "COLUMN(B5)": return .function("COLUMN", [.cellRef(CellRef("B5"))])
        case "ROW(B5)": return .function("ROW", [.cellRef(CellRef("B5"))])
        case "INDIRECT(\"B2\")": return .function("INDIRECT", [.text("B2")])
        case "INDIRECT(\"nonsense\")": return .function("INDIRECT", [.text("nonsense")])
        case "INDIRECT(\"'Other Sheet'!A1\")":
            return .function("INDIRECT", [.text("'Other Sheet'!A1")])
        case "INDIRECT(\"B2\",FALSE)":
            return .function("INDIRECT", [.text("B2"), .bool(false)])
        case "OFFSET(A1,1,1)":
            return .function("OFFSET", [.cellRef(CellRef("A1")), .number(1), .number(1)])
        case "OFFSET(A1,0,0,3,1)":
            return .function("OFFSET", [.cellRef(CellRef("A1")), .number(0), .number(0),
                                        .number(3), .number(1)])
        case "ISREF(A1)": return .function("ISREF", [.cellRef(CellRef("A1"))])
        case "ISREF(\"A1\")": return .function("ISREF", [.text("A1")])
        case "OFFSET(A1,-5,0)":
            return .function("OFFSET", [.cellRef(CellRef("A1")), .number(-5), .number(0)])
        default: throw TestFailure("unbuilt formula \(formula)")
        }
    }

    // MARK: - COLUMN and ROW

    /// With no argument, the answer is about the cell the formula sits in. D7 is
    /// column 4, row 7.
    @Test func columnAndRowWithNoArgumentDescribeTheCallingCell() throws {
        #expect(try evaluate("COLUMN()") == .number(4))
        #expect(try evaluate("ROW()") == .number(7))
    }

    /// With an argument, the answer is about the address it names — not the value
    /// in it. The cell holds 99 and the answer is still 2.
    @Test func columnAndRowWithAnArgumentDescribeThatReference() throws {
        var cells = Cells()
        cells.values["B5"] = .number(99)
        #expect(try evaluate("COLUMN(B5)", cells: cells) == .number(2))
        #expect(try evaluate("ROW(B5)", cells: cells) == .number(5))
    }

    /// Evaluated outside a sheet there is no calling cell, and no position to
    /// report. Inventing one would be worse than saying so.
    @Test func columnWithoutACallingCellReportsRatherThanGuesses() throws {
        #expect(try evaluate("COLUMN()", at: nil) == .error(.value))
    }

    // MARK: - INDIRECT

    @Test func indirectReadsTheCellItsTextNames() throws {
        var cells = Cells()
        cells.values["B2"] = .number(42)
        #expect(try evaluate("INDIRECT(\"B2\")", cells: cells) == .number(42))
    }

    @Test func indirectResolvesASheetQualifiedReference() throws {
        var cells = Cells()
        cells.sheets["Other Sheet"] = ["A1": .text("found")]
        #expect(try evaluate("INDIRECT(\"'Other Sheet'!A1\")", cells: cells) == .text("found"))
    }

    /// Text that names no cell is `#REF!` — the error Excel gives, and the reason
    /// this function is invisible to static analysis.
    @Test func indirectOnUnreadableTextIsARefError() throws {
        #expect(try evaluate("INDIRECT(\"nonsense\")") == .error(.ref))
    }

    /// R1C1 style is refused rather than misread. Answering in A1 style would
    /// return a plausible value for a different cell.
    @Test func indirectRefusesR1C1RatherThanMisreadingIt() throws {
        #expect(try evaluate("INDIRECT(\"B2\",FALSE)") == .error(.ref))
    }

    // MARK: - ISREF

    /// `ISREF` asks about the *formula*, not the sheet: whether the argument was
    /// written as a reference. Text that looks like one is not one.
    @Test func isRefDistinguishesAReferenceFromTextThatLooksLikeOne() throws {
        #expect(try evaluate("ISREF(A1)") == .bool(true))
        #expect(try evaluate("ISREF(\"A1\")") == .bool(false))
    }

    // MARK: - OFFSET

    /// Three arguments name a single cell, so the result is that cell's value.
    /// This is how every one of the corpus's 9,798 calls is written.
    @Test func offsetWithThreeArgumentsReadsOneCell() throws {
        var cells = Cells()
        cells.values["B2"] = .text("hit")
        #expect(try evaluate("OFFSET(A1,1,1)", cells: cells) == .text("hit"))
    }

    /// Five arguments name a block, and the values come back as an array so that
    /// `SUM(OFFSET(...))` works without references ever becoming values.
    @Test func offsetWithHeightAndWidthReturnsTheBlocksValues() throws {
        var cells = Cells()
        cells.values["A1"] = .number(1)
        cells.values["A2"] = .number(2)
        cells.values["A3"] = .number(3)
        guard case .array(let matrix) = try evaluate("OFFSET(A1,0,0,3,1)", cells: cells) else {
            Issue.record("expected an array"); return
        }
        #expect(matrix.elements == [.number(1), .number(2), .number(3)])
        // Height 3, width 1 — the shape OFFSET was asked for, which the result
        // can now actually state.
        #expect(matrix.rows == 3)
        #expect(matrix.columns == 1)
    }

    /// Displacing off the top of the sheet is `#REF!`, as in Excel.
    @Test func offsetOffTheSheetIsARefError() throws {
        #expect(try evaluate("OFFSET(A1,-5,0)") == .error(.ref))
    }
}
