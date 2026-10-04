import Foundation
import SwiftExcelCore
import Testing
@testable import SwiftExcelFunctions

/// The bounds on `REGEXTEST`, `REGEXEXTRACT` and `REGEXREPLACE`.
///
/// A workbook supplies the pattern, so a workbook chooses how long matching takes: a
/// backtracking engine is exponential on `(a+)+$`, and nothing in Excel's file format stops
/// a cell from holding it. Microsoft's reference for the three functions documents no error
/// values at all, so the answer for a refused input is the one this package already gives
/// for a pattern that will not compile, and the one Excel gives when text outgrows a cell
/// (`CONCAT`, `REPT`): `#VALUE!`.
@Suite struct RegexBoundsTests {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let function = registry.function(named: name) else {
            Issue.record("\(name) is not registered"); return .error(.name)
        }
        return try function.evaluate(args)
    }

    private func repeated(_ piece: String, _ count: Int) -> CellValue {
        .text(String(repeating: piece, count: count))
    }

    // MARK: - The limits are Excel's

    @Test func theLimitsAreExcelsOwn() {
        // A cell holds at most 32,767 characters; a formula at most 8,192.
        #expect(BuiltinTextConversionFunctions.maximumRegexSubjectLength == 32_767)
        #expect(BuiltinTextConversionFunctions.maximumRegexPatternLength == 8_192)
        #expect(BuiltinTextConversionFunctions.regexMatchDeadline == .seconds(1))
    }

    // MARK: - Pattern length

    @Test func aPatternAtTheLimitStillRuns() throws {
        let pattern = repeated("a", 8_192)
        #expect(try call("REGEXTEST", pattern, pattern) == .bool(true))
        #expect(try call("REGEXEXTRACT", .text("xa"), .text("a")) == .text("a"))
    }

    @Test(arguments: ["REGEXTEST", "REGEXEXTRACT"])
    func aPatternOverTheLimitIsValueError(name: String) throws {
        #expect(try call(name, .text("a"), repeated("a", 8_193)) == .error(.value))
    }

    @Test func replaceRefusesAPatternOverTheLimit() throws {
        #expect(try call("REGEXREPLACE", .text("a"), repeated("a", 8_193), .text("b")) == .error(.value))
    }

    // MARK: - Subject length

    @Test func aSubjectAtTheLimitStillRuns() throws {
        #expect(try call("REGEXTEST", repeated("a", 32_767), .text("a$")) == .bool(true))
        #expect(try call("REGEXTEST", repeated("a", 32_767), .text("b")) == .bool(false))
    }

    @Test(arguments: ["REGEXTEST", "REGEXEXTRACT"])
    func aSubjectOverTheLimitIsValueError(name: String) throws {
        #expect(try call(name, repeated("a", 32_768), .text("a")) == .error(.value))
    }

    @Test func replaceRefusesASubjectOverTheLimit() throws {
        #expect(try call("REGEXREPLACE", repeated("a", 32_768), .text("a"), .text("b")) == .error(.value))
    }

    @Test func lengthIsCountedTheWayExcelCountsIt() throws {
        // Excel's limit is in UTF-16 code units, and an emoji is two of them.
        #expect(try call("REGEXTEST", repeated("😀", 16_383), .text("x")) == .bool(false))
        #expect(try call("REGEXTEST", repeated("😀", 16_384), .text("x")) == .error(.value))
    }

    // MARK: - Replacement and result size

    @Test func replaceRefusesAReplacementOverTheLimit() throws {
        #expect(try call("REGEXREPLACE", .text("a"), .text("a"), repeated("b", 32_767)) == repeated("b", 32_767))
        #expect(try call("REGEXREPLACE", .text("a"), .text("a"), repeated("b", 32_768)) == .error(.value))
    }

    @Test func replaceRefusesAResultThatWouldNotFitInACell() throws {
        // 200 matches, each replaced by 200 characters, is 40,000 — more than a cell holds.
        #expect(try call("REGEXREPLACE", repeated("a", 200), .text("a"), repeated("b", 200)) == .error(.value))
        // 100 × 200 is 20,000, which fits.
        #expect(try call("REGEXREPLACE", repeated("a", 100), .text("a"), repeated("b", 200)) == repeated("b", 20_000))
        // One occurrence replaced: 199 kept, 200 added.
        #expect(
            try call("REGEXREPLACE", repeated("a", 200), .text("a"), repeated("b", 200), .number(1))
                == .text(String(repeating: "b", count: 200) + String(repeating: "a", count: 199)))
    }

    // MARK: - Catastrophic shapes

    @Test(arguments: [
        #"(a+)+$"#, #"(a*)*$"#, #"(a|aa)+$"#, #"(a|ab)+$"#, #"(\w+\s?)*$"#, #"^(([a-z])+.)+$"#,
    ])
    func aCatastrophicPatternIsRefusedWithoutBeingRun(pattern: String) throws {
        // Thirty characters is enough for the first of these to run for minutes if matched.
        let subject = repeated("a", 30)
        let clock = ContinuousClock()
        var answers: [CellValue] = []
        let elapsed = try clock.measure {
            answers = [
                try call("REGEXTEST", subject, .text(pattern)),
                try call("REGEXEXTRACT", subject, .text(pattern)),
                try call("REGEXREPLACE", subject, .text(pattern), .text("x")),
            ]
        }
        #expect(answers == [.error(.value), .error(.value), .error(.value)])
        #expect(elapsed < .milliseconds(250))
    }

    @Test func theRefusalDoesNotDependOnTheSubject() throws {
        // Refused for what the pattern is, not for what it was given: a short subject that
        // would have matched instantly gets the same answer as a long one that would not.
        #expect(try call("REGEXTEST", .text("a"), .text("(a+)+$")) == .error(.value))
        #expect(try call("REGEXTEST", .text(""), .text("(a+)+$")) == .error(.value))
    }

    // MARK: - What is not refused

    @Test func repetitionBehindASeparatorIsLinearAndRuns() throws {
        // Each pass must consume a character the inner quantifier cannot, so these are linear.
        #expect(try call("REGEXTEST", .text("1,22,333"), .text(#"^(\d+,)*\d+$"#)) == .bool(true))
        #expect(try call("REGEXEXTRACT", .text("v1.20.3 "), .text(#"\d+(?:\.\d+)*"#)) == .text("1.20.3"))
        #expect(try call("REGEXTEST", .text("abab"), .text("^(ab)+$")) == .bool(true))
        #expect(try call("REGEXTEST", .text("cat dog"), .text("^(cat|dog| )+$")) == .bool(true))
    }

    @Test func possessiveAndAtomicRepetitionCannotBacktrackAndRuns() throws {
        #expect(try call("REGEXTEST", .text("aaa"), .text("^(a+)++$")) == .bool(true))
        #expect(try call("REGEXTEST", .text("aaa"), .text("^(?>a+)+$")) == .bool(true))
    }

    @Test func aQuantifierInsideACharacterClassIsALiteral() throws {
        #expect(try call("REGEXTEST", .text("a+b"), .text("^([a+]+b)$")) == .bool(true))
        #expect(try call("REGEXEXTRACT", .text("1+2*3"), .text("[+*]")) == .text("+"))
        #expect(try call("REGEXTEST", .text("(a+)+"), .text(#"\(a\+\)\+"#)) == .bool(true))
    }

    @Test func ordinaryPatternsAnswerAsTheyDid() throws {
        #expect(try call("REGEXTEST", .text("a1b2"), .text("[0-9]")) == .bool(true))
        #expect(try call("REGEXTEST", .text("ABC"), .text("abc"), .number(1)) == .bool(true))
        #expect(try call("REGEXTEST", .text("a"), .text("[")) == .error(.value))
        #expect(try call("REGEXEXTRACT", .text("abc"), .text("[0-9]")) == .error(.na))
        #expect(try call("REGEXREPLACE", .text("a1b2"), .text("[0-9]"), .text("#")) == .text("a#b#"))
        #expect(try call("REGEXREPLACE", .text("a1b2"), .text("([a-z])([0-9])"), .text("$2$1")) == .text("1a2b"))
        #expect(try call("REGEXREPLACE", .text("a1b2"), .text("[0-9]"), .text("#"), .number(-1)) == .text("a1b#"))
        // Empty matches are matches: one before each character and one at the end.
        #expect(try call("REGEXREPLACE", .text("abc"), .text("x*"), .text("-")) == .text("-a-b-c-"))
        // An empty pattern is one `NSRegularExpression` will not compile.
        #expect(try call("REGEXREPLACE", .text("abc"), .text(""), .text("-")) == .error(.value))

        guard case .array(let all) = try call("REGEXEXTRACT", .text("a1b22c"), .text("[0-9]+"), .number(1)) else {
            Issue.record("expected a column of every match"); return
        }
        #expect(all.elements == [.text("1"), .text("22")])
    }

    // MARK: - The deadline

    @Test func aSlowMatchTheShapeCheckCannotSeeStopsAtTheDeadline() throws {
        // Quadratic, not exponential, so nothing about its shape is refused — but on a
        // full-length cell it runs for over a minute. The deadline is what answers.
        let subject = CellValue.text(String(repeating: "1", count: 32_766) + "x")
        let clock = ContinuousClock()
        var answer = CellValue.blank
        let elapsed = try clock.measure {
            answer = try call("REGEXTEST", subject, .text(#"\d+(?:\.\d+)*$"#))
        }
        #expect(answer == .error(.value))
        #expect(elapsed >= .seconds(1))
        #expect(elapsed < .seconds(5))
    }
}
