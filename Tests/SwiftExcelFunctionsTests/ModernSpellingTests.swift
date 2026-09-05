import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// Excel 2010 renamed its statistical functions and kept the old names working.
///
/// `STDEV` became `STDEV.S`, `VAR` became `VAR.S`, and so on. Both spellings are
/// live — Excel still accepts the legacy ones — so a registry holding only the
/// old names silently misses every workbook saved this decade.
///
/// Measured across 79 workbooks, `STDEV.S` alone is called **86,410 times** and
/// resolves to nothing. It is the single most-called function this package does
/// not answer, and it needs no new mathematics: the implementation is already
/// here under its other name.
final class ModernSpellingTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: [CellValue]) throws -> CellValue {
        let function = try XCTUnwrap(registry.function(named: name), "\(name) is not registered")
        return try function.evaluate(args)
    }

    /// Each modern name must exist and agree with the legacy one it renames.
    func testEachModernSpellingAgreesWithTheNameItReplaced() throws {
        let sample: [CellValue] = [.number(2), .number(4), .number(4), .number(4),
                                   .number(5), .number(5), .number(7), .number(9)]
        for (modern, legacy) in [("STDEV.S", "STDEV"), ("STDEV.P", "STDEVP"),
                                 ("VAR.S", "VAR"), ("VAR.P", "VARP")] {
            let new = try call(modern, sample)
            let old = try call(legacy, sample)
            XCTAssertEqual(new, old, "\(modern) must be \(legacy)")
        }
    }

    /// `PERCENTILE.INC` renames `PERCENTILE` — inclusive is what the old one did.
    func testPercentileIncIsThePercentileItRenames() throws {
        let sample: [CellValue] = [.number(1), .number(2), .number(3), .number(4)]
        let new = try call("PERCENTILE.INC", sample + [.number(0.25)])
        let old = try call("PERCENTILE", sample + [.number(0.25)])
        XCTAssertEqual(new, old)
    }

    /// Both spellings stay. Excel never withdrew the legacy names, so removing
    /// them here would break the workbooks that still use them — and the corpus
    /// contains both.
    func testTheLegacySpellingsAreStillRegistered() {
        for name in ["STDEV", "STDEVP", "VAR", "VARP", "PERCENTILE"] {
            XCTAssertNotNil(registry.function(named: name), "\(name) was withdrawn")
        }
    }

    /// A sample standard deviation of this set is 2.13809..., which is what both
    /// spellings must return — an anchor against the pair agreeing on a wrong
    /// answer.
    func testTheSharedImplementationIsRight() throws {
        guard case .number(let value) = try call("STDEV.S", [.number(2), .number(4), .number(4),
                                                             .number(4), .number(5), .number(5),
                                                             .number(7), .number(9)]) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(value, 2.13809, accuracy: 0.00001)
    }
}
