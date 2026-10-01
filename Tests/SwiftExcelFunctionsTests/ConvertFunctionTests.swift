import Foundation
import SwiftExcelCore
import Foundation
import Testing
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
@Suite struct ConvertFunctionTests {

    private let registry = FunctionRegistry.builtin

    private func call(_ n: Double, _ from: String, _ to: String) throws -> CellValue {
        let function = try #require(registry.function(named: "CONVERT"), "CONVERT missing")
        return try function.evaluate([.number(n), .text(from), .text(to)])
    }

    private func value(_ n: Double, _ from: String, _ to: String) throws -> Double {
        let result = try call(n, from, to)
        guard case .number(let v) = result else {
            Issue.record("CONVERT(\(n), \(from), \(to)) returned \(result)"); return .nan
        }
        return v
    }


    // MARK: - Definitional equalities

    @Test func theImperialDistancesAreExact() throws {
        #expect(try value(1, "ft", "in").isClose(to: 12, within: 1e-12), "\(1) \("ft") should be \(12) \("in")")
        #expect(try value(1, "yd", "ft").isClose(to: 3, within: 1e-12), "\(1) \("yd") should be \(3) \("ft")")
        #expect(try value(1, "mi", "ft").isClose(to: 5280, within: 1e-9), "\(1) \("mi") should be \(5280) \("ft")")
        #expect(try value(1, "in", "m").isClose(to: 0.0254, within: 1e-15), "\(1) \("in") should be \(0.0254) \("m")")
    }

    @Test func theMassesAreExact() throws {
        #expect(try value(1, "lbm", "ozm").isClose(to: 16, within: 1e-12), "\(1) \("lbm") should be \(16) \("ozm")")
        #expect(try value(1, "stone", "lbm").isClose(to: 14, within: 1e-12), "\(1) \("stone") should be \(14) \("lbm")")
        #expect(try value(1, "ton", "lbm").isClose(to: 2000, within: 1e-9), "\(1) \("ton") should be \(2000) \("lbm")")
    }

    @Test func theTimesAreExact() throws {
        #expect(try value(1, "hr", "mn").isClose(to: 60, within: 1e-12), "\(1) \("hr") should be \(60) \("mn")")
        #expect(try value(1, "day", "hr").isClose(to: 24, within: 1e-12), "\(1) \("day") should be \(24) \("hr")")
        #expect(try value(1, "yr", "day").isClose(to: 365.25, within: 1e-9), "\(1) \("yr") should be \(365.25) \("day")")
    }

    @Test func theVolumesAreExact() throws {
        #expect(try value(1, "gal", "qt").isClose(to: 4, within: 1e-12), "\(1) \("gal") should be \(4) \("qt")")
        #expect(try value(1, "cup", "tbs").isClose(to: 16, within: 1e-12), "\(1) \("cup") should be \(16) \("tbs")")
        #expect(try value(1, "m3", "l").isClose(to: 1000, within: 1e-9), "\(1) \("m3") should be \(1000) \("l")")
    }

    @Test func informationIsExact() throws {
        #expect(try value(1, "byte", "bit").isClose(to: 8, within: 1e-12), "\(1) \("byte") should be \(8) \("bit")")
    }

    // MARK: - Temperature, which is affine rather than proportional

    /// A scale with an offset cannot be done by multiplication, and getting it wrong gives
    /// a number that is right only at zero.
    @Test func temperatureCarriesItsOffset() throws {
        #expect(try value(0, "C", "F").isClose(to: 32, within: 1e-9), "\(0) \("C") should be \(32) \("F")")
        #expect(try value(100, "C", "F").isClose(to: 212, within: 1e-9), "\(100) \("C") should be \(212) \("F")")
        #expect(try value(0, "C", "K").isClose(to: 273.15, within: 1e-9), "\(0) \("C") should be \(273.15) \("K")")
        #expect(try value(-40, "C", "F").isClose(to: -40, within: 1e-9), "\(-40) \("C") should be \(-40) \("F")")
        #expect(try value(0, "K", "Rank").isClose(to: 0, within: 1e-9), "\(0) \("K") should be \(0) \("Rank")")
        #expect(try value(491.67, "Rank", "F").isClose(to: 32, within: 1e-6), "\(491.67) \("Rank") should be \(32) \("F")")
    }

    @Test func temperatureRoundTrips() throws {
        for unit in ["C", "F", "K", "Rank", "Reau"] {
            let there = try value(37, "C", unit)
            let back = try value(there, unit, "C")
            #expect(abs(back - 37) <= 1e-9, "C → \(unit) → C must return 37")
        }
    }

    // MARK: - Prefixes

    @Test func decimalPrefixesScaleTheUnit() throws {
        #expect(try value(1, "km", "m").isClose(to: 1000, within: 1e-9), "\(1) \("km") should be \(1000) \("m")")
        #expect(try value(1, "m", "cm").isClose(to: 100, within: 1e-9), "\(1) \("m") should be \(100) \("cm")")
        #expect(try value(1, "kg", "g").isClose(to: 1000, within: 1e-9), "\(1) \("kg") should be \(1000) \("g")")
        #expect(try value(1, "Mg", "kg").isClose(to: 1000, within: 1e-9), "\(1) \("Mg") should be \(1000) \("kg")")
    }

    /// A prefix on an area or a volume applies to the **linear** dimension, so it is squared
    /// or cubed. A square kilometre is a million square metres, not a thousand.
    @Test func aPrefixOnAnAreaOrVolumeIsRaisedToItsDimension() throws {
        #expect(try value(1, "km2", "m2").isClose(to: 1e6, within: 1), "\(1) \("km2") should be \(1e6) \("m2")")
        #expect(try value(1, "km3", "m3").isClose(to: 1e9, within: 1), "\(1) \("km3") should be \(1e9) \("m3")")
    }

    /// Binary prefixes belong to information units and to nothing else.
    @Test func binaryPrefixesApplyToInformation() throws {
        #expect(try value(1, "kibyte", "byte").isClose(to: 1024, within: 1e-9), "\(1) \("kibyte") should be \(1024) \("byte")")
        #expect(try value(1, "Mibyte", "byte").isClose(to: 1048576, within: 1e-6), "\(1) \("Mibyte") should be \(1048576) \("byte")")
    }

    /// Excel allows a prefix on a temperature unit, which this originally refused.
    ///
    /// Measured: `CONVERT(1, "mK", "K")` is `0.001`. The reasoning for refusing — that a
    /// prefix and an offset do not compose — was sound and wrong, which is why it was put to
    /// Excel rather than left as a comment.
    @Test func aPrefixOnATemperatureUnitIsAllowed() throws {
        #expect(try value(1, "mK", "K").isClose(to: 0.001, within: 1e-12), "\(1) \("mK") should be \(0.001) \("K")")
        #expect(try value(1000, "mK", "K").isClose(to: 1, within: 1e-12), "\(1000) \("mK") should be \(1) \("K")")
    }

    /// …but only on the absolute scale, which took a second measurement to learn.
    ///
    /// Refusing prefixes everywhere was wrong; allowing them everywhere was also wrong.
    /// Excel answers `CONVERT(1, "mC", "C")` with `#N/A` and `CONVERT(1, "mK", "K")` with
    /// `0.001`. A prefix scales a magnitude, and only an absolute scale has one.
    @Test func aPrefixOnAnOffsetTemperatureScaleIsRefused() throws {
        #expect(try call(1, "mC", "C") == .error(.na))
        #expect(try call(1000, "mC", "C") == .error(.na))
        #expect(try call(1, "mF", "F") == .error(.na))
    }

    @Test func aPrefixOnANonMetricUnitIsRefused() throws {
        // There is no such thing as a kilo-foot in Excel's table.
        #expect(try call(1, "kft", "m") == .error(.na))
    }

    // MARK: - What Excel refuses

    @Test func convertingBetweenMeasuresIsNotAvailable() throws {
        #expect(try call(1, "m", "g") == .error(.na), "a metre is not a mass")
        #expect(try call(1, "day", "m") == .error(.na))
    }

    @Test func anUnknownUnitIsNotAvailable() throws {
        #expect(try call(1, "furlong", "m") == .error(.na))
        #expect(try call(1, "m", "furlong") == .error(.na))
    }

    /// Excel's units are case-sensitive: `K` is kelvin and `k` is the kilo prefix.
    @Test func unitNamesAreCaseSensitive() throws {
        #expect(try call(1, "M", "m") == .error(.na), "M alone is a prefix, not a unit")
    }

    @Test func aNonNumericValueIsAValueError() throws {
        let function = try #require(registry.function(named: "CONVERT"))
        #expect(try function.evaluate([.text("x"), .text("m"), .text("ft")]) == .error(.value))
    }

    @Test func anErrorArgumentPropagates() throws {
        let function = try #require(registry.function(named: "CONVERT"))
        #expect(try function.evaluate([.error(.div0), .text("m"), .text("ft")]) == .error(.div0))
    }

    // MARK: - Round trips across every unit in a measure

    /// Catches a unit filed under the wrong measure, which a single conversion would not.
    @Test func everyUnitRoundTripsWithinItsMeasure() throws {
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
                #expect(abs(back - 3) <= 1e-6, "\(base) → \(unit) → \(base) must return 3")
            }
        }
    }
}
