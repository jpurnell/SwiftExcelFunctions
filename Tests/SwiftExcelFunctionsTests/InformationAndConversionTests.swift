import Foundation
import SwiftExcelCore
import SwiftXLSX
import XCTest
@testable import SwiftExcelFunctions

/// The `information` and `text` categories of the unreviewed bucket.
///
/// Neither is arithmetic: these are this package's *own* semantics, so the expected values
/// come from Microsoft's function reference rather than from a third implementation. Where
/// the reference gives an example it is quoted and marked; where it only states a rule, the
/// rule is written in the test's own words beside the assertion.
final class InformationAndConversionTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let function = registry.function(named: name) else {
            XCTFail("\(name) is not registered"); return .error(.name)
        }
        return try function.evaluate(args)
    }

    private func text(_ name: String, _ args: CellValue...) throws -> String {
        guard let function = registry.function(named: name) else {
            XCTFail("\(name) is not registered"); return ""
        }
        guard case .text(let value) = try function.evaluate(args) else {
            XCTFail("\(name) did not answer with text"); return ""
        }
        return value
    }

    // MARK: - Parity

    /// Truncated toward zero, not rounded.
    ///
    /// `ISEVEN(2.9)` is TRUE because the 2 is what counts. Rounding would make it FALSE,
    /// and the difference shows up only on the rows where it matters.
    func testParityTruncates() throws {
        XCTAssertEqual(try call("ISEVEN", .number(2)), .bool(true))
        XCTAssertEqual(try call("ISEVEN", .number(2.9)), .bool(true))
        XCTAssertEqual(try call("ISEVEN", .number(3)), .bool(false))
        XCTAssertEqual(try call("ISODD", .number(3.9)), .bool(true))
        XCTAssertEqual(try call("ISODD", .number(-3)), .bool(true))
        // Zero is even, and an empty cell is zero.
        XCTAssertEqual(try call("ISEVEN", .number(0)), .bool(true))
        XCTAssertEqual(try call("ISEVEN", .blank), .bool(true))
    }

    /// Text is `#VALUE!` even when it reads as a number.
    ///
    /// These ask about a *number*, and Excel does not coerce for them as it does for
    /// arithmetic — `ISEVEN("2")` is an error, not TRUE.
    func testParityDoesNotCoerceText() throws {
        XCTAssertEqual(try call("ISEVEN", .text("2")), .error(.value))
        XCTAssertEqual(try call("ISODD", .text("x")), .error(.value))
        XCTAssertEqual(try call("ISEVEN", .error(.div0)), .error(.div0))
    }

    // MARK: - Which case is it

    func testTheKindPredicates() throws {
        XCTAssertEqual(try call("ISLOGICAL", .bool(false)), .bool(true))
        XCTAssertEqual(try call("ISLOGICAL", .number(1)), .bool(false))
        XCTAssertEqual(try call("ISLOGICAL", .text("TRUE")), .bool(false))

        XCTAssertEqual(try call("ISNONTEXT", .number(1)), .bool(true))
        XCTAssertEqual(try call("ISNONTEXT", .text("x")), .bool(false))
        // An empty cell is non-text, which is the case people expect to go the other way.
        XCTAssertEqual(try call("ISNONTEXT", .blank), .bool(true))
    }

    // MARK: - As a number

    /// `N("7")` is **0**, not 7 — the documented answer, and what separates `N` from `VALUE`.
    func testNUsesExcelsCoercionTable() throws {
        XCTAssertEqual(try call("N", .number(7)), .number(7))
        XCTAssertEqual(try call("N", .bool(true)), .number(1))
        XCTAssertEqual(try call("N", .bool(false)), .number(0))
        XCTAssertEqual(try call("N", .text("7")), .number(0))
        XCTAssertEqual(try call("N", .text("hello")), .number(0))
        XCTAssertEqual(try call("N", .blank), .number(0))
        XCTAssertEqual(try call("N", .error(.na)), .error(.na))
    }

    /// The numbering has gaps, and they are Excel's.
    func testTypeNumbersTheKinds() throws {
        XCTAssertEqual(try call("TYPE", .number(1)), .number(1))
        XCTAssertEqual(try call("TYPE", .blank), .number(1))
        XCTAssertEqual(try call("TYPE", .text("x")), .number(2))
        XCTAssertEqual(try call("TYPE", .bool(true)), .number(4))
        XCTAssertEqual(try call("TYPE", .error(.value)), .number(16))
        XCTAssertEqual(try call("TYPE", .array(CellMatrix(row: [.number(1)]))), .number(64))
    }

    /// Every error has its number, and anything that is not an error is `#N/A`.
    func testErrorTypeNumbersTheErrors() throws {
        let expected: [(ExcelError, Double)] = [
            (.null, 1), (.div0, 2), (.value, 3), (.ref, 4), (.name, 5), (.num, 6), (.na, 7),
        ]
        for (error, number) in expected {
            XCTAssertEqual(try call("ERROR.TYPE", .error(error)), .number(number),
                           error.rawValue)
        }
        // A perfectly good number is #N/A here, which is why `IFERROR` wraps it.
        XCTAssertEqual(try call("ERROR.TYPE", .number(42)), .error(.na))
        XCTAssertEqual(try call("ERROR.TYPE", .text("#REF!")), .error(.na))
    }

    // MARK: - ISFORMULA

    /// The only one that asks about a *cell* rather than a value.
    ///
    /// A formula returning 7 and a typed 7 are the same value and different cells, so this
    /// has to read the sheet. An argument that is not a reference is `#REF!` — the question
    /// does not apply, and Excel says so rather than guessing.
    func testIsFormulaReadsTheCellRatherThanItsValue() throws {
        let provider = Cells(values: [
            "A1": .number(7),
            "A2": .formula(.number(7), cached: .number(7)),
        ])
        func ask(_ formula: String) throws -> CellValue {
            try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                          cells: provider, names: NoNames())
        }
        XCTAssertEqual(try ask("ISFORMULA(A1)"), .bool(false))
        XCTAssertEqual(try ask("ISFORMULA(A2)"), .bool(true))
        XCTAssertEqual(try ask("ISFORMULA(\"A2\")"), .error(.ref))
    }

    private struct Cells: CellValueProvider {
        let values: [String: CellValue]
        func value(at ref: CellRef) -> CellValue? { values[ref.reference] }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { values[ref.reference] }
        func lastPopulatedCell() -> CellRef? { CellRef("A2") }
        func lastPopulatedCell(inSheet: String) -> CellRef? { CellRef("A2") }
        func values(in range: CellRange) -> [CellValue] {
            range.cells.map { values[$0.reference] ?? .blank }
        }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { values(in: range) }
    }

    private struct NoNames: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }

    // MARK: - DOLLAR

    /// Microsoft's published examples, including the negative-places one.
    func testDollarMatchesThePublishedExamples() throws {
        XCTAssertEqual(try text("DOLLAR", .number(1234.567)), "$1,234.57")
        XCTAssertEqual(try text("DOLLAR", .number(1234.567), .number(-2)), "$1,200")
        XCTAssertEqual(try text("DOLLAR", .number(-1234.567), .number(-2)), "($1,200)")
        XCTAssertEqual(try text("DOLLAR", .number(-0.123), .number(4)), "($0.1230)")
        XCTAssertEqual(try text("DOLLAR", .number(99.888)), "$99.89")
    }

    // MARK: - VALUETOTEXT and ARRAYTOTEXT

    /// Concise loses the difference between 7 and "7"; strict keeps it.
    func testTheTwoModes() throws {
        XCTAssertEqual(try text("VALUETOTEXT", .text("hello")), "hello")
        XCTAssertEqual(try text("VALUETOTEXT", .text("hello"), .number(1)), "\"hello\"")
        XCTAssertEqual(try text("VALUETOTEXT", .number(7)), "7")
        XCTAssertEqual(try text("VALUETOTEXT", .number(7), .number(1)), "7")
        XCTAssertEqual(try text("VALUETOTEXT", .bool(true)), "TRUE")
        XCTAssertEqual(try text("VALUETOTEXT", .error(.div0)), "#DIV/0!")
        // A format that is neither 0 nor 1 is refused rather than rounded into one.
        XCTAssertEqual(try call("VALUETOTEXT", .text("x"), .number(2)), .error(.value))
    }

    /// Strict mode writes the array literal Excel would read back.
    func testArrayToTextKeepsTheShapeInStrictMode() throws {
        let matrix = CellValue.array(CellMatrix(
            elements: [.number(1), .text("a"), .number(3), .number(4)],
            rows: 2, columns: 2) ?? CellMatrix(single: .blank))
        XCTAssertEqual(try text("ARRAYTOTEXT", matrix), "1, a, 3, 4")
        XCTAssertEqual(try text("ARRAYTOTEXT", matrix, .number(1)), "{1,\"a\";3,4}")
    }

    // MARK: - TEXTSPLIT

    /// Columns by the first delimiter, rows by the second — and rows are the outer cut.
    func testTextSplitMakesARectangle() throws {
        guard case .array(let matrix) = try call(
            "TEXTSPLIT", .text("a,b;c,d"), .text(","), .text(";")) else {
            return XCTFail("expected a rectangle")
        }
        XCTAssertEqual(matrix.rows, 2)
        XCTAssertEqual(matrix.columns, 2)
        XCTAssertEqual(matrix.elements, [.text("a"), .text("b"), .text("c"), .text("d")])
    }

    /// One delimiter gives one row.
    func testTextSplitWithOneDelimiter() throws {
        guard case .array(let matrix) = try call("TEXTSPLIT", .text("a,b,c"), .text(",")) else {
            return XCTFail("expected a row")
        }
        XCTAssertEqual(matrix.rows, 1)
        XCTAssertEqual(matrix.elements, [.text("a"), .text("b"), .text("c")])
    }

    /// A ragged split is padded, and the padding is `#N/A` unless told otherwise.
    func testARaggedSplitIsPadded() throws {
        guard case .array(let matrix) = try call(
            "TEXTSPLIT", .text("a,b;c"), .text(","), .text(";")) else {
            return XCTFail("expected a rectangle")
        }
        XCTAssertEqual(matrix.elements, [.text("a"), .text("b"), .text("c"), .error(.na)])

        guard case .array(let padded) = try call(
            "TEXTSPLIT", .text("a,b;c"), .text(","), .text(";"),
            .bool(false), .number(0), .text("-")) else {
            return XCTFail("expected a rectangle")
        }
        XCTAssertEqual(padded.elements.last, .text("-"))
    }

    /// Empty pieces are kept unless `ignore_empty` says to drop them.
    func testEmptyPiecesAreKeptByDefault() throws {
        guard case .array(let kept) = try call("TEXTSPLIT", .text("a,,b"), .text(",")) else {
            return XCTFail("expected a row")
        }
        XCTAssertEqual(kept.elements, [.text("a"), .text(""), .text("b")])

        guard case .array(let dropped) = try call(
            "TEXTSPLIT", .text("a,,b"), .text(","), .blank, .bool(true)) else {
            return XCTFail("expected a row")
        }
        XCTAssertEqual(dropped.elements, [.text("a"), .text("b")])
    }

    // MARK: - The regular-expression trio

    func testRegexTest() throws {
        XCTAssertEqual(try call("REGEXTEST", .text("a1b2"), .text("[0-9]")), .bool(true))
        XCTAssertEqual(try call("REGEXTEST", .text("abc"), .text("[0-9]")), .bool(false))
        // The flag is *case sensitivity*, and 0 — the default — is sensitive.
        XCTAssertEqual(try call("REGEXTEST", .text("ABC"), .text("abc")), .bool(false))
        XCTAssertEqual(try call("REGEXTEST", .text("ABC"), .text("abc"), .number(1)), .bool(true))
        // A pattern that will not compile is #VALUE!, not a guess at what was meant.
        XCTAssertEqual(try call("REGEXTEST", .text("a"), .text("[")), .error(.value))
    }

    func testRegexExtractsTheThreeWays() throws {
        XCTAssertEqual(try call("REGEXEXTRACT", .text("a1b22c"), .text("[0-9]+")), .text("1"))

        guard case .array(let all) = try call(
            "REGEXEXTRACT", .text("a1b22c"), .text("[0-9]+"), .number(1)) else {
            return XCTFail("expected a column of every match")
        }
        XCTAssertEqual(all.elements, [.text("1"), .text("22")])

        guard case .array(let groups) = try call(
            "REGEXEXTRACT", .text("2026-09-15"), .text("([0-9]{4})-([0-9]{2})"), .number(2)) else {
            return XCTFail("expected a row of capture groups")
        }
        XCTAssertEqual(groups.elements, [.text("2026"), .text("09")])

        // Nothing matched is #N/A, which is what lets IFNA do its job.
        XCTAssertEqual(try call("REGEXEXTRACT", .text("abc"), .text("[0-9]")), .error(.na))
    }

    func testRegexReplaceCountsOccurrences() throws {
        XCTAssertEqual(try call("REGEXREPLACE", .text("a1b2"), .text("[0-9]"), .text("#")),
                       .text("a#b#"))
        XCTAssertEqual(
            try call("REGEXREPLACE", .text("a1b2"), .text("[0-9]"), .text("#"), .number(2)),
            .text("a1b#"))
        // A negative occurrence counts from the end.
        XCTAssertEqual(
            try call("REGEXREPLACE", .text("a1b2"), .text("[0-9]"), .text("#"), .number(-1)),
            .text("a1b#"))
        // An occurrence that is not there leaves the text alone.
        XCTAssertEqual(
            try call("REGEXREPLACE", .text("a1"), .text("[0-9]"), .text("#"), .number(5)),
            .text("a1"))
    }

    // MARK: - Registration

    func testTheNamesResolve() {
        for name in ["ISEVEN", "ISODD", "ISLOGICAL", "ISNONTEXT", "N", "TYPE", "ERROR.TYPE",
                     "ISFORMULA", "DOLLAR", "VALUETOTEXT", "ARRAYTOTEXT", "TEXTSPLIT",
                     "REGEXTEST", "REGEXEXTRACT", "REGEXREPLACE"] {
            XCTAssertNotNil(registry.function(named: name), name)
        }
    }
}
