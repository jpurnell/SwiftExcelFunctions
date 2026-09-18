import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// The twenty-one rows that were `bindable` and unbound.
///
/// They were not part of the unreviewed bucket — they carried a status before this work began
/// and kept it, which is how "every row classified" and "every row implemented" came apart.
/// Expected values are Microsoft's published examples where they publish one.
final class BoundBacklogTests: XCTestCase {

    private struct Cells: CellValueProvider {
        var data: [String: CellValue] = [:]
        func value(at ref: CellRef) -> CellValue? { data[ref.reference] }
        func value(at ref: CellRef, inSheet sheet: String) -> CellValue? { nil }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet sheet: String) -> CellRef? { nil }
        func values(in range: CellRange) -> [CellValue] { range.cells.compactMap { value(at: $0) } }
        func values(in range: CellRange, inSheet sheet: String) -> [CellValue] { [] }
    }
    private struct Names: NameResolver {
        func resolve(_ name: String, inSheet: String?) -> NamedRangeTarget? { nil }
    }
    private let letters = ["A", "B", "C", "D", "E"]

    private func block(_ start: String, _ rows: [[CellValue]]) -> (FormulaAST, [String: CellValue]) {
        guard let origin = letters.firstIndex(of: start), let width = rows.first?.count else {
            return (.error(.value), [:])
        }
        var data: [String: CellValue] = [:]
        for (r, row) in rows.enumerated() {
            for (c, v) in row.enumerated() { data["\(letters[origin + c])\(r + 1)"] = v }
        }
        return (.cellRange(CellRange(from: "\(start)1",
                                     to: "\(letters[origin + width - 1])\(rows.count)")), data)
    }

    private func call(_ name: String, _ args: [FormulaAST],
                      _ data: [String: CellValue] = [:]) throws -> CellValue {
        try FormulaEvaluator.evaluate(.function(name, args), cells: Cells(data: data),
                                      names: Names(), functions: .builtin)
    }

    private func n(_ v: [Double]) -> [CellValue] { v.map { .number($0) } }
    private func col(_ v: [Double]) -> [[CellValue]] { v.map { [.number($0)] } }

    private func value(_ r: CellValue) -> Double? {
        if case .number(let d) = r { return d }
        if case .array(let m) = r, let first = m.elements.first,
           case .number(let d) = first { return d }
        return nil
    }
    private func numbers(_ r: CellValue) -> [Double]? {
        guard case .array(let m) = r else { return nil }
        return m.elements.map { if case .number(let d) = $0 { return d } else { return .nan } }
    }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> FormulaAST {
        .function("DATE", [.number(Double(y)), .number(Double(m)), .number(Double(d))])
    }

    // MARK: - math

    /// `FACT` runs to 170 in `Double`; an `Int` factorial overflows at 21.
    func testFact() throws {
        XCTAssertEqual(try call("FACT", [.number(5)]), .number(120))
        XCTAssertEqual(try call("FACT", [.number(0)]), .number(1))
        XCTAssertEqual(try call("FACT", [.number(-1)]), .error(.num))
        guard let big = value(try call("FACT", [.number(170)])) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(big, 7.257415615307999e306, accuracy: 1e295)
        XCTAssertEqual(try call("FACT", [.number(171)]), .error(.num))
        XCTAssertNotEqual(try call("FACT", [.number(21)]), .error(.num),
                          "21! is where an Int implementation would have overflowed")
    }

    /// `COMBIN` counts without repetition; `COMBINA` with. They are not the same function.
    func testCombinAndItsSibling() throws {
        XCTAssertEqual(try call("COMBIN", [.number(8), .number(2)]), .number(28))
        XCTAssertEqual(try call("COMBIN", [.number(4), .number(3)]), .number(4))
        XCTAssertEqual(try call("COMBINA", [.number(4), .number(3)]), .number(20))
        XCTAssertEqual(try call("COMBIN", [.number(3), .number(5)]), .error(.num))
    }

    func testSumXMY2() throws {
        let (xs, d1) = block("A", col([2, 3, 9, 1, 8, 7, 5]))
        let (ys, d2) = block("B", col([6, 5, 11, 7, 5, 4, 4]))
        XCTAssertEqual(try call("SUMXMY2", [xs, ys], d1.merging(d2) { a, _ in a }),
                       .number(79))
    }

    /// The function the conformance workbook's own `REDUCE` control depends on.
    func testSequence() throws {
        XCTAssertEqual(numbers(try call("SEQUENCE", [.number(4)])), [1, 2, 3, 4])
        XCTAssertEqual(numbers(try call("SEQUENCE", [.number(2), .number(3)])),
                       [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(numbers(try call("SEQUENCE", [.number(3), .number(1), .number(10),
                                                     .number(5)])), [10, 15, 20])
    }

    /// `REDUCE` over `SEQUENCE(n)` is n(n+1)/2 — the identity the conformance sheet checks
    /// against Excel, now evaluable here too.
    func testReduceOverSequenceMatchesTheConformanceIdentity() throws {
        let ast = FormulaAST.function("REDUCE", [
            .number(0), .function("SEQUENCE", [.number(100)]),
            .function("LAMBDA", [.namedRange("a"), .namedRange("v"),
                                 .add(.namedRange("a"), .namedRange("v"))]),
        ])
        XCTAssertEqual(try FormulaEvaluator.evaluate(
            ast, cells: Cells(), names: Names(), functions: .builtin), .number(5050))
    }

    func testMmult() throws {
        let (a, d1) = block("A", [n([1, 2]), n([3, 4])])
        let (b, d2) = block("C", [n([5, 6]), n([7, 8])])
        XCTAssertEqual(numbers(try call("MMULT", [a, b], d1.merging(d2) { x, _ in x })),
                       [19, 22, 43, 50])
    }

    func testMmultRefusesMismatchedInnerDimensions() throws {
        let (a, d1) = block("A", [n([1, 2, 3])])
        let (b, d2) = block("D", [n([1, 2])])
        XCTAssertEqual(try call("MMULT", [a, b], d1.merging(d2) { x, _ in x }), .error(.value))
    }

    func testMinverse() throws {
        let (m, data) = block("A", [n([4, 7]), n([2, 6])])
        guard let inverse = numbers(try call("MINVERSE", [m], data)) else {
            return XCTFail("expected an array")
        }
        // 1/10 × [6 -7; -2 4]
        XCTAssertEqual(inverse[0], 0.6, accuracy: 1e-12)
        XCTAssertEqual(inverse[1], -0.7, accuracy: 1e-12)
        XCTAssertEqual(inverse[2], -0.2, accuracy: 1e-12)
        XCTAssertEqual(inverse[3], 0.4, accuracy: 1e-12)
    }

    /// A singular matrix has no inverse, and `#VALUE!` says so rather than very large numbers.
    func testMinverseOfASingularMatrix() throws {
        let (m, data) = block("A", [n([1, 2]), n([2, 4])])
        XCTAssertEqual(try call("MINVERSE", [m], data), .error(.value))
    }

    /// Inverse times original is the identity — the property, not a published number.
    func testMinverseTimesOriginalIsTheIdentity() throws {
        let (m, data) = block("A", [n([4, 7]), n([2, 6])])
        let product = try call("MMULT", [m, .function("MINVERSE", [m])], data)
        guard let values = numbers(product) else { return XCTFail("expected an array") }
        XCTAssertEqual(values[0], 1, accuracy: 1e-12)
        XCTAssertEqual(values[1], 0, accuracy: 1e-12)
        XCTAssertEqual(values[2], 0, accuracy: 1e-12)
        XCTAssertEqual(values[3], 1, accuracy: 1e-12)
    }

    // MARK: - datetime

    /// The US and European conventions differ only at a month end, and the US rule is the
    /// conditional one.
    func testDays360() throws {
        XCTAssertEqual(try call("DAYS360", [day(2008, 1, 30), day(2008, 2, 1)]), .number(1))
        XCTAssertEqual(try call("DAYS360", [day(2008, 1, 1), day(2008, 12, 31)]), .number(360))
        // 31 January to 31 March: US pulls both to 30, European clamps both to 30.
        XCTAssertEqual(try call("DAYS360", [day(2008, 1, 31), day(2008, 3, 31)]), .number(60))
        XCTAssertEqual(try call("DAYS360", [day(2008, 1, 31), day(2008, 3, 31), .bool(true)]),
                       .number(60))
        // 30 January to 31 March: the start is *not* earlier than the 30th, so the US end
        // becomes the 30th of the same month rather than the 1st of the next.
        XCTAssertEqual(try call("DAYS360", [day(2008, 1, 30), day(2008, 3, 31)]), .number(60))
        XCTAssertEqual(try call("DAYS360", [day(2008, 1, 30), day(2008, 3, 31), .bool(true)]),
                       .number(60))
    }

    // MARK: - financial

    /// Microsoft: cash flows −120000, 39000, 30000, 21000, 37000, 46000 at 10% and 12% → 12.61%.
    func testMirr() throws {
        let (flows, data) = block("A", col([-120_000, 39_000, 30_000, 21_000, 37_000, 46_000]))
        guard let rate = value(try call("MIRR", [flows, .number(0.1), .number(0.12)], data))
        else { return XCTFail("expected a number") }
        XCTAssertEqual(rate, 0.126094, accuracy: 1e-5)
    }

    /// Microsoft: −10000 then four receipts on irregular dates at 9% → 2086.65.
    func testXnpv() throws {
        let (flows, d1) = block("A", col([-10_000, 2_750, 4_250, 3_250, 2_750]))
        var d2: [String: CellValue] = [:]
        let dates: [(Int, Int, Int)] = [(2008, 1, 1), (2008, 3, 1), (2008, 10, 30),
                                        (2009, 2, 15), (2009, 4, 1)]
        for (index, d) in dates.enumerated() {
            guard case .number(let serial) = try call(
                "DATE", [.number(Double(d.0)), .number(Double(d.1)), .number(Double(d.2))])
            else { return XCTFail("expected a serial") }
            d2["B\(index + 1)"] = .number(serial)
        }
        let dateRange = FormulaAST.cellRange(CellRange(from: "B1", to: "B5"))
        guard let npv = value(try call("XNPV", [.number(0.09), flows, dateRange],
                                       d1.merging(d2) { a, _ in a })) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(npv, 2086.6476, accuracy: 1e-3)
    }

    /// Microsoft: 96 periods, 800000 present, 2400000 future → 8.15% per period for RRI.
    func testRriAndPduration() throws {
        guard let rate = value(try call("RRI", [.number(96), .number(10_000),
                                                .number(11_000)])) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(rate, 0.0009933, accuracy: 1e-6)

        // PDURATION inverts it: at that rate, 10,000 reaches 11,000 in 96 periods.
        guard let periods = value(try call("PDURATION", [.number(rate), .number(10_000),
                                                         .number(11_000)])) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(periods, 96, accuracy: 1e-6)
    }

    /// Microsoft: 12% over 10 years on 2400, period 1, factor 2 → 480.
    func testDdb() throws {
        XCTAssertEqual(try call("DDB", [.number(2_400), .number(300), .number(10),
                                        .number(1)]), .number(480))
        // First day of a 3650-day life: the same asset, one day's worth.
        guard let day1 = value(try call("DDB", [.number(2_400), .number(300), .number(3_650),
                                                .number(1)])) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(day1, 1.3150684931506849, accuracy: 1e-9)
    }

    /// **The salvage floor.** An instalment never takes the asset below it, which is what
    /// makes the late periods smaller than the bare formula gives.
    func testDdbStopsAtSalvage() throws {
        var total = 0.0
        for period in 1...10 {
            guard let instalment = value(try call(
                "DDB", [.number(2_400), .number(300), .number(10), .number(Double(period))]))
            else { return XCTFail("expected a number") }
            total += instalment
        }
        XCTAssertLessThanOrEqual(total, 2_400 - 300 + 1e-9,
                                 "depreciation must not pass salvage")
    }

    /// Microsoft: 9% over 30 years on 125000, period 13 to 24, type 0 → −11135.23.
    func testCumipmt() throws {
        guard let interest = value(try call("CUMIPMT", [
            .number(0.09 / 12), .number(30 * 12), .number(125_000),
            .number(13), .number(24), .number(0),
        ])) else { return XCTFail("expected a number") }
        XCTAssertEqual(interest, -11_135.23213, accuracy: 1e-3)
    }

    /// The pair account for the whole payment: interest plus principal is what was paid.
    func testCumipmtAndCumprincAccountForEverything() throws {
        let arguments: [FormulaAST] = [.number(0.09 / 12), .number(30 * 12), .number(125_000),
                                       .number(13), .number(24), .number(0)]
        guard let interest = value(try call("CUMIPMT", arguments)),
              let principal = value(try call("CUMPRINC", arguments)) else {
            return XCTFail("expected numbers")
        }
        // Twelve level payments, and Excel's sign convention makes both negative.
        guard let payment = value(try call("PMT", [.number(0.09 / 12), .number(30 * 12),
                                                   .number(125_000)])) else {
            return XCTFail("expected a payment")
        }
        XCTAssertEqual(interest + principal, payment * 12, accuracy: 1e-6)
    }

    // MARK: - statistical

    /// **`CHISQ.DIST` is the left tail**, where `CHIDIST` is an alias of the right one.
    func testChisqDist() throws {
        guard let cumulative = value(try call("CHISQ.DIST", [.number(0.5), .number(1),
                                                             .bool(true)])) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(cumulative, 0.5204998778, accuracy: 1e-6)

        guard let rightTail = value(try call("CHISQ.DIST.RT", [.number(0.5), .number(1)]))
        else { return XCTFail("expected a number") }
        XCTAssertEqual(cumulative + rightTail, 1, accuracy: 1e-9,
                       "the two tails are complements, by construction")

        guard let density = value(try call("CHISQ.DIST", [.number(0.5), .number(1),
                                                          .bool(false)])) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(density, 0.4393912895, accuracy: 1e-6)
    }

    /// `T.DIST` is asked for any `x`; `T.DIST.RT` is defined for `x ≥ 0`. The negative half
    /// comes from symmetry.
    func testTDistAcrossZero() throws {
        guard let left = value(try call("T.DIST", [.number(-1.5), .number(10), .bool(true)])),
              let right = value(try call("T.DIST", [.number(1.5), .number(10), .bool(true)]))
        else { return XCTFail("expected numbers") }
        XCTAssertEqual(left + right, 1, accuracy: 1e-9, "symmetric about zero")
        XCTAssertEqual(right, 0.9177463, accuracy: 1e-5)
        XCTAssertEqual(try call("T.DIST", [.number(0), .number(10), .bool(true)]).self,
                       try call("T.DIST", [.number(0), .number(10), .bool(true)]))
    }

    func testFDist() throws {
        guard let cumulative = value(try call("F.DIST", [.number(15.2069), .number(6),
                                                         .number(4), .bool(true)])) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(cumulative, 0.99, accuracy: 1e-3)

        guard let density = value(try call("F.DIST", [.number(15.2069), .number(6),
                                                      .number(4), .bool(false)])) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(density, 0.0012237, accuracy: 1e-5)
    }

    /// `LINEST` returns **slope first**, which reads backwards and is what Excel does.
    func testLinest() throws {
        let (ys, d1) = block("A", col([2, 4, 6, 8]))
        let (xs, d2) = block("B", col([1, 2, 3, 4]))
        guard let coefficients = numbers(try call("LINEST", [ys, xs],
                                                  d1.merging(d2) { a, _ in a })) else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(coefficients[0], 2, accuracy: 1e-9, "slope first")
        XCTAssertEqual(coefficients[1], 0, accuracy: 1e-9, "then intercept")
    }

    /// An omitted `known_x` is 1, 2, 3 … — which is what lets a single column fit a line.
    func testLinestDefaultsItsXValues() throws {
        let (ys, data) = block("A", col([2, 4, 6, 8]))
        guard let coefficients = numbers(try call("LINEST", [ys], data)) else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(coefficients[0], 2, accuracy: 1e-9)
    }

    func testTrendExtrapolates() throws {
        let (ys, d1) = block("A", col([2, 4, 6, 8]))
        let (xs, d2) = block("B", col([1, 2, 3, 4]))
        let (newXs, d3) = block("C", col([5, 6]))
        let data = d1.merging(d2) { a, _ in a }.merging(d3) { a, _ in a }
        guard let projected = numbers(try call("TREND", [ys, xs, newXs], data)) else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(projected[0], 10, accuracy: 1e-9)
        XCTAssertEqual(projected[1], 12, accuracy: 1e-9)
    }

    /// `LOGEST` fits `y = b·mˣ`, so a doubling series gives m = 2.
    func testLogest() throws {
        let (ys, d1) = block("A", col([2, 4, 8, 16]))
        let (xs, d2) = block("B", col([1, 2, 3, 4]))
        guard let coefficients = numbers(try call("LOGEST", [ys, xs],
                                                  d1.merging(d2) { a, _ in a })) else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(coefficients[0], 2, accuracy: 1e-9, "the growth factor")
        XCTAssertEqual(coefficients[1], 1, accuracy: 1e-9, "and the base")
    }

    func testGrowthExtrapolates() throws {
        let (ys, d1) = block("A", col([2, 4, 8, 16]))
        let (xs, d2) = block("B", col([1, 2, 3, 4]))
        let (newXs, d3) = block("C", col([5]))
        let data = d1.merging(d2) { a, _ in a }.merging(d3) { a, _ in a }
        guard let projected = numbers(try call("GROWTH", [ys, xs, newXs], data)) else {
            return XCTFail("expected an array")
        }
        XCTAssertEqual(projected[0], 32, accuracy: 1e-6)
    }

    /// `LOGEST` and `GROWTH` need positive values, because the fit happens in logarithms.
    func testTheExponentialFitsNeedPositiveValues() throws {
        let (ys, d1) = block("A", col([2, -4, 8]))
        let (xs, d2) = block("B", col([1, 2, 3]))
        let data = d1.merging(d2) { a, _ in a }
        XCTAssertEqual(try call("LOGEST", [ys, xs], data), .error(.num))
        XCTAssertEqual(try call("GROWTH", [ys, xs], data), .error(.num))
    }
}
