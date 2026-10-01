import Foundation
import SwiftExcelCore
import SwiftXLSX
import Foundation
import Testing
@testable import SwiftExcelFunctions

/// The `information` and `text` categories of the unreviewed bucket.
///
/// Neither is arithmetic: these are this package's *own* semantics, so the expected values
/// come from Microsoft's function reference rather than from a third implementation. Where
/// the reference gives an example it is quoted and marked; where it only states a rule, the
/// rule is written in the test's own words beside the assertion.
@Suite struct InformationAndConversionTests {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let function = registry.function(named: name) else {
            Issue.record("\(name) is not registered"); return .error(.name)
        }
        return try function.evaluate(args)
    }

    private func text(_ name: String, _ args: CellValue...) throws -> String {
        guard let function = registry.function(named: name) else {
            Issue.record("\(name) is not registered"); return ""
        }
        guard case .text(let value) = try function.evaluate(args) else {
            Issue.record("\(name) did not answer with text"); return ""
        }
        return value
    }

    // MARK: - Parity

    /// Truncated toward zero, not rounded.
    ///
    /// `ISEVEN(2.9)` is TRUE because the 2 is what counts. Rounding would make it FALSE,
    /// and the difference shows up only on the rows where it matters.
    @Test func parityTruncates() throws {
        #expect(try call("ISEVEN", .number(2)) == .bool(true))
        #expect(try call("ISEVEN", .number(2.9)) == .bool(true))
        #expect(try call("ISEVEN", .number(3)) == .bool(false))
        #expect(try call("ISODD", .number(3.9)) == .bool(true))
        #expect(try call("ISODD", .number(-3)) == .bool(true))
        // Zero is even, and an empty cell is zero.
        #expect(try call("ISEVEN", .number(0)) == .bool(true))
        #expect(try call("ISEVEN", .blank) == .bool(true))
    }

    /// Text is `#VALUE!` even when it reads as a number.
    ///
    /// These ask about a *number*, and Excel does not coerce for them as it does for
    /// arithmetic — `ISEVEN("2")` is an error, not TRUE.
    @Test func parityDoesNotCoerceText() throws {
        #expect(try call("ISEVEN", .text("2")) == .error(.value))
        #expect(try call("ISODD", .text("x")) == .error(.value))
        #expect(try call("ISEVEN", .error(.div0)) == .error(.div0))
    }

    // MARK: - Which case is it

    @Test func theKindPredicates() throws {
        #expect(try call("ISLOGICAL", .bool(false)) == .bool(true))
        #expect(try call("ISLOGICAL", .number(1)) == .bool(false))
        #expect(try call("ISLOGICAL", .text("TRUE")) == .bool(false))

        #expect(try call("ISNONTEXT", .number(1)) == .bool(true))
        #expect(try call("ISNONTEXT", .text("x")) == .bool(false))
        // An empty cell is non-text, which is the case people expect to go the other way.
        #expect(try call("ISNONTEXT", .blank) == .bool(true))
    }

    // MARK: - As a number

    /// `N("7")` is **0**, not 7 — the documented answer, and what separates `N` from `VALUE`.
    @Test func nUsesExcelsCoercionTable() throws {
        #expect(try call("N", .number(7)) == .number(7))
        #expect(try call("N", .bool(true)) == .number(1))
        #expect(try call("N", .bool(false)) == .number(0))
        #expect(try call("N", .text("7")) == .number(0))
        #expect(try call("N", .text("hello")) == .number(0))
        #expect(try call("N", .blank) == .number(0))
        #expect(try call("N", .error(.na)) == .error(.na))
    }

    /// The numbering has gaps, and they are Excel's.
    @Test func typeNumbersTheKinds() throws {
        #expect(try call("TYPE", .number(1)) == .number(1))
        #expect(try call("TYPE", .blank) == .number(1))
        #expect(try call("TYPE", .text("x")) == .number(2))
        #expect(try call("TYPE", .bool(true)) == .number(4))
        #expect(try call("TYPE", .error(.value)) == .number(16))
        #expect(try call("TYPE", .array(CellMatrix(row: [.number(1)]))) == .number(64))
    }

    /// Every error has its number, and anything that is not an error is `#N/A`.
    @Test func errorTypeNumbersTheErrors() throws {
        let expected: [(ExcelError, Double)] = [
            (.null, 1), (.div0, 2), (.value, 3), (.ref, 4), (.name, 5), (.num, 6), (.na, 7),
        ]
        for (error, number) in expected {
            #expect(try call("ERROR.TYPE", .error(error)) == .number(number), "\(error.rawValue)")
        }
        // A perfectly good number is #N/A here, which is why `IFERROR` wraps it.
        #expect(try call("ERROR.TYPE", .number(42)) == .error(.na))
        #expect(try call("ERROR.TYPE", .text("#REF!")) == .error(.na))
    }

    // MARK: - ISFORMULA

    /// The only one that asks about a *cell* rather than a value.
    ///
    /// A formula returning 7 and a typed 7 are the same value and different cells, so this
    /// has to read the sheet. An argument that is not a reference is `#REF!` — the question
    /// does not apply, and Excel says so rather than guessing.
    @Test func isFormulaReadsTheCellRatherThanItsValue() throws {
        let provider = Cells(values: [
            "A1": .number(7),
            "A2": .formula(.number(7), cached: .number(7)),
        ])
        func ask(_ formula: String) throws -> CellValue {
            try FormulaEvaluator.evaluate(try FormulaParser.parse(formula),
                                          cells: provider, names: NoNames())
        }
        #expect(try ask("ISFORMULA(A1)") == .bool(false))
        #expect(try ask("ISFORMULA(A2)") == .bool(true))
        #expect(try ask("ISFORMULA(\"A2\")") == .error(.ref))
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
    @Test func dollarMatchesThePublishedExamples() throws {
        #expect(try text("DOLLAR", .number(1234.567)) == "$1,234.57")
        #expect(try text("DOLLAR", .number(1234.567), .number(-2)) == "$1,200")
        #expect(try text("DOLLAR", .number(-1234.567), .number(-2)) == "($1,200)")
        #expect(try text("DOLLAR", .number(-0.123), .number(4)) == "($0.1230)")
        #expect(try text("DOLLAR", .number(99.888)) == "$99.89")
    }

    // MARK: - VALUETOTEXT and ARRAYTOTEXT

    /// Concise loses the difference between 7 and "7"; strict keeps it.
    @Test func theTwoModes() throws {
        #expect(try text("VALUETOTEXT", .text("hello")) == "hello")
        #expect(try text("VALUETOTEXT", .text("hello"), .number(1)) == "\"hello\"")
        #expect(try text("VALUETOTEXT", .number(7)) == "7")
        #expect(try text("VALUETOTEXT", .number(7), .number(1)) == "7")
        #expect(try text("VALUETOTEXT", .bool(true)) == "TRUE")
        #expect(try text("VALUETOTEXT", .error(.div0)) == "#DIV/0!")
        // A format that is neither 0 nor 1 is refused rather than rounded into one.
        #expect(try call("VALUETOTEXT", .text("x"), .number(2)) == .error(.value))
    }

    /// Strict mode writes the array literal Excel would read back.
    @Test func arrayToTextKeepsTheShapeInStrictMode() throws {
        let matrix = CellValue.array(CellMatrix(
            elements: [.number(1), .text("a"), .number(3), .number(4)],
            rows: 2, columns: 2) ?? CellMatrix(single: .blank))
        #expect(try text("ARRAYTOTEXT", matrix) == "1, a, 3, 4")
        #expect(try text("ARRAYTOTEXT", matrix, .number(1)) == "{1,\"a\";3,4}")
    }

    // MARK: - TEXTSPLIT

    /// Columns by the first delimiter, rows by the second — and rows are the outer cut.
    @Test func textSplitMakesARectangle() throws {
        guard case .array(let matrix) = try call(
            "TEXTSPLIT", .text("a,b;c,d"), .text(","), .text(";")) else {
            Issue.record("expected a rectangle"); return
        }
        #expect(matrix.rows == 2)
        #expect(matrix.columns == 2)
        #expect(matrix.elements == [.text("a"), .text("b"), .text("c"), .text("d")])
    }

    /// One delimiter gives one row.
    @Test func textSplitWithOneDelimiter() throws {
        guard case .array(let matrix) = try call("TEXTSPLIT", .text("a,b,c"), .text(",")) else {
            Issue.record("expected a row"); return
        }
        #expect(matrix.rows == 1)
        #expect(matrix.elements == [.text("a"), .text("b"), .text("c")])
    }

    /// A ragged split is padded, and the padding is `#N/A` unless told otherwise.
    @Test func aRaggedSplitIsPadded() throws {
        guard case .array(let matrix) = try call(
            "TEXTSPLIT", .text("a,b;c"), .text(","), .text(";")) else {
            Issue.record("expected a rectangle"); return
        }
        #expect(matrix.elements == [.text("a"), .text("b"), .text("c"), .error(.na)])

        guard case .array(let padded) = try call(
            "TEXTSPLIT", .text("a,b;c"), .text(","), .text(";"),
            .bool(false), .number(0), .text("-")) else {
            Issue.record("expected a rectangle"); return
        }
        #expect(padded.elements.last == .text("-"))
    }

    /// Empty pieces are kept unless `ignore_empty` says to drop them.
    @Test func emptyPiecesAreKeptByDefault() throws {
        guard case .array(let kept) = try call("TEXTSPLIT", .text("a,,b"), .text(",")) else {
            Issue.record("expected a row"); return
        }
        #expect(kept.elements == [.text("a"), .text(""), .text("b")])

        guard case .array(let dropped) = try call(
            "TEXTSPLIT", .text("a,,b"), .text(","), .blank, .bool(true)) else {
            Issue.record("expected a row"); return
        }
        #expect(dropped.elements == [.text("a"), .text("b")])
    }

    // MARK: - The regular-expression trio

    @Test func regexTest() throws {
        #expect(try call("REGEXTEST", .text("a1b2"), .text("[0-9]")) == .bool(true))
        #expect(try call("REGEXTEST", .text("abc"), .text("[0-9]")) == .bool(false))
        // The flag is *case sensitivity*, and 0 — the default — is sensitive.
        #expect(try call("REGEXTEST", .text("ABC"), .text("abc")) == .bool(false))
        #expect(try call("REGEXTEST", .text("ABC"), .text("abc"), .number(1)) == .bool(true))
        // A pattern that will not compile is #VALUE!, not a guess at what was meant.
        #expect(try call("REGEXTEST", .text("a"), .text("[")) == .error(.value))
    }

    @Test func regexExtractsTheThreeWays() throws {
        #expect(try call("REGEXEXTRACT", .text("a1b22c"), .text("[0-9]+")) == .text("1"))

        guard case .array(let all) = try call(
            "REGEXEXTRACT", .text("a1b22c"), .text("[0-9]+"), .number(1)) else {
            Issue.record("expected a column of every match"); return
        }
        #expect(all.elements == [.text("1"), .text("22")])

        guard case .array(let groups) = try call(
            "REGEXEXTRACT", .text("2026-09-15"), .text("([0-9]{4})-([0-9]{2})"), .number(2)) else {
            Issue.record("expected a row of capture groups"); return
        }
        #expect(groups.elements == [.text("2026"), .text("09")])

        // Nothing matched is #N/A, which is what lets IFNA do its job.
        #expect(try call("REGEXEXTRACT", .text("abc"), .text("[0-9]")) == .error(.na))
    }

    @Test func regexReplaceCountsOccurrences() throws {
        #expect(try call("REGEXREPLACE", .text("a1b2"), .text("[0-9]"), .text("#")) == .text("a#b#"))
        #expect(try call("REGEXREPLACE", .text("a1b2"), .text("[0-9]"), .text("#"), .number(2)) == .text("a1b#"))
        // A negative occurrence counts from the end.
        #expect(try call("REGEXREPLACE", .text("a1b2"), .text("[0-9]"), .text("#"), .number(-1)) == .text("a1b#"))
        // An occurrence that is not there leaves the text alone.
        #expect(try call("REGEXREPLACE", .text("a1"), .text("[0-9]"), .text("#"), .number(5)) == .text("a1"))
    }

    // MARK: - Registration

    @Test func theNamesResolve() {
        for name in ["ISEVEN", "ISODD", "ISLOGICAL", "ISNONTEXT", "N", "TYPE", "ERROR.TYPE",
                     "ISFORMULA", "DOLLAR", "VALUETOTEXT", "ARRAYTOTEXT", "TEXTSPLIT",
                     "REGEXTEST", "REGEXEXTRACT", "REGEXREPLACE"] {
            #expect(registry.resolvedName(name) == FunctionRegistry.canonical(name), "\(name)")
        }
    }
}
