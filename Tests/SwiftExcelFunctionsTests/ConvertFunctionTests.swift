import Foundation
import SwiftExcelCore
import XCTest
@testable import SwiftExcelFunctions

/// `CONVERT(number, from_unit, to_unit)` — Excel's unit table.
///
/// ## What is being tested
///
/// A conversion table is data, and data is wrong in one of three ways: a factor is
/// mistyped, two units are filed under the wrong measure, or a rule about prefixes is
/// misapplied. Round-trips catch none of the first kind — a wrong factor round-trips
/// perfectly — so these assert **exact definitional equalities** instead: a foot is twelve
/// inches, a mile is 5,280 feet, a kibibyte is 1,024 bytes, water freezes at 32°F.
///
/// Those are relationships anyone can check without a table, which is the point.
final class ConvertFunctionTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    private func call(_ n: Double, _ from: String, _ to: String) throws -> CellValue {
        let function = try XCTUnwrap(registry.function(named: "CONVERT"), "CONVERT missing")
        return try function.evaluate([.number(n), .text(from), .text(to)])
    }

    private func value(_ n: Double, _ from: String, _ to: String) throws -> Double {
        let result = try call(n, from, to)
        guard case .number(let v) = result else {
            XCTFail("CONVERT(\(n), \(from), \(to)) returned \(result)"); return .nan
        }
        return v
    }

    private func assertConverts(_ n: Double, _ from: String, _ to: String,
                                _ expected: Double, accuracy: Double = 1e-9,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try value(n, from, to), expected, accuracy: accuracy,
                       "\(n) \(from) should be \(expected) \(to)", file: file, line: line)
    }

    // MARK: - Definitional equalities

    func testTheImperialDistancesAreExact() throws {
        try assertConverts(1, "ft", "in", 12, accuracy: 1e-12)
        try assertConverts(1, "yd", "ft", 3, accuracy: 1e-12)
        try assertConverts(1, "mi", "ft", 5280, accuracy: 1e-9)
        try assertConverts(1, "in", "m", 0.0254, accuracy: 1e-15)
    }

    func testTheMassesAreExact() throws {
        try assertConverts(1, "lbm", "ozm", 16, accuracy: 1e-12)
        try assertConverts(1, "stone", "lbm", 14, accuracy: 1e-12)
        try assertConverts(1, "ton", "lbm", 2000, accuracy: 1e-9)
    }

    func testTheTimesAreExact() throws {
        try assertConverts(1, "hr", "mn", 60, accuracy: 1e-12)
        try assertConverts(1, "day", "hr", 24, accuracy: 1e-12)
        try assertConverts(1, "yr", "day", 365.25, accuracy: 1e-9)
    }

    func testTheVolumesAreExact() throws {
        try assertConverts(1, "gal", "qt", 4, accuracy: 1e-12)
        try assertConverts(1, "cup", "tbs", 16, accuracy: 1e-12)
        try assertConverts(1, "m3", "l", 1000, accuracy: 1e-9)
    }

    func testInformationIsExact() throws {
        try assertConverts(1, "byte", "bit", 8, accuracy: 1e-12)
    }

    // MARK: - Temperature, which is affine rather than proportional

    /// A scale with an offset cannot be done by multiplication, and getting it wrong gives
    /// a number that is right only at zero.
    func testTemperatureCarriesItsOffset() throws {
        try assertConverts(0, "C", "F", 32, accuracy: 1e-9)
        try assertConverts(100, "C", "F", 212, accuracy: 1e-9)
        try assertConverts(0, "C", "K", 273.15, accuracy: 1e-9)
        try assertConverts(-40, "C", "F", -40, accuracy: 1e-9)
        try assertConverts(0, "K", "Rank", 0, accuracy: 1e-9)
        try assertConverts(491.67, "Rank", "F", 32, accuracy: 1e-6)
    }

    func testTemperatureRoundTrips() throws {
        for unit in ["C", "F", "K", "Rank", "Reau"] {
            let there = try value(37, "C", unit)
            let back = try value(there, unit, "C")
            XCTAssertEqual(back, 37, accuracy: 1e-9, "C → \(unit) → C must return 37")
        }
    }

    // MARK: - Prefixes

    func testDecimalPrefixesScaleTheUnit() throws {
        try assertConverts(1, "km", "m", 1000, accuracy: 1e-9)
        try assertConverts(1, "m", "cm", 100, accuracy: 1e-9)
        try assertConverts(1, "kg", "g", 1000, accuracy: 1e-9)
        try assertConverts(1, "Mg", "kg", 1000, accuracy: 1e-9)
    }

    /// A prefix on an area or a volume applies to the **linear** dimension, so it is squared
    /// or cubed. A square kilometre is a million square metres, not a thousand.
    func testAPrefixOnAnAreaOrVolumeIsRaisedToItsDimension() throws {
        try assertConverts(1, "km2", "m2", 1e6, accuracy: 1)
        try assertConverts(1, "km3", "m3", 1e9, accuracy: 1)
    }

    /// Binary prefixes belong to information units and to nothing else.
    func testBinaryPrefixesApplyToInformation() throws {
        try assertConverts(1, "kibyte", "byte", 1024, accuracy: 1e-9)
        try assertConverts(1, "Mibyte", "byte", 1048576, accuracy: 1e-6)
    }

    /// Excel allows a prefix on a temperature unit, which this originally refused.
    ///
    /// Measured: `CONVERT(1, "mK", "K")` is `0.001`. The reasoning for refusing — that a
    /// prefix and an offset do not compose — was sound and wrong, which is why it was put to
    /// Excel rather than left as a comment.
    func testAPrefixOnATemperatureUnitIsAllowed() throws {
        try assertConverts(1, "mK", "K", 0.001, accuracy: 1e-12)
        try assertConverts(1000, "mK", "K", 1, accuracy: 1e-12)
    }

    func testAPrefixOnANonMetricUnitIsRefused() throws {
        // There is no such thing as a kilo-foot in Excel's table.
        XCTAssertEqual(try call(1, "kft", "m"), .error(.na))
    }

    // MARK: - What Excel refuses

    func testConvertingBetweenMeasuresIsNotAvailable() throws {
        XCTAssertEqual(try call(1, "m", "g"), .error(.na), "a metre is not a mass")
        XCTAssertEqual(try call(1, "day", "m"), .error(.na))
    }

    func testAnUnknownUnitIsNotAvailable() throws {
        XCTAssertEqual(try call(1, "furlong", "m"), .error(.na))
        XCTAssertEqual(try call(1, "m", "furlong"), .error(.na))
    }

    /// Excel's units are case-sensitive: `K` is kelvin and `k` is the kilo prefix.
    func testUnitNamesAreCaseSensitive() throws {
        XCTAssertEqual(try call(1, "M", "m"), .error(.na), "M alone is a prefix, not a unit")
    }

    func testANonNumericValueIsAValueError() throws {
        let function = try XCTUnwrap(registry.function(named: "CONVERT"))
        XCTAssertEqual(try function.evaluate([.text("x"), .text("m"), .text("ft")]),
                       .error(.value))
    }

    func testAnErrorArgumentPropagates() throws {
        let function = try XCTUnwrap(registry.function(named: "CONVERT"))
        XCTAssertEqual(try function.evaluate([.error(.div0), .text("m"), .text("ft")]),
                       .error(.div0))
    }

    // MARK: - Round trips across every unit in a measure

    /// Catches a unit filed under the wrong measure, which a single conversion would not.
    func testEveryUnitRoundTripsWithinItsMeasure() throws {
        let families = [
            ["m", "mi", "Nmi", "in", "ft", "yd", "ang", "ell", "ly", "parsec", "pica"],
            ["g", "sg", "lbm", "u", "ozm", "grain", "cwt", "stone", "ton"],
            ["yr", "day", "hr", "mn", "sec"],
            ["Pa", "atm", "mmHg", "psi", "Torr"],
            ["N", "dyn", "lbf", "pond"],
            ["J", "e", "c", "cal", "eV", "Wh", "flb", "BTU"],
            ["HP", "PS", "W"],
            ["T", "ga"],
            ["l", "tsp", "tbs", "oz", "cup", "pt", "qt", "gal", "ft3", "in3", "m3"],
            ["m2", "ar", "ft2", "ha", "in2", "mi2", "yd2", "uk_acre", "us_acre"],
            ["bit", "byte"],
            ["m/s", "m/h", "mph", "kn"],
        ]
        for family in families {
            guard let base = family.first else { continue }
            for unit in family {
                let there = try value(3, base, unit)
                let back = try value(there, unit, base)
                XCTAssertEqual(back, 3, accuracy: 1e-6,
                               "\(base) → \(unit) → \(base) must return 3")
            }
        }
    }
}
