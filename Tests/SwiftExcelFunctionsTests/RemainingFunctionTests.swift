import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The tail: the last functions the corpus asks for that this package lacked.
///
/// `SUMPRODUCT` is the interesting one. Only 805 calls, but across **134
/// sheets** — the widest reach of anything unregistered, because it is how a
/// spreadsheet writes a dot product, and a dot product is how a spreadsheet
/// writes an objective function.
@Suite struct RemainingFunctionTests {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ args: [CellValue]) throws -> CellValue {
        let function = try #require(registry.function(named: name), "\(name) is not registered")
        return try function.evaluate(args)
    }

    private func number(_ name: String, _ args: [CellValue]) throws -> Double {
        guard case .number(let value) = try call(name, args) else {
            throw TestFailure("\(name) did not return a number")
        }
        return value
    }

    // MARK: - SUMPRODUCT

    /// Element by element, then summed: 1·4 + 2·5 + 3·6 = 32.
    @Test func sumProductIsADotProduct() throws {
        let left = CellValue.array(CellMatrix(row: [.number(1), .number(2), .number(3)]))
        let right = CellValue.array(CellMatrix(row: [.number(4), .number(5), .number(6)]))
        #expect(try number("SUMPRODUCT", [left, right]).isEqual(to: 32))
    }

    /// One array is a plain sum, which is what Excel does and what a constraint
    /// row written as `SUMPRODUCT(row)` relies on.
    @Test func sumProductOfOneArrayIsASum() throws {
        #expect(try number("SUMPRODUCT", [.array(CellMatrix(row: [.number(1), .number(2), .number(3)]))]).isEqual(to: 6))
    }

    /// More than two is still element-wise: 1·2·3 + 4·5·6 = 126.
    @Test func sumProductTakesMoreThanTwoArrays() throws {
        let a = CellValue.array(CellMatrix(row: [.number(1), .number(4)]))
        let b = CellValue.array(CellMatrix(row: [.number(2), .number(5)]))
        let c = CellValue.array(CellMatrix(row: [.number(3), .number(6)]))
        #expect(try number("SUMPRODUCT", [a, b, c]).isEqual(to: 126))
    }

    /// Text and blanks count as zero rather than erroring — Excel's rule, and the
    /// reason a label at the head of a row does not poison the whole product.
    @Test func sumProductTreatsNonNumbersAsZero() throws {
        let a = CellValue.array(CellMatrix(row: [.number(2), .text("label"), .blank]))
        let b = CellValue.array(CellMatrix(row: [.number(3), .number(9), .number(9)]))
        #expect(try number("SUMPRODUCT", [a, b]).isEqual(to: 6))
    }

    /// Arrays of different lengths are `#VALUE!`. Pairing them off by position
    /// and ignoring the tail would silently answer a question nobody asked.
    @Test func sumProductRejectsMismatchedLengths() throws {
        let a = CellValue.array(CellMatrix(row: [.number(1), .number(2)]))
        let b = CellValue.array(CellMatrix(row: [.number(1), .number(2), .number(3)]))
        #expect(try call("SUMPRODUCT", [a, b]) == .error(.value))
    }

    // MARK: - SUMSQ

    @Test func sumSqAddsSquares() throws {
        #expect(try number("SUMSQ", [.number(3), .number(4)]).isEqual(to: 25))
        #expect(try number("SUMSQ", [.array(CellMatrix(row: [.number(1), .number(2)]))]).isEqual(to: 5))
    }

    // MARK: - CHOOSE

    @Test func choosePicksTheNthValue() throws {
        let args: [CellValue] = [.number(2), .text("a"), .text("b"), .text("c")]
        #expect(try call("CHOOSE", args) == .text("b"))
    }

    /// Excel indexes from one. Zero and past the end are `#VALUE!`.
    @Test func chooseIsOneBasedAndBounded() throws {
        #expect(try call("CHOOSE", [.number(0), .text("a")]) == .error(.value))
        #expect(try call("CHOOSE", [.number(2), .text("a")]) == .error(.value))
    }

    // MARK: - LOOKUP

    /// Vector form: find the largest value not greater than the target, and take
    /// the matching entry from the result vector.
    @Test func lookupFindsTheLastValueNotGreaterThanTheTarget() throws {
        let lookup = CellValue.array(CellMatrix(row: [.number(10), .number(20), .number(30)]))
        let result = CellValue.array(CellMatrix(row: [.text("low"), .text("mid"), .text("high")]))
        #expect(try call("LOOKUP", [.number(25), lookup, result]) == .text("mid"))
        #expect(try call("LOOKUP", [.number(30), lookup, result]) == .text("high"))
    }

    /// Below everything in the vector there is no match.
    @Test func lookupBelowTheRangeIsNotAvailable() throws {
        let lookup = CellValue.array(CellMatrix(row: [.number(10), .number(20)]))
        #expect(try call("LOOKUP", [.number(5), lookup]) == .error(.na))
    }

    /// With no result vector, the lookup vector supplies the answer.
    @Test func lookupWithoutAResultVectorReturnsFromTheLookupVector() throws {
        let lookup = CellValue.array(CellMatrix(row: [.number(10), .number(20)]))
        #expect(try call("LOOKUP", [.number(15), lookup]) == .number(10))
    }
}
