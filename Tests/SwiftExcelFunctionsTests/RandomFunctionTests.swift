import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// `RAND()` and `RANDBETWEEN()`, which this package deliberately cannot do alone.
///
/// Excel exposes no seed, so there is no sequence to reproduce and nothing to
/// mimic. What is observable is the contract — uniform in `[0, 1)`, and a uniform
/// integer inclusive of both bounds — and that is all these promise.
///
/// The randomness itself comes from the caller. This package never reaches for
/// system entropy, which is what lets it be deterministic by construction rather
/// than deterministic by justification.
final class RandomFunctionTests: XCTestCase {

    private struct Cells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
    }

    /// Hands back exactly what a test wants, in order.
    // Justification: single-threaded test double; the shipped SeededRandomSource is the one that locks.
    private final class FixedSource: RandomSource, @unchecked Sendable {
        private var values: [Double]
        private var index = 0
        init(_ values: [Double]) { self.values = values }
        func nextUniform() -> Double {
            defer { index += 1 }
            return values[index % values.count]
        }

        /// Scales the fixed sequence, so a test can still steer the integer draw.
        func nextInteger(below bound: Int) -> Int {
            Swift.min(Int(nextUniform() * Double(bound)), bound - 1)
        }
    }

    private func evaluate(_ ast: FormulaAST, random: RandomSource?) throws -> CellValue {
        try FormulaEvaluator.evaluate(
            ast, cells: Cells(), names: NamedRangeCollection(),
            at: nil, inSheet: "Sheet1", random: random)
    }

    // MARK: - The contract

    func testRandReturnsWhatTheSourceGives() throws {
        let result = try evaluate(.function("RAND", []), random: FixedSource([0.25]))
        XCTAssertEqual(result, .number(0.25))
    }

    /// Both bounds are inclusive, which is where an off-by-one would hide: a
    /// source at the very top of `[0, 1)` must still land on `top`, not past it.
    func testRandBetweenIncludesBothBounds() throws {
        let low = try evaluate(
            .function("RANDBETWEEN", [.number(1), .number(6)]), random: FixedSource([0.0]))
        XCTAssertEqual(low, .number(1))

        let high = try evaluate(
            .function("RANDBETWEEN", [.number(1), .number(6)]),
            random: FixedSource([0.999_999_999]))
        XCTAssertEqual(high, .number(6))
    }

    /// Every outcome is reachable and none is favoured.
    ///
    /// The check that matters after moving off a scaled double: over a range that
    /// does not divide the generator's period evenly, a scaled draw leans. A
    /// rejecting integer draw does not.
    func testRandBetweenIsEvenOverAnAwkwardRange() throws {
        let source = SeededRandomSource(seed: 99)
        var counts: [Double: Int] = [:]
        for _ in 0..<30_000 {
            guard case .number(let value) = try evaluate(
                .function("RANDBETWEEN", [.number(1), .number(7)]), random: source) else {
                return XCTFail("expected a number")
            }
            counts[value, default: 0] += 1
        }
        XCTAssertEqual(counts.count, 7, "every outcome reachable")
        for (outcome, count) in counts {
            // 30,000 over 7 is ~4,286; ±10% is loose enough never to flake on a
            // fixed seed and tight enough to catch a systematic lean.
            XCTAssertEqual(Double(count), 4_285.7, accuracy: 430, "outcome \(outcome)")
        }
    }

    func testRandBetweenSpreadsAcrossItsRange() throws {
        let source = FixedSource([0.0, 0.2, 0.4, 0.6, 0.8, 0.99])
        var seen: Set<Double> = []
        for _ in 0..<6 {
            guard case .number(let value) = try evaluate(
                .function("RANDBETWEEN", [.number(1), .number(6)]), random: source) else {
                return XCTFail("expected a number")
            }
            seen.insert(value)
        }
        XCTAssertEqual(seen, [1, 2, 3, 4, 5, 6])
    }

    /// Reversed bounds are `#NUM!`, as in Excel.
    func testRandBetweenRejectsReversedBounds() throws {
        let result = try evaluate(
            .function("RANDBETWEEN", [.number(6), .number(1)]), random: FixedSource([0.5]))
        XCTAssertEqual(result, .error(.num))
    }

    // MARK: - No source

    /// Without a source there is no answer, and the package says so rather than
    /// quietly reaching for system entropy. Same posture as `COLUMN()` with no
    /// calling cell: report rather than invent.
    func testWithoutASourceTheAnswerIsAnError() throws {
        XCTAssertEqual(try evaluate(.function("RAND", []), random: nil), .error(.value))
        XCTAssertEqual(
            try evaluate(.function("RANDBETWEEN", [.number(1), .number(6)]), random: nil),
            .error(.value))
    }

    // MARK: - Seeding

    /// The same seed gives the same stream. This is the property Excel cannot
    /// offer at all, and the reason for not imitating it.
    func testTheSameSeedGivesTheSameStream() {
        let first = SeededRandomSource(seed: 42)
        let second = SeededRandomSource(seed: 42)
        let a = (0..<8).map { _ in first.nextUniform() }
        let b = (0..<8).map { _ in second.nextUniform() }
        XCTAssertEqual(a, b)
    }

    func testDifferentSeedsGiveDifferentStreams() {
        let a = (0..<8).map { _ in SeededRandomSource(seed: 1).nextUniform() }
        let b = (0..<8).map { _ in SeededRandomSource(seed: 2).nextUniform() }
        XCTAssertNotEqual(a, b)
    }

    /// Every draw lies in `[0, 1)` — the half-open interval Excel documents, so
    /// `RANDBETWEEN`'s top bound is reachable and 1.0 is never returned.
    func testEveryDrawIsInTheHalfOpenUnitInterval() {
        let source = SeededRandomSource(seed: 7)
        for _ in 0..<1_000 {
            let value = source.nextUniform()
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThan(value, 1)
        }
    }
}
