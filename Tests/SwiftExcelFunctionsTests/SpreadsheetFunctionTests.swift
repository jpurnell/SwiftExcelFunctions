import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// A spreadsheet, read as a function of some of its cells.
///
/// This is the adapter an optimizer needs and the simulator already had in another form:
/// put values into designated cells, recompute the sheet in dependency order, read
/// designated cells back. Simulation drives it with random draws; optimization drives it
/// with candidate solutions; the loop between them is the same.
@Suite struct SpreadsheetFunctionTests {

    /// `A1` and `A2` are constants; `B1 = A1 * 2`; `B2 = B1 + A2`.
    private struct Sheet: CellValueProvider, PopulatedCellProvider {
        /// Keyed by ``positionKey`` — which is `absolute()`, so `B1` and `$B$1` normalise
        /// to one entry. Storing relative keys and looking up absolute ones silently finds
        /// nothing, and a provider that returns `nil` for every cell yields an empty
        /// evaluation order rather than an error.
        var stored: [CellRef: CellValue] = [
            CellRef("A1").positionKey: .number(0),
            CellRef("A2").positionKey: .number(0),
            CellRef("B1").positionKey:
                .formula(.multiply(.cellRef(CellRef("A1")), .number(2)), cached: nil),
            CellRef("B2").positionKey:
                .formula(.add(.cellRef(CellRef("B1")), .cellRef(CellRef("A2"))), cached: nil),
        ]
        func value(at ref: CellRef) -> CellValue? { stored[ref.positionKey] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { value(at: ref) }
        func values(in range: CellRange) -> [CellValue] { range.cells.map { value(at: $0) ?? .blank } }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
        func lastPopulatedCell() -> CellRef? { CellRef("B2") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
        /// **Relative refs, deliberately.** Storage is keyed by ``positionKey`` so `B1`
        /// and `$B$1` normalise together, but enumeration must hand back the form formulas
        /// use. Returning the absolute keys makes `DependencyGraph` treat `$B$1` and the
        /// `B1` inside a formula as two cells — seven nodes for four cells — and a cycle
        /// through them is then invisible.
        func populatedCells() -> [CellRef] {
            stored.keys.map { CellRef(column: $0.column, row: $0.row) }
        }
    }

    /// Named `makeFunction` rather than `function`: the latter collides with Swift's
    /// `function` macro, and the compiler asks for a leading `#`.
    private func makeFunction(
        inputs: [String] = ["A1", "A2"],
        outputs: [String] = ["B2"]
    ) throws -> SpreadsheetFunction {
        try SpreadsheetFunction(
            inputs: inputs.map { CellRef($0) },
            outputs: outputs.map { CellRef($0) },
            cells: Sheet(),
            names: NamedRangeCollection())
    }


    // MARK: - Reading the sheet as a function

    @Test func evaluatesThroughTheDependencyChain() throws {
        let f = try makeFunction()
        // B1 = 3*2 = 6, B2 = 6 + 4 = 10
        #expect(try f.callAsFunction([3, 4]).isElementwiseClose(to: [10], within: 1e-12))
    }

    /// **It is a function**: the same input gives the same output, and an earlier call
    /// leaves nothing behind. The loop writes into a fresh overlay each time rather than
    /// mutating the sheet, which is what makes it safe to hand to an optimizer that will
    /// call it thousands of times in any order.
    @Test func repeatedCallsDoNotAccumulateState() throws {
        let f = try makeFunction()
        #expect(try f.callAsFunction([1, 1]).isElementwiseClose(to: [3], within: 1e-12))
        #expect(try f.callAsFunction([5, 0]).isElementwiseClose(to: [10], within: 1e-12))
        #expect(try f.callAsFunction([1, 1]).isElementwiseClose(to: [3], within: 1e-12))
    }

    @Test func severalOutputs() throws {
        let f = try makeFunction(outputs: ["B1", "B2"])
        #expect(try f.callAsFunction([3, 4]).isElementwiseClose(to: [6, 10], within: 1e-12))
    }

    // MARK: - Refusals

    /// **A variable cell must be a constant.** Excel's Solver says the same: a decision
    /// variable that holds a formula would have its value overwritten and the formula
    /// silently ignored, which is a wrong answer rather than an error.
    @Test func aFormulaCellCannotBeAnInput() throws {
        if let error = #expect(throws: (any Error).self, performing: { try makeFunction(inputs: ["B1"]) }) {
            #expect((error as? SpreadsheetFunctionError) == SpreadsheetFunctionError.inputIsNotAConstant(CellRef("B1")))
        }
    }

    @Test func wrongArgumentCountIsRefused() throws {
        let f = try makeFunction()
        if let error = #expect(throws: (any Error).self, performing: { try f.callAsFunction([1.0]) }) {
            #expect((error as? SpreadsheetFunctionError) == SpreadsheetFunctionError.wrongInputCount(expected: 2, got: 1))
        }
    }

    /// An output that evaluates to an error is not silently zero. Averaging a `#DIV/0!` as
    /// zero is the plausible-wrong-number this project exists to avoid.
    @Test func anErrorOutputIsReported() throws {
        var sheet = Sheet()
        sheet.stored[CellRef("B2").positionKey] = .formula(.divide(.cellRef(CellRef("B1")), .number(0)), cached: nil)
        let f = try SpreadsheetFunction(
            inputs: [CellRef("A1")], outputs: [CellRef("B2")],
            cells: sheet, names: NamedRangeCollection())
        if let error = #expect(throws: (any Error).self, performing: { try f.callAsFunction([1.0]) }) {
            #expect((error as? SpreadsheetFunctionError) == SpreadsheetFunctionError.outputNotNumeric(CellRef("B2"),
                                                                     CellValue.error(.div0)))
        }
    }

    /// A circular sheet has no evaluation order, and that is refused at construction —
    /// before an optimizer has spent a thousand calls discovering it.
    @Test func aCycleIsRefusedAtConstruction() throws {
        var sheet = Sheet()
        sheet.stored[CellRef("B1").positionKey] = .formula(.cellRef(CellRef("B2")), cached: nil)
        #expect(throws: (any Error).self) { try SpreadsheetFunction(
            inputs: [CellRef("A1")], outputs: [CellRef("B2")],
            cells: sheet, names: NamedRangeCollection()) }
    }
}
