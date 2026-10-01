import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The reader against names as a *file* produces them, not as a test constructs them.
///
/// **Every other test in this suite builds `NamedRangeTarget` values by hand**, which
/// encodes an assumption about how a defined name parses rather than exercising the parse.
/// That assumption was wrong, and it was wrong in the most expensive possible way: a bare
/// number like `solver_eng = 2` is not a cell reference, so a resolver hands back
/// `.formula(.text("2"))` rather than `.formula(.number(2))`.
///
/// Reading only `.number` therefore found nothing in any real workbook. Every model
/// reported GRG whatever engine it named, and every model reported **no constraints at
/// all**, because `solver_num` was unreadable by the same mechanism — so the runner would
/// have quietly solved an unconstrained version of a real problem.
///
/// These tests use the text form on purpose. A fixture that agrees with the code about
/// something neither has checked is not evidence.
@Suite struct ExcelSolverReaderParseTests {

    /// Names as a resolver yields them: numbers as text, references as references.
    private func fileShaped() -> NamedRangeCollection {
        var collection = NamedRangeCollection()
        let entries: [(String, NamedRangeTarget)] = [
            ("solver_opt", .sheetCell(SheetReference(sheet: "Sheet1", cell: CellRef("B1")))),
            ("solver_typ", .formula(.text("2"))),
            ("solver_adj", .sheetRange(SheetReference(
                sheet: "Sheet1",
                range: CellRange(from: CellRef("A1"), to: CellRef("A3"))))),
            ("solver_num", .formula(.text("2"))),
            ("solver_eng", .formula(.text("2"))),
            ("solver_neg", .formula(.text("2"))),
            ("solver_ver", .formula(.text("2"))),
            ("solver_lhs1", .sheetCell(SheetReference(sheet: "Sheet1", cell: CellRef("C1")))),
            ("solver_rel1", .formula(.text("1"))),
            ("solver_rhs1", .formula(.text("10"))),
            ("solver_lhs2", .sheetCell(SheetReference(sheet: "Sheet1", cell: CellRef("A1")))),
            ("solver_rel2", .formula(.text("4"))),
            ("solver_rhs2", .formula(.text("integer"))),
        ]
        for (name, target) in entries {
            collection.add(NamedRange(name: name, reference: target, scope: .sheet("Sheet1")))
        }
        return collection
    }

    /// The engine is read, where before every file reported GRG.
    @Test func engineIsReadFromTextualForm() throws {
        #expect(try #require(ExcelSolverReader.model(from: fileShaped())).engine == .simplexLP)
    }

    /// **The constraints are read at all**, which is the failure that mattered:
    /// `solver_num` as text meant a count of zero and a model with nothing to satisfy.
    @Test func constraintsAreReadFromTextualForm() throws {
        let model = try #require(ExcelSolverReader.model(from: fileShaped()))
        #expect(model.constraints.count == 2)
        #expect(model.constraints.first?.relation == .lessOrEqual)
        #expect(model.constraints.first?.rhs == .constant(10))
    }

    @Test func senseAndNonNegativityFromTextualForm() throws {
        let model = try #require(ExcelSolverReader.model(from: fileShaped()))
        #expect(model.sense == .minimise)
        #expect(!model.assumesNonNegative)
        #expect(model.formatVersion == 2)
    }

    /// **A numeric bound stays a bound.** Numbers arrive as text, and so do the integrality
    /// labels, so the two must not be confused: `"10"` is a right-hand side and `"integer"`
    /// is a declaration.
    @Test func aNumericBoundIsNotMistakenForALabel() throws {
        let model = try #require(ExcelSolverReader.model(from: fileShaped()))
        #expect(model.constraints.first?.rhs == .constant(10))
        #expect(model.constraints.last?.rhs == .label("integer"))
        #expect(model.constraints.last?.relation == .integer)
    }
}
