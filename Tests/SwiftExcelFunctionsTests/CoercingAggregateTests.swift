import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore
import BusinessMath

/// The `A`-suffixed aggregates — `AVERAGEA`, `MAXA`, `MINA`, `STDEVA`, `STDEVPA`, `VARA`,
/// `VARPA`.
///
/// **These are not new mathematics. They are a different coercion rule wearing the same
/// arithmetic.** `AVERAGE` skips text and logicals inside a range; `AVERAGEA` counts text
/// as 0, `TRUE` as 1 and `FALSE` as 0. Everything else about the pair is identical, so
/// every test here is about which values reach the sum — not what happens to them after.
///
/// Microsoft, on the whole family: *"Arguments that contain TRUE evaluate as 1; arguments
/// that contain text or FALSE evaluate as 0 (zero). Empty cells are ignored."*
@Suite struct CoercingAggregateTests {

    private func fn(_ name: String) throws -> ExcelFunction {
        try #require(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
    }

    private func n(_ name: String, _ args: CellValue...) throws -> Double {
        guard case .number(let d) = try fn(name).evaluate(args) else {
            throw TestFailure("\(name) did not return a number")
        }
        return d
    }

    private func row(_ values: [CellValue]) -> CellValue {
        .array(CellMatrix(row: values))
    }

    // MARK: - The coercion rule, which is the whole function

    /// **Text counts as zero, and that is the entire difference.** `AVERAGE` of 10 and 20
    /// with a label beside them is 15; `AVERAGEA` is 10, because the label is a third
    /// observation worth nothing.
    @Test func textCountsAsZeroAndChangesTheDenominator() throws {
        let cells = row([.number(10), .text("n/a"), .number(20)])
        #expect(try abs(n("AVERAGEA", cells) - 10) <= 1e-12)
    }

    /// `TRUE` is 1 and `FALSE` is 0 — so a column of flags averages to the proportion that
    /// are set, which is what the function is for.
    @Test func logicalsCountAsOneAndZero() throws {
        let flags = row([.bool(true), .bool(true), .bool(false), .bool(false)])
        #expect(try abs(n("AVERAGEA", flags) - 0.5) <= 1e-12)
    }

    /// **Empty cells are still ignored.** They are not zeros — a blank in a range must not
    /// pull the mean down, which is the one place the `A` variants agree with their
    /// plain counterparts.
    @Test func emptyCellsAreStillIgnored() throws {
        #expect(try abs(n("AVERAGEA", row([.number(10), .blank, .number(20)])) - 15) <= 1e-12)
    }

    // MARK: - The extremes

    /// `MAXA` and `MINA` see the coerced values, so text at zero can *become* the minimum
    /// of a set of positive numbers — the case that catches people out.
    @Test func textBecomesTheMinimum() throws {
        let cells = row([.number(5), .text("closed"), .number(9)])
        #expect(try abs(n("MINA", cells) - 0) <= 1e-12)
        #expect(try abs(n("MAXA", cells) - 9) <= 1e-12)
    }

    /// And `TRUE` at 1 can be the maximum of a set of fractions.
    @Test func trueCanBeTheMaximum() throws {
        #expect(try abs(n("MAXA", row([.number(0.2), .bool(true), .number(0.9)])) - 1) <= 1e-12)
    }

    // MARK: - Sample against population

    /// `STDEVA` is the **sample** deviation and `STDEVPA` the **population** one — the same
    /// `n − 1` against `n` split the plain versions have. On the same data the sample value
    /// is the larger.
    /// The population value is asserted against the definition computed here, not against
    /// a recalled figure. The first draft said 1.0 — the classic eight-value example's
    /// answer, not this five-value one's, which is √0.96. Third time today a remembered
    /// constant failed correct code, and the fix each time was to assert the arithmetic
    /// rather than the memory.
    @Test func sampleAndPopulationDiffer() throws {
        let observations: [Double] = [2, 4, 4, 4, 5]
        let cells = row(observations.map { CellValue.number($0) })

        let average = observations.reduce(0, +) / Double(observations.count)
        let squaredDeviations = observations.reduce(0) { $0 + ($1 - average) * ($1 - average) }
        let populationSigma = (squaredDeviations / Double(observations.count)).squareRoot()

        #expect(try abs(n("STDEVPA", cells) - populationSigma) <= 1e-12)
        #expect(try n("STDEVA", cells) > n("STDEVPA", cells), "the sample form divides by n − 1 and is the larger")
    }

    /// Variance is the square of the deviation, which is the relationship rather than a
    /// second implementation.
    @Test func varianceIsTheSquareOfTheDeviation() throws {
        let cells = row([.number(2), .number(4), .number(4), .number(4), .number(5)])
        #expect(try abs(n("VARA", cells) - Foundation.pow(try n("STDEVA", cells), 2)) <= 1e-12)
        #expect(try abs(n("VARPA", cells) - Foundation.pow(try n("STDEVPA", cells), 2)) <= 1e-12)
    }

    /// The coercion reaches the dispersion functions too: a text value is an observation
    /// at zero, which widens the spread rather than being skipped.
    @Test func coercionWidensTheSpread() throws {
        let plain = row([.number(4), .number(4), .number(4)])
        let withText = row([.number(4), .number(4), .number(4), .text("-")])
        #expect(try abs(n("STDEVPA", plain) - 0) <= 1e-12)
        #expect(try n("STDEVPA", withText) > 0)
    }

    // MARK: - Degenerate input

    /// A sample deviation needs two observations; one is `#DIV/0!`, as Excel reports.
    @Test func sampleDeviationNeedsTwoObservations() throws {
        #expect(try fn("STDEVA").evaluate([row([.number(1)])]) == .error(.div0))
        #expect(try fn("VARA").evaluate([row([.number(1)])]) == .error(.div0))
    }

    /// Nothing at all to average is `#DIV/0!` too.
    @Test func nothingToAverage() throws {
        #expect(try fn("AVERAGEA").evaluate([row([.blank, .blank])]) == .error(.div0))
    }
}
