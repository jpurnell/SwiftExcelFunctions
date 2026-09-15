import Foundation
import SwiftExcelCore
import XCTest
@testable import SwiftExcelFunctions

/// The statistical bindings, checked against SciPy.
///
/// **Every expected value here was computed by SciPy or NumPy** over the two series below,
/// and none by this package. That is the rule ADR-001 sets for a binding: the arithmetic is
/// BusinessMath's question, and what these tests establish is that the Excel-facing name
/// reaches the right function with the arguments in Excel's order.
///
/// The order is the part that goes wrong silently. `RSQ` takes the y series first and
/// `CORREL` is symmetric, so a binding that normalises them agrees with SciPy on both and
/// is still wrong the moment `FORECAST` reuses the same reader.
final class StatisticalBindingTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    /// Ten values with a visible right tail, so skewness is not near zero.
    private let x: [Double] = [3, 4, 5, 2, 3, 4, 5, 6, 4, 7]

    /// A second series correlated with the first, but only loosely.
    private let y: [Double] = [9, 7, 5, 3, 1, 2, 4, 6, 8, 10]

    private func row(_ values: [Double]) -> CellValue {
        .array(CellMatrix(row: values.map { CellValue.number($0) }))
    }

    private func call(_ name: String, _ args: CellValue...) throws -> CellValue {
        guard let function = registry.function(named: name) else {
            XCTFail("\(name) is not registered"); return .error(.name)
        }
        return try function.evaluate(args)
    }

    private func number(_ name: String, _ args: CellValue...) throws -> Double {
        guard let function = registry.function(named: name) else {
            XCTFail("\(name) is not registered"); return .nan
        }
        guard case .number(let value) = try function.evaluate(args) else {
            XCTFail("\(name) did not answer with a number"); return .nan
        }
        return value
    }

    // MARK: - Shape

    /// `scipy.stats.skew(x, bias=False)` and `bias=True`.
    ///
    /// The pair differ by the `n/((n−1)(n−2))` correction, which is what `SKEW` applies and
    /// `SKEW.P` does not. Both are tested because binding one to the other's formula is the
    /// obvious mistake and neither answer looks wrong on its own.
    func testSkewnessMatchesSciPy() throws {
        XCTAssertEqual(try number("SKEW", row(x)), 0.35954307140679753, accuracy: 1e-12)
        XCTAssertEqual(try number("SKEW.P", row(x)), 0.30319333935414405, accuracy: 1e-12)
    }

    /// `scipy.stats.kurtosis(x, fisher=True, bias=False)` — excess, so normal is zero.
    func testKurtosisMatchesSciPy() throws {
        XCTAssertEqual(try number("KURT", row(x)), -0.15179963720841405, accuracy: 1e-12)
    }

    /// Each wants enough values to make its own correction, and says so.
    func testTooFewValuesIsADivisionRatherThanAnAnswer() throws {
        XCTAssertEqual(try call("SKEW", row([1, 2])), .error(.div0))
        XCTAssertEqual(try call("SKEW.P", row([1])), .error(.div0))
        XCTAssertEqual(try call("KURT", row([1, 2, 3])), .error(.div0))
        // No spread means dividing by a standard deviation of zero.
        XCTAssertEqual(try call("SKEW", row([4, 4, 4, 4])), .error(.div0))
    }

    // MARK: - Two series

    /// `numpy.corrcoef(x, y)[0,1]`, and its square.
    func testCorrelationMatchesNumPy() throws {
        XCTAssertEqual(try number("CORREL", row(x), row(y)), 0.4543041723549836, accuracy: 1e-12)
        XCTAssertEqual(try number("PEARSON", row(x), row(y)), 0.4543041723549836, accuracy: 1e-12)
        XCTAssertEqual(try number("RSQ", row(y), row(x)), 0.20639228101914664, accuracy: 1e-12)
    }

    /// `scipy.stats.linregress(x, y)` read at 5.5.
    ///
    /// The argument order is the whole test: Excel writes `FORECAST(x, known_y, known_x)`
    /// with the **y series in the middle**, and BusinessMath's regression takes `(x, y)`.
    /// A binding that passes them straight through fits x on y and answers 3.05 rather
    /// than 6.60 — a plausible number, in range, from the wrong line.
    func testForecastPutsTheSeriesInExcelsOrder() throws {
        XCTAssertEqual(try number("FORECAST", .number(5.5), row(y), row(x)),
                       6.604477611940299, accuracy: 1e-10)
        XCTAssertEqual(try number("FORECAST.LINEAR", .number(5.5), row(y), row(x)),
                       6.604477611940299, accuracy: 1e-10)
    }

    /// Series of different lengths is `#N/A`, not a correlation over the shorter one.
    func testMismatchedSeriesAreRefused() throws {
        XCTAssertEqual(try call("CORREL", row(x), row([1, 2, 3])), .error(.na))
        XCTAssertEqual(try call("FORECAST", .number(1), row(y), row([1, 2, 3])), .error(.na))
    }

    // MARK: - Dispersion and means

    /// Against NumPy and SciPy: `sum((x-mean)**2)`, `gmean`, `hmean`.
    func testTheMeansMatchSciPy() throws {
        XCTAssertEqual(try number("DEVSQ", row(x)), 20.1, accuracy: 1e-12)
        XCTAssertEqual(try number("GEOMEAN", row(x)), 4.057552780441772, accuracy: 1e-12)
        XCTAssertEqual(try number("HARMEAN", row(x)), 3.807796917497733, accuracy: 1e-12)
    }

    /// A non-positive value has no geometric mean, and Excel says so.
    func testTheGeometricMeanNeedsPositiveValues() throws {
        XCTAssertEqual(try call("GEOMEAN", row([1, 2, 0])), .error(.num))
        XCTAssertEqual(try call("GEOMEAN", row([1, 2, -3])), .error(.num))
        XCTAssertEqual(try call("HARMEAN", row([1, 2, 0])), .error(.num))
    }

    /// Microsoft's published example: 1.3333… standard deviations.
    func testStandardizeMatchesThePublishedExample() throws {
        XCTAssertEqual(try number("STANDARDIZE", .number(42), .number(40), .number(1.5)),
                       1.3333333333333333, accuracy: 1e-12)
        XCTAssertEqual(try call("STANDARDIZE", .number(42), .number(40), .number(0)), .error(.num))
    }

    // MARK: - Fisher

    /// `numpy.arctanh(0.75)`, and the round trip back.
    func testFisherIsTheInverseHyperbolicTangent() throws {
        XCTAssertEqual(try number("FISHER", .number(0.75)), 0.9729550745276566, accuracy: 1e-12)
        XCTAssertEqual(try number("FISHERINV", .number(0.9729550745276566)), 0.75, accuracy: 1e-12)
        // The endpoints transform to infinity, which is #NUM! rather than a number.
        XCTAssertEqual(try call("FISHER", .number(1)), .error(.num))
        XCTAssertEqual(try call("FISHER", .number(-1)), .error(.num))
    }

    /// Microsoft's published example, and the difference from `COMBIN`.
    func testPermutCountsOrderedArrangements() throws {
        XCTAssertEqual(try number("PERMUT", .number(100), .number(3)), 970_200)
        XCTAssertEqual(try number("PERMUT", .number(4), .number(2)), 12)
        XCTAssertEqual(try call("PERMUT", .number(2), .number(4)), .error(.num))
    }

    // MARK: - The two inverses

    /// `scipy.stats.f.ppf` and `t.ppf` — the **left** tail, which is what distinguishes
    /// these from the `.RT` and `.2T` spellings already registered.
    func testTheLeftTailedInversesMatchSciPy() throws {
        XCTAssertEqual(try number("F.INV", .number(0.1), .number(6), .number(4)),
                       0.3143899883217684, accuracy: 1e-8)
        XCTAssertEqual(try number("T.INV", .number(0.75), .number(2)),
                       0.8164965809277261, accuracy: 1e-8)
        // Signed, unlike T.INV.2T: below the median the answer is negative.
        XCTAssertLessThan(try number("T.INV", .number(0.25), .number(2)), 0)
    }

    /// `t.ppf(0.975, 49) / sqrt(50)` for a standard deviation of 1.
    func testConfidenceTMatchesSciPy() throws {
        XCTAssertEqual(try number("CONFIDENCE.T", .number(0.05), .number(1), .number(50)),
                       0.28419685549572987, accuracy: 1e-8)
        // One observation leaves no degrees of freedom.
        XCTAssertEqual(try call("CONFIDENCE.T", .number(0.05), .number(1), .number(1)),
                       .error(.div0))
    }

    // MARK: - AVERAGEIFS

    /// The most-called name the corpus sweep found unanswerable: 35 calls.
    func testAverageifsAveragesTheRowsMeetingEveryCriterion() throws {
        let amounts = row([10, 20, 30, 40])
        let region = CellValue.array(CellMatrix(row: [.text("N"), .text("S"), .text("N"), .text("S")]))
        let quarter = row([1, 1, 2, 2])

        XCTAssertEqual(try number("AVERAGEIFS", amounts, region, .text("N")), 20)
        XCTAssertEqual(try number("AVERAGEIFS", amounts, region, .text("N"), quarter, .number(2)), 30)
        XCTAssertEqual(try number("AVERAGEIFS", amounts, quarter, .text(">1")), 35)
    }

    /// No matching row is `#DIV/0!` — where `MAXIFS`, on the same shape, answers zero.
    func testAverageifsRefusesToAverageNothing() throws {
        let amounts = row([10, 20])
        let region = CellValue.array(CellMatrix(row: [.text("N"), .text("S")]))
        XCTAssertEqual(try call("AVERAGEIFS", amounts, region, .text("E")), .error(.div0))
    }

    /// The value range leads, which is `SUMIFS`'s order and not `AVERAGEIF`'s.
    ///
    /// Written as a test because the two functions differ by one argument position and a
    /// reader coming from `AVERAGEIF` will assume they do not.
    func testTheValueRangeComesFirst() throws {
        let amounts = row([10, 20, 30, 40])
        let region = CellValue.array(CellMatrix(row: [.text("N"), .text("S"), .text("N"), .text("S")]))
        // AVERAGEIF is (criteria_range, criterion, [value_range]).
        XCTAssertEqual(try number("AVERAGEIF", region, .text("N"), amounts), 20)
        // AVERAGEIFS is (value_range, criteria_range, criterion).
        XCTAssertEqual(try number("AVERAGEIFS", amounts, region, .text("N")), 20)
        // An unpaired criterion is refused rather than ignored.
        XCTAssertEqual(try call("AVERAGEIFS", amounts, region), .error(.value))
    }

    // MARK: - Registration

    /// Every name this tranche claims, including the two that are pure aliases.
    ///
    /// `MODE` and `GAMMALN` were implemented all along under their dotted names, and the
    /// corpus calls the plain ones. A `#NAME?` for the sake of a full stop.
    func testTheNamesResolve() throws {
        for name in ["SKEW", "SKEW.P", "KURT", "CORREL", "PEARSON", "RSQ", "FORECAST",
                     "FORECAST.LINEAR", "DEVSQ", "GEOMEAN", "HARMEAN", "STANDARDIZE",
                     "FISHER", "FISHERINV", "PERMUT", "F.INV", "T.INV", "CONFIDENCE.T",
                     "AVERAGEIFS", "MODE", "GAMMALN"] {
            XCTAssertNotNil(registry.function(named: name), name)
        }
        // The aliases answer the same thing their dotted names do.
        XCTAssertEqual(try call("MODE", row([1, 2, 2, 3])), try call("MODE.SNGL", row([1, 2, 2, 3])))
        XCTAssertEqual(try call("GAMMALN", .number(4)), try call("GAMMALN.PRECISE", .number(4)))
    }
}
