import XCTest
import SwiftExcelCore
@testable import SwiftExcelFunctions

/// The nineteen `math` rows from the unreviewed bucket.
///
/// Expected values are Microsoft's published examples where they publish one, and the
/// definition where they do not. The cases worth writing down are the ones where Excel's
/// answer is not the obvious one — and there are more of those here than the category
/// suggests, because the rounding family disagrees with itself about negative numbers.
final class MathBucketTests: XCTestCase {

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
    func testTheCeilingsDisagreeAboutNegatives() throws {
        XCTAssertEqual(try call("CEILING.PRECISE", [.number(-4.5), .number(2)]), .number(-4))
        XCTAssertEqual(try call("ISO.CEILING", [.number(-4.5), .number(2)]), .number(-4))
        XCTAssertEqual(try call("CEILING.MATH", [.number(-4.5), .number(2)]), .number(-4))
        XCTAssertEqual(try call("CEILING.MATH", [.number(-4.5), .number(2), .number(1)]),
                       .number(-6))
    }

    /// The significance's sign never matters. "Precise" is what that is called.
    func testTheSignificanceSignIsIgnored() throws {
        XCTAssertEqual(try call("CEILING.PRECISE", [.number(-4.5), .number(-2)]), .number(-4))
        XCTAssertEqual(try call("FLOOR.PRECISE", [.number(-4.5), .number(-2)]), .number(-6))
    }

    func testTheFloors() throws {
        XCTAssertEqual(try call("FLOOR.MATH", [.number(6.7)]), .number(6))
        XCTAssertEqual(try call("FLOOR.MATH", [.number(-8.1), .number(2)]), .number(-10))
        XCTAssertEqual(try call("FLOOR.MATH", [.number(-5.5), .number(2), .number(1)]),
                       .number(-4))
    }

    /// Significance defaults to 1, and a significance of zero is zero rather than `#DIV/0!`.
    func testDefaultsAndZero() throws {
        XCTAssertEqual(try call("CEILING.MATH", [.number(24.3)]), .number(25))
        XCTAssertEqual(try call("CEILING.MATH", [.number(24.3), .number(0)]), .number(0))
    }

    /// `MROUND` goes to the nearest, and refuses a multiple of the opposite sign.
    func testMround() throws {
        XCTAssertEqual(try call("MROUND", [.number(10), .number(3)]), .number(9))
        XCTAssertEqual(try call("MROUND", [.number(-10), .number(-3)]), .number(-9))
        XCTAssertEqual(try call("MROUND", [.number(1.3), .number(0.2)]), .number(1.4000000000000001))
        XCTAssertEqual(try call("MROUND", [.number(5), .number(-2)]), .error(.num),
                       "no nearest multiple in the direction asked for")
    }

    /// A tie goes away from zero, which is Excel's rule everywhere it rounds.
    func testMroundTiesAwayFromZero() throws {
        XCTAssertEqual(try call("MROUND", [.number(7.5), .number(5)]), .number(10))
        XCTAssertEqual(try call("MROUND", [.number(-7.5), .number(-5)]), .number(-10))
    }

    // MARK: - Counting

    /// `COMBINA` counts with repetition, which is not what `COMBIN` counts.
    func testCombina() throws {
        XCTAssertEqual(try call("COMBINA", [.number(4), .number(3)]), .number(20))
        XCTAssertEqual(try call("COMBINA", [.number(10), .number(3)]), .number(220))
        XCTAssertEqual(try call("COMBINA", [.number(0), .number(0)]), .number(1),
                       "exactly one way to choose nothing")
        XCTAssertEqual(try call("COMBINA", [.number(0), .number(1)]), .error(.num))
    }

    /// `FACTDOUBLE(6)` is 48, not 720.
    func testFactDouble() throws {
        XCTAssertEqual(try call("FACTDOUBLE", [.number(6)]), .number(48))
        XCTAssertEqual(try call("FACTDOUBLE", [.number(7)]), .number(105))
        XCTAssertEqual(try call("FACTDOUBLE", [.number(0)]), .number(1))
        XCTAssertEqual(try call("FACTDOUBLE", [.number(-1)]), .number(1), "1 by convention")
        XCTAssertEqual(try call("FACTDOUBLE", [.number(-2)]), .error(.num))
    }

    /// Microsoft's own example: `MULTINOMIAL(2, 3, 4)` is 1260.
    func testMultinomial() throws {
        XCTAssertEqual(try call("MULTINOMIAL", [.number(2), .number(3), .number(4)]),
                       .number(1260))
        XCTAssertEqual(try call("MULTINOMIAL", [.number(5)]), .number(1))
        XCTAssertEqual(try call("MULTINOMIAL", [.number(-1)]), .error(.num))
    }

    /// Big enough that the factorials would overflow and the answer does not.
    func testMultinomialSurvivesLargeArguments() throws {
        guard case .number(let value) = try call(
            "MULTINOMIAL", [.number(100), .number(100)]) else {
            return XCTFail("expected a number")
        }
        XCTAssertTrue(value.isFinite, "200! does not fit in a Double and does not need to")
        XCTAssertEqual(value, 9.054851465610987e58, accuracy: 1e47)
    }

    // MARK: - Series and paired sums

    /// Microsoft's example: the first terms of cos(x) at x = π/4.
    func testSeriesSum() throws {
        let coefficients = Range("A", [1, -0.5, 0.041666667, -0.001388889].map(CellValue.number))
        guard case .number(let value) = try call(
            "SERIESSUM", [.number(Double.pi / 4), .number(0), .number(2), coefficients.ast],
            cells: Cells(data: coefficients.data)) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(value, 0.7071032, accuracy: 1e-6)
    }

    func testSumsOfSquares() throws {
        // Microsoft's published example, all seven pairs of it. Five of them sum to -97,
        // which is also correct and is not the number the documentation prints.
        let xs = Range("A", [2, 3, 9, 1, 8, 7, 5].map(CellValue.number))
        let ys = Range("B", [6, 5, 11, 7, 5, 4, 4].map(CellValue.number))
        let cells = Cells(data: xs.data.merging(ys.data) { a, _ in a })
        XCTAssertEqual(try call("SUMX2MY2", [xs.ast, ys.ast], cells: cells), .number(-55))
        XCTAssertEqual(try call("SUMX2PY2", [xs.ast, ys.ast], cells: cells), .number(521))
    }

    /// Arrays of different lengths are `#N/A`, not a sum over the shorter.
    func testPairedSumsRefuseMismatchedLengths() throws {
        let xs = Range("A", [1, 2, 3].map(CellValue.number))
        let ys = Range("B", [1, 2].map(CellValue.number))
        XCTAssertEqual(
            try call("SUMX2MY2", [xs.ast, ys.ast],
                     cells: Cells(data: xs.data.merging(ys.data) { a, _ in a })),
            .error(.na))
    }

    // MARK: - Roman numerals

    func testRoman() throws {
        XCTAssertEqual(try call("ROMAN", [.number(499)]), .text("CDXCIX"))
        XCTAssertEqual(try call("ROMAN", [.number(1999)]), .text("MCMXCIX"))
        XCTAssertEqual(try call("ROMAN", [.number(3999)]), .text("MMMCMXCIX"))
        XCTAssertEqual(try call("ROMAN", [.number(0)]), .text(""))
        XCTAssertEqual(try call("ROMAN", [.number(4000)]), .error(.value))
    }

    /// A concise form is refused rather than answered with the classic one.
    ///
    /// `ROMAN(499, 2)` is `XDIX` in Excel. Returning `CDXCIX` would be a different string
    /// that looks right, which is the failure this package exists to avoid.
    func testRomanRefusesTheFormsItCannotProduce() throws {
        XCTAssertEqual(try call("ROMAN", [.number(499), .number(0)]), .text("CDXCIX"))
        XCTAssertEqual(try call("ROMAN", [.number(499), .number(1)]), .error(.value))
    }

    func testArabic() throws {
        XCTAssertEqual(try call("ARABIC", [.text("LVII")]), .number(57))
        XCTAssertEqual(try call("ARABIC", [.text("MCMXCIX")]), .number(1999))
        XCTAssertEqual(try call("ARABIC", [.text("-IV")]), .number(-4))
        XCTAssertEqual(try call("ARABIC", [.text("")]), .number(0))
        XCTAssertEqual(try call("ARABIC", [.text("banana")]), .error(.value))
    }

    /// `ARABIC` reads forms `ROMAN` does not write, because a person may have written them.
    func testArabicIsMorePermissiveThanRoman() throws {
        XCTAssertEqual(try call("ARABIC", [.text("MIM")]), .number(1999))
    }

    func testRomanAndArabicRoundTrip() throws {
        for number in [1, 4, 9, 14, 40, 90, 400, 1066, 1999, 3999] {
            let numeral = try call("ROMAN", [.number(Double(number))])
            guard case .text(let text) = numeral else { return XCTFail("expected text") }
            XCTAssertEqual(try call("ARABIC", [.text(text)]), .number(Double(number)), text)
        }
    }

    // MARK: - Matrices

    func testMunit() throws {
        XCTAssertEqual(numbers(try call("MUNIT", [.number(3)])),
                       [1, 0, 0, 0, 1, 0, 0, 0, 1])
        XCTAssertEqual(try call("MUNIT", [.number(0)]), .error(.value))
    }

    func testMdeterm() throws {
        // Microsoft's example, whose determinant is 88.
        let (matrix, cells) = square([[1, 3, 8, 5], [1, 3, 6, 1], [1, 1, 1, 0], [7, 3, 10, 2]])
        guard case .number(let value) = try call("MDETERM", [matrix], cells: cells) else {
            return XCTFail("expected a number")
        }
        XCTAssertEqual(value, 88, accuracy: 1e-9)
    }

    /// The sign is the half that is easy to lose and impossible to see on a symmetric example.
    func testMdetermGetsTheSignRight() throws {
        let (swapped, cells) = square([[0, 1], [1, 0]])
        XCTAssertEqual(try call("MDETERM", [swapped], cells: cells), .number(-1))
    }

    /// A singular matrix is 0, not a very small number.
    func testMdetermOfASingularMatrix() throws {
        let (singular, cells) = square([[1, 2], [2, 4]])
        XCTAssertEqual(try call("MDETERM", [singular], cells: cells), .number(0))
    }

    func testMdetermNeedsASquare() throws {
        let (oblong, cells) = square([[1, 2, 3]])
        XCTAssertEqual(try call("MDETERM", [oblong], cells: cells), .error(.value))
    }

    // MARK: - PERCENTOF and RANDARRAY

    func testPercentOf() throws {
        let part = Range("A", [1, 2].map(CellValue.number))
        let whole = Range("B", [1, 2, 3, 4].map(CellValue.number))
        XCTAssertEqual(
            try call("PERCENTOF", [part.ast, whole.ast],
                     cells: Cells(data: part.data.merging(whole.data) { a, _ in a })),
            .number(0.3))

        let zero = Range("C", [CellValue.number(0)])
        XCTAssertEqual(
            try call("PERCENTOF", [part.ast, zero.ast],
                     cells: Cells(data: part.data.merging(zero.data) { a, _ in a })),
            .error(.div0))
    }

    /// Defaults make `RANDARRAY()` exactly `RAND()`.
    func testRandArrayDefaults() throws {
        XCTAssertEqual(numbers(try call("RANDARRAY", [], random: Fixed())), [0.5])
    }

    func testRandArrayShapeAndRange() throws {
        let result = try call(
            "RANDARRAY", [.number(2), .number(3), .number(10), .number(20)], random: Fixed())
        guard case .array(let matrix) = result else { return XCTFail("expected an array") }
        XCTAssertEqual(matrix.rows, 2)
        XCTAssertEqual(matrix.columns, 3)
        XCTAssertEqual(numbers(result), [15, 15, 15, 15, 15, 15])
    }

    func testRandArrayWholeNumbers() throws {
        let result = try call(
            "RANDARRAY", [.number(1), .number(1), .number(1), .number(6), .bool(true)],
            random: Fixed())
        XCTAssertEqual(numbers(result), [4])
    }

    /// Without an injected source there is no answer, rather than a different one each run.
    func testRandArrayNeedsASource() throws {
        XCTAssertEqual(try call("RANDARRAY", []), .error(.value))
    }

    // MARK: - AGGREGATE

    func testAggregateDispatchesToTheElevenItSharesWithSubtotal() throws {
        let data = Range("A", [1, 2, 3, 4].map(CellValue.number))
        let cells = Cells(data: data.data)
        XCTAssertEqual(try call("AGGREGATE", [.number(9), .number(0), data.ast], cells: cells),
                       .number(10))
        XCTAssertEqual(try call("AGGREGATE", [.number(1), .number(0), data.ast], cells: cells),
                       .number(2.5))
        XCTAssertEqual(try call("AGGREGATE", [.number(4), .number(0), data.ast], cells: cells),
                       .number(4))
    }

    func testAggregateReachesTheEightItAdds() throws {
        let data = Range("A", [1, 2, 3, 4].map(CellValue.number))
        let cells = Cells(data: data.data)
        XCTAssertEqual(try call("AGGREGATE", [.number(12), .number(0), data.ast], cells: cells),
                       .number(2.5))
        XCTAssertEqual(
            try call("AGGREGATE", [.number(14), .number(0), data.ast, .number(2)], cells: cells),
            .number(3), "second largest")
        XCTAssertEqual(
            try call("AGGREGATE", [.number(15), .number(0), data.ast, .number(2)], cells: cells),
            .number(2), "second smallest")
    }

    /// **The reason `AGGREGATE` exists**: it can be told to ignore errors in the data.
    func testAggregateIgnoresErrorsWhenAsked() throws {
        let withError = Range("A", [.number(1), .error(.na), .number(3)])
        let cells = Cells(data: withError.data)
        XCTAssertEqual(
            try call("AGGREGATE", [.number(9), .number(6), withError.ast], cells: cells),
            .number(4))
        XCTAssertEqual(
            try call("AGGREGATE", [.number(9), .number(0), withError.ast], cells: cells),
            .error(.na), "and reports them when not")
    }

    /// The rank is an argument, not a value to aggregate over.
    func testAggregateDoesNotCountTheRankAsData() throws {
        let data = Range("A", [10, 20, 30].map(CellValue.number))
        XCTAssertEqual(
            try call("AGGREGATE", [.number(14), .number(0), data.ast, .number(1)],
                     cells: Cells(data: data.data)),
            .number(30), "largest of three, not of four")
    }

    func testAggregateRefusesACodeItDoesNotKnow() throws {
        let data = Range("A", [CellValue.number(1)])
        let cells = Cells(data: data.data)
        XCTAssertEqual(try call("AGGREGATE", [.number(20), .number(0), data.ast], cells: cells),
                       .error(.value))
        XCTAssertEqual(try call("AGGREGATE", [.number(9), .number(9), data.ast], cells: cells),
                       .error(.value))
    }
}
