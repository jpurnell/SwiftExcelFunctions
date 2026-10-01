import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore
import SwiftXLSX

/// `ROWS` and `COLUMNS` count the reference, not the values behind it.
///
/// `ROWS(A:A)` is 1,048,576 in Excel on every sheet, and this package answered the height of
/// the *used range* — 10 on a sheet with ten rows of data, 0 on an empty one. Measured
/// against Excel in round eight of the conformance workbook, where it showed up as a
/// disagreement that had been dismissed as an artifact of evaluating with no cells. It was
/// not: the same wrong answer appears on a fully populated sheet.
///
/// The cause is a decision that is right everywhere else. `CellRange.clipped(to:)` pulls a
/// whole-column reference back to the used range, because reading `$B:$B` otherwise means
/// materialising a million values. Counting positions is the one job that must not go
/// through that clipping.
@Suite struct ReferenceShapeTests {

    private struct Cells: CellValueProvider {
        let values: [String: CellValue]
        func value(at ref: CellRef) -> CellValue? { values[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { values[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("C10") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("C10") }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { values[$0.reference] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
    }

    private struct Names: NameResolver {
        let targets: [String: NamedRangeTarget]
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { targets[name] }
    }

    private static let populated = Cells(values: [
        "A1": .number(1), "A2": .number(2), "C10": .number(3)
    ])

    private func number(_ formula: String,
                        names: NameResolver = Names(targets: [:])) throws -> Double {
        let value = try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                                  cells: Self.populated, names: names)
        guard case .number(let d) = value else {
            Issue.record("\(formula) gave \(value), expected a number")
            return .nan
        }
        return d
    }

    /// The grid's dimensions, which have been the same since 2007.
    private static let sheetRows = 1_048_576.0
    private static let sheetColumns = 16_384.0

    /// **The defect.** A whole column is a whole column however little is in it.
    @Test func aWholeColumnCountsTheWholeGrid() throws {
        #expect(try number("ROWS(A:A)").isEqual(to: Self.sheetRows))
        #expect(try number("COLUMNS(A:A)").isEqual(to: 1))
        #expect(try number("ROWS(A:C)").isEqual(to: Self.sheetRows))
        #expect(try number("COLUMNS(A:C)").isEqual(to: 3))
    }

    /// The written-out form is the same reference and must give the same answer.
    ///
    /// This is what showed the clipping was the cause rather than the shorthand: both
    /// spellings answered 10.
    @Test func theWrittenOutFormAgrees() throws {
        #expect(try number("ROWS($A$1:$A$1048576)").isEqual(to: Self.sheetRows))
        #expect(try number("COLUMNS($A$1:$A$1048576)").isEqual(to: 1))
    }

    /// A whole row already worked, and must keep working.
    ///
    /// `CellRange.clipped(to:)` deliberately keeps a whole row at full width, for exactly the
    /// reason this type generalises. These are the controls for that decision.
    @Test func aWholeRowStillCountsTheWholeGrid() throws {
        #expect(try number("COLUMNS($A$1:$XFD$1)").isEqual(to: Self.sheetColumns))
        #expect(try number("ROWS($A$1:$XFD$1)").isEqual(to: 1))
    }

    /// The `1:1` shorthand, which could not be parsed until SwiftXLSX 0.30.0.
    ///
    /// The whole-row branch existed in that parser and was unreachable — it sat below the
    /// plain `.number` case, and `1:1` lexes as a number. So this question could not even be
    /// *written into* the conformance workbook to ask Excel, and the row was dismissed as a
    /// harness artifact for seven rounds.
    @Test func theWholeRowShorthandCounts() throws {
        #expect(try number("COLUMNS(1:1)").isEqual(to: Self.sheetColumns))
        #expect(try number("ROWS(1:1)").isEqual(to: 1))
        #expect(try number("ROWS(2:5)").isEqual(to: 4))
        #expect(try number("COLUMNS(2:5)").isEqual(to: Self.sheetColumns))
    }

    /// An ordinary bounded range is unaffected — the common case, and the regression risk.
    @Test func boundedRangesAreUnchanged() throws {
        #expect(try number("ROWS(A1:A10)").isEqual(to: 10))
        #expect(try number("COLUMNS(A1:C10)").isEqual(to: 3))
        #expect(try number("ROWS(A1:C10)").isEqual(to: 10))
        #expect(try number("ROWS(A1)").isEqual(to: 1))
        #expect(try number("COLUMNS(A1)").isEqual(to: 1))
    }

    /// A defined name pointing at a whole column counts like one.
    ///
    /// This is how a real model says "this column", so it is most of the value rather than an
    /// extra — the defined-name corpus found 161,901 names, and whole-column targets are
    /// ordinary among them.
    @Test func aNameThatPointsAtAWholeColumnCountsLikeOne() throws {
        // Built from explicit endpoints rather than `CellRange("A:A")`: that initialiser
        // splits on the colon and parses "A" as a cell reference, so the shorthand does not
        // survive it. A separate gap, and not one this type can paper over — noted here
        // because the obvious spelling of this test silently builds a one-row range.
        let wholeColumn = CellRange(from: CellRef("A1"), to: CellRef("A1048576"))
        let names = Names(targets: [
            "Amounts": .range(wholeColumn),
            "Window": .range(CellRange("A1:A10"))
        ])
        #expect(try number("ROWS(Amounts)", names: names).isEqual(to: Self.sheetRows))
        #expect(try number("ROWS(Window)", names: names).isEqual(to: 10))
    }

    /// An array's shape *is* its values, and must still come from them.
    ///
    /// This was spelled through `SEQUENCE(2,3)` when it was written, because the
    /// `{1,2,3;4,5,6}` literal did not parse — the gap that discovery led to, now closed in
    /// SwiftXLSX 0.31.0. Both spellings are kept: they exercise different paths to an array,
    /// and the literal is the one a person writes.
    @Test func arraysAreStillCountedFromTheirValues() throws {
        #expect(try number("ROWS({1,2,3;4,5,6})").isEqual(to: 2))
        #expect(try number("COLUMNS({1,2,3;4,5,6})").isEqual(to: 3))
        #expect(try number("ROWS(SEQUENCE(2,3))").isEqual(to: 2))
        #expect(try number("COLUMNS(SEQUENCE(2,3))").isEqual(to: 3))
    }

    /// A computed reference has no shape until it is computed, and falls through.
    @Test func computedReferencesFallThrough() throws {
        #expect(try number("ROWS(OFFSET(A1,0,0,4,2))").isEqual(to: 4))
        #expect(try number("COLUMNS(OFFSET(A1,0,0,4,2))").isEqual(to: 2))
    }
}
