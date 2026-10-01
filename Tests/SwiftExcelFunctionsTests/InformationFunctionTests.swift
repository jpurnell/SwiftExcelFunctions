import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The predicates a formula branches on.
///
/// `IF` and `IFERROR` were here already; the tests that decide what they branch
/// on were not. `ISERROR` alone is called 2,462 times across 79 workbooks and
/// resolves to nothing, which means any formula guarding a division was
/// unreadable in its entirety.
///
/// These ask about a *value*, so they belong with the logic functions rather
/// than with navigation: none of them needs to know where it was called from.
@Suite struct InformationFunctionTests {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: [CellValue]) throws -> CellValue {
        let function = try #require(registry.function(named: name), "\(name) is not registered")
        return try function.evaluate(args)
    }

    // MARK: - Error predicates

    /// `ISERROR` is true for every Excel error, `#N/A` included.
    @Test func isErrorIsTrueForAnyError() throws {
        for error in [ExcelError.div0, .value, .ref, .name, .num, .na] {
            #expect(try call("ISERROR", [.error(error)]) == .bool(true), "\(error)")
        }
        #expect(try call("ISERROR", [.number(1)]) == .bool(false))
    }

    /// `ISERR` is `ISERROR` minus `#N/A`. The distinction exists so a formula can
    /// treat "no value yet" differently from "the arithmetic went wrong".
    @Test func isErrExcludesNotAvailable() throws {
        #expect(try call("ISERR", [.error(.div0)]) == .bool(true))
        #expect(try call("ISERR", [.error(.na)]) == .bool(false), "#N/A is not an ISERR error")
    }

    @Test func isNAIsTrueOnlyForNotAvailable() throws {
        #expect(try call("ISNA", [.error(.na)]) == .bool(true))
        #expect(try call("ISNA", [.error(.div0)]) == .bool(false))
        #expect(try call("ISNA", [.number(1)]) == .bool(false))
    }

    /// `NA()` produces `#N/A`, which is how a sheet says "deliberately absent".
    @Test func naProducesNotAvailable() throws {
        #expect(try call("NA", []) == .error(.na))
    }

    // MARK: - Type predicates

    @Test func isBlankIsTrueOnlyForAnEmptyCell() throws {
        #expect(try call("ISBLANK", [.blank]) == .bool(true))
        #expect(try call("ISBLANK", [.text("")]) == .bool(false), "an empty string is a value")
        #expect(try call("ISBLANK", [.number(0)]) == .bool(false))
    }

    @Test func isNumberIsTrueForNumbersOnly() throws {
        #expect(try call("ISNUMBER", [.number(0)]) == .bool(true))
        #expect(try call("ISNUMBER", [.text("1")]) == .bool(false), "text is not a number")
        #expect(try call("ISNUMBER", [.bool(true)]) == .bool(false))
        #expect(try call("ISNUMBER", [.blank]) == .bool(false))
    }

    @Test func isTextIsTrueForTextOnly() throws {
        #expect(try call("ISTEXT", [.text("x")]) == .bool(true))
        #expect(try call("ISTEXT", [.number(1)]) == .bool(false))
        #expect(try call("ISTEXT", [.blank]) == .bool(false))
    }

    /// A predicate never propagates the error it is asked about — that is the
    /// whole point of it. `ISERROR(1/0)` is `TRUE`, not `#DIV/0!`.
    @Test func aPredicateAnswersAboutAnErrorRatherThanPropagatingIt() throws {
        for name in ["ISERROR", "ISERR", "ISNA", "ISBLANK", "ISNUMBER", "ISTEXT"] {
            let result = try call(name, [.error(.div0)])
            #expect(result.isBool, "\(name) propagated the error instead of answering: \(result)")
        }
    }
}
