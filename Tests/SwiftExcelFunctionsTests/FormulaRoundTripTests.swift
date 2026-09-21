import Foundation
import SwiftExcelCore
import SwiftXLSX
import XCTest
@testable import SwiftExcelFunctions

/// Where `serialize(parse(x))` is `x`, and where it is not.
///
/// **This is the ledger a round trip is built on.** `PROPOSAL_defined_names.md` chooses to
/// reconstruct a name's refers-to text from its parsed target rather than keep a copy of the
/// original, and that choice is only safe for the shapes where the reconstruction is exact.
/// This test is the list of which those are — measured, and pinned, so a change in the
/// serializer shows up here rather than in somebody's workbook.
///
/// The three failures are not equal and the proposal treats them differently:
///
/// | Shape | Result | What it is |
/// |---|---|---|
/// | unnecessary quoting | `Definitions!$B$53` → `'Definitions'!$B$53` | cosmetic; Excel accepts both |
/// | function-name case | `_xlfn.LAMBDA` → `_XLFN.LAMBDA` | cosmetic; Excel accepts both |
/// | whole-column expansion | `$D:$D` → `D1:D1048576` | **visible** — the Name Manager shows the expansion |
/// | the text-node fallback | `.text("42")` → `"42"` | **wrong** — a number becomes a string |
final class FormulaRoundTripTests: XCTestCase {

    private func roundTrip(_ text: String) throws -> String {
        FormulaSerializer.serialize(try FormulaParser.parse(text))
    }

    /// The shapes that survive a round trip exactly, and may therefore be reconstructed.
    func testWhatIsExact() throws {
        for text in ["42", "0.0825", "#REF!", "\"a label\"", "SUM(A1:A10)*2",
                     "'2018 - Sorted by Area'!$J$2:$J$333"] {
            XCTAssertEqual(try roundTrip(text), text, text)
        }
    }

    /// Quoting a sheet name that needs no quotes: accepted by Excel, different in the file.
    ///
    /// Fixable with a rule rather than with stored state — quote only where Excel would — and
    /// the rule is checkable against the corpus's 161,901 names.
    func testSheetNamesAreAlwaysQuoted() throws {
        XCTAssertEqual(try roundTrip("Definitions!$B$53"), "'Definitions'!$B$53")
        XCTAssertEqual(try roundTrip("Definitions!$B$19:$C$51"), "'Definitions'!$B$19:$C$51")
    }

    /// A function name comes back upper-cased and its spacing normalised.
    func testFunctionNamesAreUppercased() throws {
        XCTAssertEqual(try roundTrip("_xlfn.LAMBDA(_xlpm.x, _xlpm.x+1)"),
                       "_XLFN.LAMBDA(_xlpm.x,_xlpm.x+1)")
    }

    /// **A whole column expands, and that one is visible to the user.**
    ///
    /// `$D:$D` means "column D" and says so in the Name Manager. `$D1:$D1048576` is the same
    /// cells and reads as a mistake. Reconstructing this shape needs the writer to recognise a
    /// full-column span and write the short form — a rule, again, not a second copy of the
    /// text.
    ///
    /// **The `$` used to be lost here too**, and that was not cosmetic: the lexer discarded it
    /// before the parser saw it, so a shared formula moved columns Excel pins. This expectation
    /// read `D1:D1048576`, and it passed. What remains lost is only the short form.
    func testAWholeColumnExpands() throws {
        XCTAssertEqual(try roundTrip("Expenditures!$D:$D"), "'Expenditures'!$D1:$D1048576")
    }

    /// **The fallback the defined-name resolver uses today is not lossy, it is wrong.**
    ///
    /// A refers-to it cannot parse becomes `.formula(.text(raw))` — a claim that the name *is*
    /// a text constant. Serialising that adds quotes, so a reference becomes a caption and a
    /// number becomes a string. This is why the proposal adds `.unparsed`, whose round trip is
    /// the identity function and needs no rule at all.
    func testTheTextNodeFallbackCorrupts() {
        XCTAssertEqual(FormulaSerializer.serialize(.text("Expenditures!$D:$D")),
                       "\"Expenditures!$D:$D\"")
        XCTAssertEqual(FormulaSerializer.serialize(.text("42")), "\"42\"")
    }
}
