import Foundation
import SwiftExcelCore
import XCTest
@testable import SwiftExcelFunctions

/// `*` and `?` in a criterion, and the tilde that turns them off.
///
/// Also found by the workbook checker: `COUNTIFS(volunteers, "*")` cached 38 and answered 0,
/// because the criterion was compared as the literal text "*" and no cell holds one.
final class WildcardCriteriaTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    private func row(_ values: [CellValue]) -> CellValue { .array(CellMatrix(row: values)) }

    private func count(_ range: CellValue, _ criterion: String) throws -> Double {
        guard let function = registry.function(named: "COUNTIF") else {
            XCTFail("COUNTIF is not registered"); return .nan
        }
        guard case .number(let value) = try function.evaluate([range, .text(criterion)]) else {
            XCTFail("COUNTIF did not answer with a number"); return .nan
        }
        return value
    }

    /// Names, a number, a blank — the shape of a column somebody has been filling in.
    private lazy var column = row([.text("Alice"), .text("Bob"), .text("alison"),
                                   .number(42), .blank])

    // MARK: - The two wildcards

    /// `"*"` counts the cells holding **text**, which is what makes it "how many are
    /// filled in".
    ///
    /// The number and the blank are passed over. A pattern match that stringified the
    /// number would count it, and the answer would be one too many in every real column.
    func testAnAsteriskCountsTheTextCells() throws {
        XCTAssertEqual(try count(column, "*"), 3)
    }

    /// A pattern anchored at one end.
    func testAPrefixAndASuffix() throws {
        XCTAssertEqual(try count(column, "A*"), 2)        // Alice, alison — case-insensitive
        XCTAssertEqual(try count(column, "*e"), 1)        // Alice
        XCTAssertEqual(try count(column, "*li*"), 2)      // Alice, alison
    }

    /// `?` is exactly one character, which is what distinguishes it from `*`.
    func testAQuestionMarkIsOneCharacter() throws {
        XCTAssertEqual(try count(column, "Bo?"), 1)
        XCTAssertEqual(try count(column, "Bo??"), 0)
        XCTAssertEqual(try count(column, "?????"), 1)     // Alice
    }

    /// The whole of the text must match, not some of it.
    ///
    /// `COUNTIF(range, "lic")` is 0 even though "Alice" contains it. That is the difference
    /// between a criterion and `SEARCH`, and getting it wrong inflates every count.
    func testTheMatchIsAnchoredAtBothEnds() throws {
        XCTAssertEqual(try count(column, "lic"), 0)
        XCTAssertEqual(try count(column, "Alice"), 1)
    }

    // MARK: - Turning them off

    /// A tilde makes the next character mean itself.
    func testATildeEscapesTheWildcard() throws {
        let stars = row([.text("*"), .text("a*b"), .text("ab"), .text("?")])
        XCTAssertEqual(try count(stars, "~*"), 1)       // the cell holding one asterisk
        XCTAssertEqual(try count(stars, "a~*b"), 1)     // a, asterisk, b
        XCTAssertEqual(try count(stars, "~?"), 1)
        // Without the tilde, the same two patterns are wildcards again.
        XCTAssertEqual(try count(stars, "*"), 4)
        XCTAssertEqual(try count(stars, "a*b"), 2)      // "a*b" and "ab"
    }

    // MARK: - Where they do not apply

    /// Only equality reads wildcards. `">a*"` compares against three characters.
    func testAnOrderingCriterionTakesThePatternLiterally() throws {
        let values = row([.text("a*"), .text("b"), .text("z")])
        // Ordered after the literal text "a*": "b" and "z".
        XCTAssertEqual(try count(values, ">a*"), 2)
    }

    /// `<>` is the negation, and it negates the *match*.
    func testTheNegatedFormNegatesTheMatch() throws {
        XCTAssertEqual(try count(column, "<>A*"), 3)    // Bob, 42, and the blank
    }

    /// A criterion with no wildcard in it behaves exactly as before.
    func testAPlainCriterionIsUnaffected() throws {
        XCTAssertEqual(try count(column, "Bob"), 1)
        XCTAssertEqual(try count(column, "bob"), 1)     // still case-insensitive
        XCTAssertEqual(try count(column, "42"), 1)
        XCTAssertEqual(try count(column, ">40"), 1)
    }

    // MARK: - The other functions that take criteria

    /// The criteria machinery is shared, so the wildcard reaches all of them.
    func testTheWholeCriteriaFamilySeesThem() throws {
        let names = row([.text("Alice"), .text("Bob"), .text("alison")])
        let amounts = row([.number(10), .number(20), .number(30)])

        for (name, arguments, expected) in [
            ("SUMIF", [names, .text("A*"), amounts], 40.0),
            ("SUMIFS", [amounts, names, .text("A*")], 40.0),
            ("AVERAGEIF", [names, .text("A*"), amounts], 20.0),
            ("AVERAGEIFS", [amounts, names, .text("A*")], 20.0),
            ("COUNTIFS", [names, .text("A*")], 2.0),
            ("MAXIFS", [amounts, names, .text("A*")], 30.0),
            ("MINIFS", [amounts, names, .text("A*")], 10.0),
        ] as [(String, [CellValue], Double)] {
            guard let function = registry.function(named: name) else {
                XCTFail("\(name) is not registered"); continue
            }
            guard case .number(let value) = try function.evaluate(arguments) else {
                XCTFail("\(name) did not answer with a number"); continue
            }
            XCTAssertEqual(value, expected, name)
        }
    }

    // MARK: - TEXT, while we are here

    /// `TEXT(0, "####")` is the empty string, which is what the corpus cell needed.
    ///
    /// `#` means "a digit if there is one" and `0` means "a digit, or a zero". The
    /// difference only shows at zero, and at zero it is the difference between `", )"` and
    /// `", 0)"` in a heading somebody reads.
    func testAHashOnlyFormatShowsNothingForZero() throws {
        guard let text = registry.function(named: "TEXT") else {
            return XCTFail("TEXT is not registered")
        }
        XCTAssertEqual(try text.evaluate([.number(0), .text("####")]), .text(""))
        XCTAssertEqual(try text.evaluate([.number(2025), .text("####")]), .text("2025"))
        XCTAssertEqual(try text.evaluate([.number(0), .text("0000")]), .text("0000"))
        XCTAssertEqual(try text.evaluate([.number(0), .text("0")]), .text("0"))
    }
}
