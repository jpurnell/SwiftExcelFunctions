import Foundation
import SwiftExcelCore
import Foundation
import Testing
@testable import SwiftExcelFunctions

/// `SUBTOTAL` — the eleven aggregates, and the two rules this package cannot model.
///
/// The dispersion figures come from NumPy (`ddof=1` and `ddof=0`); the rest is arithmetic
/// over four numbers, checkable by eye, which is what a test of a dispatch table should be.
@Suite struct SubtotalTests {

    private let registry = FunctionRegistry.builtin

    /// Four numbers, a label and an empty cell — the shape of a real column, because
    /// `COUNT` and `COUNTA` differ only when both are present.
    private let column = CellValue.array(CellMatrix(row: [
        .number(10), .number(20), .number(30), .number(40), .text("Total"), .blank,
    ]))

    private func call(_ code: Double) throws -> CellValue {
        guard let function = registry.function(named: "SUBTOTAL") else {
            Issue.record("SUBTOTAL is not registered"); return .error(.name)
        }
        return try function.evaluate([.number(code), column])
    }

    private func number(_ code: Double) throws -> Double {
        guard case .number(let value) = try call(code) else {
            Issue.record("SUBTOTAL(\(code)) did not answer with a number"); return .nan
        }
        return value
    }

    /// Every code in the 1–11 block.
    @Test func everyAggregate() throws {
        #expect(try number(1).isEqual(to: 25))                                    // AVERAGE
        #expect(try number(2).isEqual(to: 4))                                     // COUNT
        #expect(try number(3).isEqual(to: 5))                                     // COUNTA
        #expect(try number(4).isEqual(to: 40))                                    // MAX
        #expect(try number(5).isEqual(to: 10))                                    // MIN
        #expect(try number(6).isEqual(to: 240_000))                               // PRODUCT
        #expect(try abs(number(7) - 12.909944487358056) <= 1e-12)   // STDEV
        #expect(try abs(number(8) - 11.180339887498949) <= 1e-12)   // STDEVP
        #expect(try number(9).isEqual(to: 100))                                   // SUM
        #expect(try abs(number(10) - 166.66666666666666) <= 1e-10)  // VAR
        #expect(try abs(number(11) - 125) <= 1e-12)                 // VARP
    }

    /// `COUNT` and `COUNTA` are the pair that separates the two readings of the range.
    ///
    /// Four numbers, one label, one empty cell: `COUNT` sees the numbers, `COUNTA` sees
    /// everything that is *there*. A blank counted by `COUNTA` would be the mistake, and it
    /// is invisible in any column with no gaps.
    @Test func countAndCountAReadTheRangeDifferently() throws {
        #expect(try number(2).isEqual(to: 4))
        #expect(try number(3).isEqual(to: 5))
    }

    /// The hundreds answer the same thing, because row visibility is not ours to see.
    ///
    /// Asserted rather than left implicit: this is a documented limitation, and a test that
    /// pins it is what makes it a decision rather than an oversight. If visibility ever
    /// reaches the evaluator, this test fails and says where to look.
    @Test func theHundredsBlockAnswersTheSame() throws {
        for code in stride(from: 1.0, through: 11.0, by: 1) {
            #expect(try call(code) == call(code + 100), "code \(code)")
        }
    }

    /// A function number in neither block is `#VALUE!`, and a fractional one truncates.
    @Test func theFunctionNumberIsValidated() throws {
        #expect(try call(0) == .error(.value))
        #expect(try call(12) == .error(.value))
        #expect(try call(100) == .error(.value))
        #expect(try call(112) == .error(.value))
        #expect(try call(9.7) == call(9))
    }

    /// An empty selection: zero for the extremes, an error for the mean.
    ///
    /// Not a rule either way — it is what Excel does for each, and the two disagree.
    @Test func anEmptySelection() throws {
        guard let function = registry.function(named: "SUBTOTAL") else {
            Issue.record("SUBTOTAL is not registered"); return
        }
        let empty = CellValue.array(CellMatrix(row: [.blank, .text("x")]))
        #expect(try function.evaluate([.number(9), empty]) == .number(0))
        #expect(try function.evaluate([.number(4), empty]) == .number(0))
        #expect(try function.evaluate([.number(1), empty]) == .error(.div0))
        #expect(try function.evaluate([.number(7), empty]) == .error(.div0))
    }

    /// An error anywhere in the range propagates, as it does through every aggregate.
    @Test func anErrorPropagates() throws {
        guard let function = registry.function(named: "SUBTOTAL") else {
            Issue.record("SUBTOTAL is not registered"); return
        }
        let withError = CellValue.array(CellMatrix(row: [.number(1), .error(.div0)]))
        #expect(try function.evaluate([.number(9), withError]) == .error(.div0))
        // The error in the *first* argument is the one that stops the call.
        #expect(try function.evaluate([.error(.na), column]) == .error(.na))
    }
}
