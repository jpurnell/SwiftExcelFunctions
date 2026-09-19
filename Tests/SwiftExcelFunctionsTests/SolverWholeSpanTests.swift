import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// A Solver model that names a whole column must not try to enumerate it.
///
/// `ExcelSolverReader` turns a model's references into the cells they cover, one `CellRef`
/// each. A whole column is 1,048,576 of them — about 25 MB of references for a model that
/// cannot use them, since Excel's own Solver caps decision variables at 200.
///
/// **This was reachable before `CellRange(_:)` was fixed**, by the other path:
/// `DefinedNameResolver` has always read `Sheet1!$A:$A` as the whole column it is, so a
/// Solver model bound to a whole-column *defined name* already enumerated a million
/// references. Fixing `CellRange(_:)` added a second way in — the literal `A:A` in a
/// multi-area reference string — which is what made it worth looking at.
final class SolverWholeSpanTests: XCTestCase {

    /// The limit is a refusal, not a truncation.
    ///
    /// Half a model is worse than none: a caller handed the first 4,096 cells of a column
    /// has a model that looks complete and optimises the wrong thing.
    func testAWholeColumnNamesNoCells() {
        XCTAssertTrue(ExcelSolverReader.cellsForTesting("Sheet1!$A:$A").isEmpty)
        XCTAssertTrue(ExcelSolverReader.cellsForTesting("A:A").isEmpty)
        XCTAssertTrue(ExcelSolverReader.cellsForTesting("3:3").isEmpty)
    }

    /// An ordinary model range is unaffected — the case that has to keep working.
    func testOrdinaryRangesStillEnumerate() {
        XCTAssertEqual(ExcelSolverReader.cellsForTesting("Sheet1!$B$4:$B$10").count, 7)
        XCTAssertEqual(ExcelSolverReader.cellsForTesting("$C$5").count, 1)
        XCTAssertEqual(ExcelSolverReader.cellsForTesting("Sheet1!$A$1:$A$3,Sheet1!$C$5").count, 4)
    }

    /// One oversized area does not take the areas beside it down with it.
    func testAnOversizedAreaIsDroppedAndTheRestKept() {
        let cells = ExcelSolverReader.cellsForTesting("Sheet1!$A$1:$A$3,Sheet1!$D:$D")
        XCTAssertEqual(cells.count, 3, "the bounded area survives; the column does not")
    }

    /// The boundary, stated rather than left to be discovered.
    func testTheLimitIsWhereItSays() {
        let atLimit = "A1:A\(ExcelSolverReader.maximumModelCells)"
        XCTAssertEqual(ExcelSolverReader.cellsForTesting(atLimit).count,
                       ExcelSolverReader.maximumModelCells)
        let pastLimit = "A1:A\(ExcelSolverReader.maximumModelCells + 1)"
        XCTAssertTrue(ExcelSolverReader.cellsForTesting(pastLimit).isEmpty)
    }
}
