import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// The twelve `D` functions, over Microsoft's own example table.
///
/// ```
///        A        B       C       D       E
/// 1   Tree     Height   Age    Yield   Profit
/// 2   Apple    18       20     14      105
/// 3   Pear     12       12     10      96
/// 4   Cherry   13       14     9       105
/// 5   Apple    14       15     10      75
/// 6   Pear     9        8      8       76.8
/// 7   Apple    8        9      6       45
/// ```
///
/// The criteria range is the part of these functions worth testing hardest: its *shape*
/// carries the logic, columns are `AND`, rows are `OR`, and a blank cell is not a condition.
final class DatabaseFunctionTests: XCTestCase {

    private struct Cells: CellValueProvider {
        var data: [String: CellValue] = [:]
        func value(at ref: CellRef) -> CellValue? { data[ref.reference] }
        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet sheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { range.cells.compactMap { value(at: $0) } }
        func values(in range: CellRange, inSheet sheet: String) -> [CellValue] { [] }
    }
    private struct Names: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    /// The orchard, plus whatever criteria a test lays out below it.
    private func sheet(criteria: [[CellValue]] = []) -> Cells {
        var data: [String: CellValue] = [:]
        let columns = ["A", "B", "C", "D", "E"]
        let rows: [[CellValue]] = [
            [.text("Tree"), .text("Height"), .text("Age"), .text("Yield"), .text("Profit")],
            [.text("Apple"), .number(18), .number(20), .number(14), .number(105)],
            [.text("Pear"), .number(12), .number(12), .number(10), .number(96)],
            [.text("Cherry"), .number(13), .number(14), .number(9), .number(105)],
            [.text("Apple"), .number(14), .number(15), .number(10), .number(75)],
            [.text("Pear"), .number(9), .number(8), .number(8), .number(76.8)],
            [.text("Apple"), .number(8), .number(9), .number(6), .number(45)],
        ]
        for (r, row) in rows.enumerated() {
            for (c, value) in row.enumerated() { data["\(columns[c])\(r + 1)"] = value }
        }
        // Criteria go at row 10 and below, well clear of the table.
        for (r, row) in criteria.enumerated() {
            for (c, value) in row.enumerated() { data["\(columns[c])\(r + 10)"] = value }
        }
        return Cells(data: data)
    }

    private let database = FormulaAST.cellRange(CellRange(from: "A1", to: "E7"))

    private func criteriaRange(rows: Int, columns: String) -> FormulaAST {
        .cellRange(CellRange(from: "A10", to: "\(columns)\(9 + rows)"))
    }

    private func call(_ name: String, field: CellValue, criteria: FormulaAST,
                      cells: Cells) throws -> CellValue {
        let fieldAST: FormulaAST
        switch field {
        case .text(let t): fieldAST = .text(t)
        case .number(let n): fieldAST = .number(n)
        default: fieldAST = .number(0)
        }
        return try FormulaEvaluator.evaluate(
            .function(name, [database, fieldAST, criteria]),
            cells: cells, names: Names(), functions: .builtin)
    }

    // MARK: - One condition

    /// Microsoft's own: the height of the one apple tree between 10 and 16 feet.
    func testDgetFindsTheSingleMatch() throws {
        let cells = sheet(criteria: [
            [.text("Tree"), .text("Height"), .text("Height")],
            [.text("Apple"), .text(">10"), .text("<16")],
        ])
        XCTAssertEqual(
            try call("DGET", field: .text("Yield"),
                     criteria: criteriaRange(rows: 2, columns: "C"), cells: cells),
            .number(10))
    }

    /// `DGET` refuses ambiguity rather than answering with the first of several.
    func testDgetRefusesMoreThanOneMatch() throws {
        let cells = sheet(criteria: [[.text("Tree")], [.text("Apple")]])
        XCTAssertEqual(
            try call("DGET", field: .text("Yield"),
                     criteria: criteriaRange(rows: 2, columns: "A"), cells: cells),
            .error(.num))
    }

    func testDgetWithNoMatch() throws {
        let cells = sheet(criteria: [[.text("Tree")], [.text("Plum")]])
        XCTAssertEqual(
            try call("DGET", field: .text("Yield"),
                     criteria: criteriaRange(rows: 2, columns: "A"), cells: cells),
            .error(.value))
    }

    // MARK: - The aggregates

    func testTheAggregatesOverTheAppleTrees() throws {
        let cells = sheet(criteria: [[.text("Tree")], [.text("Apple")]])
        let criteria = criteriaRange(rows: 2, columns: "A")

        // Apples yield 14, 10 and 6; their profits are 105, 75 and 45.
        XCTAssertEqual(try call("DSUM", field: .text("Profit"), criteria: criteria, cells: cells),
                       .number(225))
        XCTAssertEqual(try call("DCOUNT", field: .text("Yield"), criteria: criteria, cells: cells),
                       .number(3))
        XCTAssertEqual(try call("DMAX", field: .text("Profit"), criteria: criteria, cells: cells),
                       .number(105))
        XCTAssertEqual(try call("DMIN", field: .text("Profit"), criteria: criteria, cells: cells),
                       .number(45))
        XCTAssertEqual(try call("DAVERAGE", field: .text("Yield"), criteria: criteria, cells: cells),
                       .number(10))
        XCTAssertEqual(try call("DPRODUCT", field: .text("Yield"), criteria: criteria, cells: cells),
                       .number(840))
    }

    /// `DSTDEV` and `DVAR` are the *sample* forms; the `P` pair are the population ones.
    func testTheSpreadStatistics() throws {
        let cells = sheet(criteria: [[.text("Tree")], [.text("Apple")]])
        let criteria = criteriaRange(rows: 2, columns: "A")

        // Yields 14, 10, 6: mean 10, deviations 4, 0, -4.
        XCTAssertEqual(try call("DVAR", field: .text("Yield"), criteria: criteria, cells: cells),
                       .number(16), "32 over n-1 = 2")
        XCTAssertEqual(try call("DVARP", field: .text("Yield"), criteria: criteria, cells: cells),
                       .number(32.0 / 3.0), "32 over n = 3")
        guard case .number(let sample) = try call(
            "DSTDEV", field: .text("Yield"), criteria: criteria, cells: cells) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(sample, 4, accuracy: 1e-12)
    }

    /// `DCOUNTA` counts cells that are not blank, where `DCOUNT` counts numbers.
    func testDcountAndDcountAAreDifferentQuestions() throws {
        var cells = sheet(criteria: [[.text("Tree")], [.text("Apple")]])
        // One apple's yield replaced by text: still present, no longer a number.
        cells.data["D5"] = .text("n/a")
        let criteria = criteriaRange(rows: 2, columns: "A")

        XCTAssertEqual(try call("DCOUNT", field: .text("Yield"), criteria: criteria, cells: cells),
                       .number(2))
        XCTAssertEqual(try call("DCOUNTA", field: .text("Yield"), criteria: criteria, cells: cells),
                       .number(3))
    }

    // MARK: - The criteria range's shape

    /// Two conditions in one row are `AND`.
    func testColumnsAreAnd() throws {
        let cells = sheet(criteria: [
            [.text("Tree"), .text("Height")],
            [.text("Apple"), .text(">10")],
        ])
        // Apples over 10 feet: 18 and 14, yielding 14 and 10.
        XCTAssertEqual(
            try call("DSUM", field: .text("Yield"),
                     criteria: criteriaRange(rows: 2, columns: "B"), cells: cells),
            .number(24))
    }

    /// Two criteria rows are `OR`.
    func testRowsAreOr() throws {
        let cells = sheet(criteria: [
            [.text("Tree")],
            [.text("Apple")],
            [.text("Pear")],
        ])
        // Every tree but the cherry: yields 14, 10, 10, 8, 6.
        XCTAssertEqual(
            try call("DSUM", field: .text("Yield"),
                     criteria: criteriaRange(rows: 3, columns: "A"), cells: cells),
            .number(48))
    }

    /// **A blank cell states no condition**, so an empty criteria row matches everything.
    ///
    /// Correct, and the behaviour that catches people out: a criteria range with a spare
    /// blank row under it selects the entire table.
    func testABlankCriteriaRowMatchesEverything() throws {
        let cells = sheet(criteria: [
            [.text("Tree")],
            [.text("Apple")],
            [.blank],
        ])
        // Every yield: 14 + 10 + 9 + 10 + 8 + 6.
        XCTAssertEqual(
            try call("DSUM", field: .text("Yield"),
                     criteria: criteriaRange(rows: 3, columns: "A"), cells: cells),
            .number(57))
    }

    /// A criteria column the database does not have selects nothing.
    func testAnUnknownCriteriaColumnMatchesNothing() throws {
        let cells = sheet(criteria: [[.text("Colour")], [.text("Red")]])
        XCTAssertEqual(
            try call("DSUM", field: .text("Yield"),
                     criteria: criteriaRange(rows: 2, columns: "A"), cells: cells),
            .number(0))
    }

    // MARK: - The field argument

    /// A field may be named or numbered, and both must mean the same column.
    func testTheFieldMayBeAPosition() throws {
        let cells = sheet(criteria: [[.text("Tree")], [.text("Apple")]])
        let criteria = criteriaRange(rows: 2, columns: "A")
        XCTAssertEqual(try call("DSUM", field: .number(4), criteria: criteria, cells: cells),
                       try call("DSUM", field: .text("Yield"), criteria: criteria, cells: cells))
    }

    func testAFieldNameIsMatchedWithoutCase() throws {
        let cells = sheet(criteria: [[.text("Tree")], [.text("Apple")]])
        let criteria = criteriaRange(rows: 2, columns: "A")
        XCTAssertEqual(try call("DSUM", field: .text("yield"), criteria: criteria, cells: cells),
                       .number(30))
    }

    func testAnUnknownFieldIsRefused() throws {
        let cells = sheet(criteria: [[.text("Tree")], [.text("Apple")]])
        XCTAssertEqual(
            try call("DSUM", field: .text("Colour"),
                     criteria: criteriaRange(rows: 2, columns: "A"), cells: cells),
            .error(.value))
        XCTAssertEqual(
            try call("DSUM", field: .number(99),
                     criteria: criteriaRange(rows: 2, columns: "A"), cells: cells),
            .error(.value))
    }

    /// The criteria vocabulary is the one `SUMIF` uses, so comparisons work the same way.
    func testTheCriteriaVocabularyIsShared() throws {
        let cells = sheet(criteria: [[.text("Profit")], [.text(">=100")]])
        // Two records at 105.
        XCTAssertEqual(
            try call("DCOUNT", field: .text("Profit"),
                     criteria: criteriaRange(rows: 2, columns: "A"), cells: cells),
            .number(2))
    }
}
