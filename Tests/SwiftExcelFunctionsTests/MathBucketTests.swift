import Foundation
import Testing
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// The nineteen `math` rows from the unreviewed bucket.
///
/// Expected values are Microsoft's published examples where they publish one, and the
/// definition where they do not. The cases worth writing down are the ones where Excel's
/// answer is not the obvious one — and there are more of those here than the category
/// suggests, because the rounding family disagrees with itself about negative numbers.
@Suite struct MathBucketTests {

    /// Cells backed by a dictionary, so a test can hand a function a real range.
    ///
    /// `FormulaAST` has no array-literal node — Excel writes `{1,2,3}` but this package's
    /// parser produces ranges, not literals — so an array argument reaches a function the way
    /// it does in a workbook: as a reference to cells that hold the values.
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
    /// Every draw is the midpoint, so a shape test reads as a shape test.
    private struct Fixed: RandomSource {
        func nextUniform() -> Double { 0.5 }
        func nextInteger(below bound: Int) -> Int { bound / 2 }
    }

    /// One range's worth of values, laid out down a column from the given letter.
    private struct Range {
        let ast: FormulaAST
        let data: [String: CellValue]

        init(_ column: String, _ values: [CellValue]) {
            var cells: [String: CellValue] = [:]
            for (offset, value) in values.enumerated() {
                cells["\(column)\(offset + 1)"] = value
            }
            data = cells
            ast = .cellRange(CellRange(from: "\(column)1", to: "\(column)\(values.count)"))
        }
    }

    private func call(_ name: String, _ args: [FormulaAST],
                      cells: Cells = Cells(),
                      random: (any RandomSource)? = nil) throws -> CellValue {
        try FormulaEvaluator.evaluate(
            .function(name, args), cells: cells, names: Names(),
            functions: .builtin, random: random)
    }

    private func numbers(_ value: CellValue) -> [Double]? {
        guard case .array(let m) = value else { return nil }
        return m.elements.map { if case .number(let n) = $0 { return n } else { return .nan } }
    }

    /// A square matrix laid out across columns A… , rows 1…
    private func square(_ rows: [[Double]]) -> (FormulaAST, Cells) {
        var data: [String: CellValue] = [:]
        let letters = ["A", "B", "C", "D", "E"]
        for (r, row) in rows.enumerated() {
            for (c, value) in row.enumerated() {
                data["\(letters[c])\(r + 1)"] = .number(value)
            }
        }
        let last = letters[(rows.first?.count ?? 1) - 1]
        return (.cellRange(CellRange(from: "A1", to: "\(last)\(rows.count)")), Cells(data: data))
    }

    // MARK: - Rounding to a multiple

    /// The four ceilings, and the negative number that separates them.
    ///
    /// `CEILING.PRECISE` and `ISO.CEILING` round a negative *up*, toward zero.
    /// `CEILING.MATH` agrees until a non-zero `mode` sends it away from zero instead. This is
    /// the whole of what `mode` does.
    @Test func theCeilingsDisagreeAboutNegatives() throws {
        #expect(try call("CEILING.PRECISE", [.number(-4.5), .number(2)]) == .number(-4))
        #expect(try call("ISO.CEILING", [.number(-4.5), .number(2)]) == .number(-4))
        #expect(try call("CEILING.MATH", [.number(-4.5), .number(2)]) == .number(-4))
        #expect(try call("CEILING.MATH", [.number(-4.5), .number(2), .number(1)]) == .number(-6))
    }

    /// The significance's sign never matters. "Precise" is what that is called.
    @Test func theSignificanceSignIsIgnored() throws {
        #expect(try call("CEILING.PRECISE", [.number(-4.5), .number(-2)]) == .number(-4))
        #expect(try call("FLOOR.PRECISE", [.number(-4.5), .number(-2)]) == .number(-6))
    }

    @Test func theFloors() throws {
        #expect(try call("FLOOR.MATH", [.number(6.7)]) == .number(6))
        #expect(try call("FLOOR.MATH", [.number(-8.1), .number(2)]) == .number(-10))
        #expect(try call("FLOOR.MATH", [.number(-5.5), .number(2), .number(1)]) == .number(-4))
    }

    /// Significance defaults to 1, and a significance of zero is zero rather than `#DIV/0!`.
    @Test func defaultsAndZero() throws {
        #expect(try call("CEILING.MATH", [.number(24.3)]) == .number(25))
        #expect(try call("CEILING.MATH", [.number(24.3), .number(0)]) == .number(0))
    }

    /// `MROUND` goes to the nearest, and refuses a multiple of the opposite sign.
    @Test func mround() throws {
        #expect(try call("MROUND", [.number(10), .number(3)]) == .number(9))
        #expect(try call("MROUND", [.number(-10), .number(-3)]) == .number(-9))
        #expect(try call("MROUND", [.number(1.3), .number(0.2)]) == .number(1.4000000000000001))
        #expect(try call("MROUND", [.number(5), .number(-2)]) == .error(.num), "no nearest multiple in the direction asked for")
    }

    /// A tie goes away from zero, which is Excel's rule everywhere it rounds.
    @Test func mroundTiesAwayFromZero() throws {
        #expect(try call("MROUND", [.number(7.5), .number(5)]) == .number(10))
        #expect(try call("MROUND", [.number(-7.5), .number(-5)]) == .number(-10))
    }

    // MARK: - Counting

    /// `COMBINA` counts with repetition, which is not what `COMBIN` counts.
    @Test func combina() throws {
        #expect(try call("COMBINA", [.number(4), .number(3)]) == .number(20))
        #expect(try call("COMBINA", [.number(10), .number(3)]) == .number(220))
        #expect(try call("COMBINA", [.number(0), .number(0)]) == .number(1), "exactly one way to choose nothing")
        #expect(try call("COMBINA", [.number(0), .number(1)]) == .error(.num))
    }

    /// `FACTDOUBLE(6)` is 48, not 720.
    @Test func factDouble() throws {
        #expect(try call("FACTDOUBLE", [.number(6)]) == .number(48))
        #expect(try call("FACTDOUBLE", [.number(7)]) == .number(105))
        #expect(try call("FACTDOUBLE", [.number(0)]) == .number(1))
        #expect(try call("FACTDOUBLE", [.number(-1)]) == .number(1), "1 by convention")
        #expect(try call("FACTDOUBLE", [.number(-2)]) == .error(.num))
    }

    /// Microsoft's own example: `MULTINOMIAL(2, 3, 4)` is 1260.
    @Test func multinomial() throws {
        #expect(try call("MULTINOMIAL", [.number(2), .number(3), .number(4)]) == .number(1260))
        #expect(try call("MULTINOMIAL", [.number(5)]) == .number(1))
        #expect(try call("MULTINOMIAL", [.number(-1)]) == .error(.num))
    }

    /// Big enough that the factorials would overflow and the answer does not.
    @Test func multinomialSurvivesLargeArguments() throws {
        guard case .number(let value) = try call(
            "MULTINOMIAL", [.number(100), .number(100)]) else {
            Issue.record("expected a number"); return
        }
        #expect(value.isFinite, "200! does not fit in a Double and does not need to")
        #expect(abs(value - 9.054851465610987e58) <= 1e47)
    }

    // MARK: - Series and paired sums

    /// Microsoft's example: the first terms of cos(x) at x = π/4.
    @Test func seriesSum() throws {
        let coefficients = Range("A", [1, -0.5, 0.041666667, -0.001388889].map(CellValue.number))
        guard case .number(let value) = try call(
            "SERIESSUM", [.number(Double.pi / 4), .number(0), .number(2), coefficients.ast],
            cells: Cells(data: coefficients.data)) else {
            Issue.record("expected a number"); return
        }
        #expect(abs(value - 0.7071032) <= 1e-6)
    }

    @Test func sumsOfSquares() throws {
        // Microsoft's published example, all seven pairs of it. Five of them sum to -97,
        // which is also correct and is not the number the documentation prints.
        let xs = Range("A", [2, 3, 9, 1, 8, 7, 5].map(CellValue.number))
        let ys = Range("B", [6, 5, 11, 7, 5, 4, 4].map(CellValue.number))
        let cells = Cells(data: xs.data.merging(ys.data) { a, _ in a })
        #expect(try call("SUMX2MY2", [xs.ast, ys.ast], cells: cells) == .number(-55))
        #expect(try call("SUMX2PY2", [xs.ast, ys.ast], cells: cells) == .number(521))
    }

    /// Arrays of different lengths are `#N/A`, not a sum over the shorter.
    @Test func pairedSumsRefuseMismatchedLengths() throws {
        let xs = Range("A", [1, 2, 3].map(CellValue.number))
        let ys = Range("B", [1, 2].map(CellValue.number))
        #expect(try call("SUMX2MY2", [xs.ast, ys.ast],
                     cells: Cells(data: xs.data.merging(ys.data) { a, _ in a })) == .error(.na))
    }

    // MARK: - Roman numerals

    @Test func roman() throws {
        #expect(try call("ROMAN", [.number(499)]) == .text("CDXCIX"))
        #expect(try call("ROMAN", [.number(1999)]) == .text("MCMXCIX"))
        #expect(try call("ROMAN", [.number(3999)]) == .text("MMMCMXCIX"))
        #expect(try call("ROMAN", [.number(0)]) == .text(""))
        #expect(try call("ROMAN", [.number(4000)]) == .error(.value))
    }

    /// A concise form is refused rather than answered with the classic one.
    ///
    /// `ROMAN(499, 2)` is `XDIX` in Excel. Returning `CDXCIX` would be a different string
    /// that looks right, which is the failure this package exists to avoid.
    @Test func romanRefusesTheFormsItCannotProduce() throws {
        #expect(try call("ROMAN", [.number(499), .number(0)]) == .text("CDXCIX"))
        #expect(try call("ROMAN", [.number(499), .number(1)]) == .error(.value))
    }

    @Test func arabic() throws {
        #expect(try call("ARABIC", [.text("LVII")]) == .number(57))
        #expect(try call("ARABIC", [.text("MCMXCIX")]) == .number(1999))
        #expect(try call("ARABIC", [.text("-IV")]) == .number(-4))
        #expect(try call("ARABIC", [.text("")]) == .number(0))
        #expect(try call("ARABIC", [.text("banana")]) == .error(.value))
    }

    /// `ARABIC` reads forms `ROMAN` does not write, because a person may have written them.
    @Test func arabicIsMorePermissiveThanRoman() throws {
        #expect(try call("ARABIC", [.text("MIM")]) == .number(1999))
    }

    @Test func romanAndArabicRoundTrip() throws {
        for number in [1, 4, 9, 14, 40, 90, 400, 1066, 1999, 3999] {
            let numeral = try call("ROMAN", [.number(Double(number))])
            guard case .text(let text) = numeral else { Issue.record("expected text"); return }
            #expect(try call("ARABIC", [.text(text)]) == .number(Double(number)), "\(text)")
        }
    }

    // MARK: - Matrices

    @Test func munit() throws {
        #expect(try numbers(call("MUNIT", [.number(3)]))?.isElementwiseEqual(to: [1, 0, 0, 0, 1, 0, 0, 0, 1]) == true)
        #expect(try call("MUNIT", [.number(0)]) == .error(.value))
    }

    @Test func mdeterm() throws {
        // Microsoft's example, whose determinant is 88.
        let (matrix, cells) = square([[1, 3, 8, 5], [1, 3, 6, 1], [1, 1, 1, 0], [7, 3, 10, 2]])
        guard case .number(let value) = try call("MDETERM", [matrix], cells: cells) else {
            Issue.record("expected a number"); return
        }
        #expect(abs(value - 88) <= 1e-9)
    }

    /// The sign is the half that is easy to lose and impossible to see on a symmetric example.
    @Test func mdetermGetsTheSignRight() throws {
        let (swapped, cells) = square([[0, 1], [1, 0]])
        #expect(try call("MDETERM", [swapped], cells: cells) == .number(-1))
    }

    /// A singular matrix is 0, not a very small number.
    @Test func mdetermOfASingularMatrix() throws {
        let (singular, cells) = square([[1, 2], [2, 4]])
        #expect(try call("MDETERM", [singular], cells: cells) == .number(0))
    }

    @Test func mdetermNeedsASquare() throws {
        let (oblong, cells) = square([[1, 2, 3]])
        #expect(try call("MDETERM", [oblong], cells: cells) == .error(.value))
    }

    // MARK: - PERCENTOF and RANDARRAY

    @Test func percentOf() throws {
        let part = Range("A", [1, 2].map(CellValue.number))
        let whole = Range("B", [1, 2, 3, 4].map(CellValue.number))
        #expect(try call("PERCENTOF", [part.ast, whole.ast],
                     cells: Cells(data: part.data.merging(whole.data) { a, _ in a })) == .number(0.3))

        let zero = Range("C", [CellValue.number(0)])
        #expect(try call("PERCENTOF", [part.ast, zero.ast],
                     cells: Cells(data: part.data.merging(zero.data) { a, _ in a })) == .error(.div0))
    }

    /// Defaults make `RANDARRAY()` exactly `RAND()`.
    @Test func randArrayDefaults() throws {
        #expect(try numbers(call("RANDARRAY", [], random: Fixed()))?.isElementwiseEqual(to: [0.5]) == true)
    }

    @Test func randArrayShapeAndRange() throws {
        let result = try call(
            "RANDARRAY", [.number(2), .number(3), .number(10), .number(20)], random: Fixed())
        guard case .array(let matrix) = result else { Issue.record("expected an array"); return }
        #expect(matrix.rows == 2)
        #expect(matrix.columns == 3)
        #expect(numbers(result)?.isElementwiseEqual(to: [15, 15, 15, 15, 15, 15]) == true)
    }

    @Test func randArrayWholeNumbers() throws {
        let result = try call(
            "RANDARRAY", [.number(1), .number(1), .number(1), .number(6), .bool(true)],
            random: Fixed())
        #expect(numbers(result)?.isElementwiseEqual(to: [4]) == true)
    }

    /// Without an injected source there is no answer, rather than a different one each run.
    @Test func randArrayNeedsASource() throws {
        #expect(try call("RANDARRAY", []) == .error(.value))
    }

    // MARK: - AGGREGATE

    @Test func aggregateDispatchesToTheElevenItSharesWithSubtotal() throws {
        let data = Range("A", [1, 2, 3, 4].map(CellValue.number))
        let cells = Cells(data: data.data)
        #expect(try call("AGGREGATE", [.number(9), .number(0), data.ast], cells: cells) == .number(10))
        #expect(try call("AGGREGATE", [.number(1), .number(0), data.ast], cells: cells) == .number(2.5))
        #expect(try call("AGGREGATE", [.number(4), .number(0), data.ast], cells: cells) == .number(4))
    }

    @Test func aggregateReachesTheEightItAdds() throws {
        let data = Range("A", [1, 2, 3, 4].map(CellValue.number))
        let cells = Cells(data: data.data)
        #expect(try call("AGGREGATE", [.number(12), .number(0), data.ast], cells: cells) == .number(2.5))
        #expect(try call("AGGREGATE", [.number(14), .number(0), data.ast, .number(2)], cells: cells) == .number(3), "second largest")
        #expect(try call("AGGREGATE", [.number(15), .number(0), data.ast, .number(2)], cells: cells) == .number(2), "second smallest")
    }

    /// **The reason `AGGREGATE` exists**: it can be told to ignore errors in the data.
    @Test func aggregateIgnoresErrorsWhenAsked() throws {
        let withError = Range("A", [.number(1), .error(.na), .number(3)])
        let cells = Cells(data: withError.data)
        #expect(try call("AGGREGATE", [.number(9), .number(6), withError.ast], cells: cells) == .number(4))
        #expect(try call("AGGREGATE", [.number(9), .number(0), withError.ast], cells: cells) == .error(.na), "and reports them when not")
    }

    /// The rank is an argument, not a value to aggregate over.
    @Test func aggregateDoesNotCountTheRankAsData() throws {
        let data = Range("A", [10, 20, 30].map(CellValue.number))
        #expect(try call("AGGREGATE", [.number(14), .number(0), data.ast, .number(1)],
                     cells: Cells(data: data.data)) == .number(30), "largest of three, not of four")
    }

    @Test func aggregateRefusesACodeItDoesNotKnow() throws {
        let data = Range("A", [CellValue.number(1)])
        let cells = Cells(data: data.data)
        #expect(try call("AGGREGATE", [.number(20), .number(0), data.ast], cells: cells) == .error(.value))
        #expect(try call("AGGREGATE", [.number(9), .number(9), data.ast], cells: cells) == .error(.value))
    }
}
