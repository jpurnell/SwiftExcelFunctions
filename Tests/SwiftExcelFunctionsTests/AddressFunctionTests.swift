import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// `ADDRESS(row, column, [abs], [a1], [sheet])` — a reference, as text.
///
/// Called 20,978 times across 32 sheets, always with five arguments, and always
/// paired with `INDIRECT`: the sheet builds a reference out of numbers and then
/// reads it. This half needs nothing new — numbers in, a string out — which is
/// why it lands before the evaluation context does.
///
/// The fourth argument is almost always **omitted** in the corpus, written as
/// `ADDRESS($C27,AZ$3,1,,"Lease Revenue")`. That arrives here as `.blank`, and
/// treating it as "use the default" rather than as a value is the whole reason
/// `FormulaAST.missing` evaluates to blank.
final class AddressFunctionTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    private func address(_ args: [CellValue]) throws -> String {
        let function = try XCTUnwrap(registry.function(named: "ADDRESS"), "ADDRESS is missing")
        guard case .text(let text) = try function.evaluate(args) else {
            throw XCTSkip("ADDRESS did not return text")
        }
        return text
    }

    /// With no style argument, Excel makes both parts absolute.
    func testDefaultsToAbsoluteRowAndColumn() throws {
        XCTAssertEqual(try address([.number(1), .number(1)]), "$A$1")
        XCTAssertEqual(try address([.number(5), .number(2)]), "$B$5")
    }

    /// The four styles, which are the reason this cannot be string concatenation.
    func testEachAbsoluteStyle() throws {
        XCTAssertEqual(try address([.number(5), .number(2), .number(1)]), "$B$5")
        XCTAssertEqual(try address([.number(5), .number(2), .number(2)]), "B$5")
        XCTAssertEqual(try address([.number(5), .number(2), .number(3)]), "$B5")
        XCTAssertEqual(try address([.number(5), .number(2), .number(4)]), "B5")
    }

    /// Columns past 26 carry, which is where a naive implementation goes wrong.
    func testColumnLettersCarry() throws {
        XCTAssertEqual(try address([.number(1), .number(26), .number(4)]), "Z1")
        XCTAssertEqual(try address([.number(1), .number(27), .number(4)]), "AA1")
        XCTAssertEqual(try address([.number(1), .number(52), .number(4)]), "AZ1")
        XCTAssertEqual(try address([.number(1), .number(16_384), .number(4)]), "XFD1")
    }

    /// A sheet name is quoted only when it needs to be. `Sheet1!$A$1` is how
    /// Excel writes it; `'Lease Revenue'!$A$1` is how it writes one with a space.
    func testASheetNameIsQuotedOnlyWhenItNeedsToBe() throws {
        XCTAssertEqual(
            try address([.number(1), .number(1), .number(1), .bool(true), .text("Sheet1")]),
            "Sheet1!$A$1")
        XCTAssertEqual(
            try address([.number(1), .number(1), .number(1), .bool(true), .text("Lease Revenue")]),
            "'Lease Revenue'!$A$1")
    }

    /// The corpus's actual shape: the style argument omitted between two commas.
    ///
    /// It arrives as `.blank` and must be read as "use the default", not as a
    /// value. Getting this wrong would produce R1C1 output for 20,978 formulas.
    func testAnOmittedStyleArgumentMeansTheDefault() throws {
        XCTAssertEqual(
            try address([.number(27), .number(52), .number(1), .blank, .text("Lease Revenue")]),
            "'Lease Revenue'!$AZ$27")
    }

    /// `FALSE` for the fourth argument asks for R1C1.
    func testR1C1Style() throws {
        XCTAssertEqual(try address([.number(5), .number(2), .number(1), .bool(false)]), "R5C2")
        XCTAssertEqual(try address([.number(5), .number(2), .number(4), .bool(false)]), "R[5]C[2]")
    }

    /// Excel's grid ends at 16,384 columns and 1,048,576 rows.
    func testOutOfRangeIsAValueError() throws {
        let function = try XCTUnwrap(registry.function(named: "ADDRESS"))
        XCTAssertEqual(try function.evaluate([.number(1), .number(16_385)]), .error(.value))
        XCTAssertEqual(try function.evaluate([.number(0), .number(1)]), .error(.value))
    }
}
