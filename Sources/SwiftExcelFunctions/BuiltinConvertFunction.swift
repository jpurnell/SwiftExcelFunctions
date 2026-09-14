import Foundation
import SwiftExcelCore

/// `CONVERT(number, from_unit, to_unit)` — Excel's unit table.
///
/// ## This is data, not a computation
///
/// The arithmetic is one multiplication. Everything that can go wrong is in the table: a
/// mistyped factor, a unit filed under the wrong measure, or a rule about prefixes applied
/// where it does not belong. So the factors here are **definitional wherever a definition
/// exists** — a foot is exactly 0.3048 m, a pound is exactly 0.45359237 kg — rather than
/// rounded decimals copied from a chart.
///
/// ## Three rules that are easy to get wrong
///
/// **A name is looked up whole before any prefix is considered.** `mn` is a minute, not a
/// milli-newton; `cwt` is a hundredweight, not a centi-watt; `e` is an erg while also being
/// the deka prefix. Stripping prefixes first would quietly redefine all three.
///
/// **A prefix on an area or a volume is raised to its dimension.** A square kilometre is
/// 10⁶ square metres, not 10³, because the prefix scales the length the unit is built from.
///
/// **Temperature is affine.** Every other conversion is a ratio; these have an offset, and a
/// scale factor alone gives an answer that is correct only at zero.
///
/// ## Provenance
///
/// The unit list and its factors come from Microsoft's documentation. No workbook in the
/// 2,240-file corpus calls `CONVERT`, so none of this was measured against Excel. Two
/// choices are inferred rather than documented and are noted where they are made: prefixes
/// are refused on temperature, and unknown units give `#N/A`.
public enum BuiltinConvertFunction {

    /// The function, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [convert]

    // MARK: - The table

    /// What a unit measures. Conversion happens within one of these and never across.
    private enum Measure: Sendable {
        case mass, distance, time, pressure, force, energy, power
        case magnetism, temperature, volume, area, information, speed
    }

    /// Which prefixes a unit accepts.
    private enum Prefixing: Sendable {
        /// None — the imperial and customary units.
        case none
        /// The decimal prefixes, which is what "metric" means here.
        case decimal
        /// Decimal and binary both, which only the information units take.
        case binary
    }

    /// One unit: what it measures, and how many base units it is.
    private struct Unit: Sendable {
        let measure: Measure
        /// In base units — grams, metres, seconds, pascals, newtons, joules, watts,
        /// teslas, litres, square metres, bits, or metres per second.
        let factor: Double
        /// 1, 2 or 3 — the power a prefix is raised to for this unit.
        let dimension: Int
        let prefixing: Prefixing

        init(_ measure: Measure, _ factor: Double,
             dimension: Int = 1, prefixing: Prefixing = .none) {
            self.measure = measure
            self.factor = factor
            self.dimension = dimension
            self.prefixing = prefixing
        }
    }

    /// Exact by definition, and reused so the derived units cannot drift from them.
    private static let inch = 0.0254
    private static let foot = 0.3048
    private static let pound = 453.59237
    private static let lightYear = 9.46073047258080e15

    private static let units: [String: Unit] = {
        var table: [String: Unit] = [:]
        func put(_ names: [String], _ unit: Unit) { for name in names { table[name] = unit } }

        // --- Mass, in grams -------------------------------------------------------
        put(["g"], Unit(.mass, 1, prefixing: .decimal))
        put(["sg"], Unit(.mass, 14593.9029372064))
        put(["lbm"], Unit(.mass, pound))
        put(["u"], Unit(.mass, 1.66053886e-24, prefixing: .decimal))
        put(["ozm"], Unit(.mass, pound / 16))
        put(["grain"], Unit(.mass, pound / 7000))
        put(["cwt", "shweight"], Unit(.mass, pound * 100))
        put(["uk_cwt", "lcwt", "hweight"], Unit(.mass, pound * 112))
        put(["stone"], Unit(.mass, pound * 14))
        put(["ton"], Unit(.mass, pound * 2000))
        put(["uk_ton", "LTON", "brton"], Unit(.mass, pound * 2240))

        // --- Distance, in metres --------------------------------------------------
        put(["m"], Unit(.distance, 1, prefixing: .decimal))
        put(["mi"], Unit(.distance, foot * 5280))
        put(["Nmi"], Unit(.distance, 1852))
        put(["in"], Unit(.distance, inch))
        put(["ft"], Unit(.distance, foot))
        put(["yd"], Unit(.distance, foot * 3))
        put(["ang"], Unit(.distance, 1e-10, prefixing: .decimal))
        put(["ell"], Unit(.distance, 1.143))
        put(["ly"], Unit(.distance, lightYear))
        put(["parsec", "pc"], Unit(.distance, 3.08567758128155e16))
        // A PostScript point is 1/72 inch; a printer's pica is 1/6 inch. Excel spells the
        // first `Picapt` and the second `pica`, and the two differ by a factor of twelve.
        put(["Picapt", "Pica"], Unit(.distance, inch / 72))
        put(["pica"], Unit(.distance, inch / 6))
        put(["survey_mi"], Unit(.distance, 1609.347218694437))

        // --- Time, in seconds -----------------------------------------------------
        put(["yr"], Unit(.time, 31557600))
        put(["day", "d"], Unit(.time, 86400))
        put(["hr"], Unit(.time, 3600))
        put(["mn", "min"], Unit(.time, 60))
        put(["sec", "s"], Unit(.time, 1, prefixing: .decimal))

        // --- Pressure, in pascals -------------------------------------------------
        put(["Pa", "p"], Unit(.pressure, 1, prefixing: .decimal))
        put(["atm", "at"], Unit(.pressure, 101325, prefixing: .decimal))
        put(["mmHg"], Unit(.pressure, 133.322, prefixing: .decimal))
        put(["psi"], Unit(.pressure, 6894.75729316836))
        put(["Torr"], Unit(.pressure, 101325.0 / 760))

        // --- Force, in newtons ----------------------------------------------------
        put(["N"], Unit(.force, 1, prefixing: .decimal))
        put(["dyn", "dy"], Unit(.force, 1e-5, prefixing: .decimal))
        put(["lbf"], Unit(.force, 4.4482216152605))
        put(["pond"], Unit(.force, 9.80665e-3, prefixing: .decimal))

        // --- Energy, in joules ----------------------------------------------------
        put(["J"], Unit(.energy, 1, prefixing: .decimal))
        put(["e"], Unit(.energy, 1e-7, prefixing: .decimal))
        // `c` is the thermodynamic calorie and `cal` the International Table calorie.
        // They differ in the fourth digit, which is exactly the kind of difference that
        // survives a plausibility check.
        put(["c"], Unit(.energy, 4.184, prefixing: .decimal))
        put(["cal"], Unit(.energy, 4.1868, prefixing: .decimal))
        put(["eV", "ev"], Unit(.energy, 1.60217646e-19, prefixing: .decimal))
        put(["HPh", "hh"], Unit(.energy, 745.699871582270 * 3600))
        put(["Wh", "wh"], Unit(.energy, 3600, prefixing: .decimal))
        put(["flb"], Unit(.energy, 1.3558179483314))
        put(["BTU", "btu"], Unit(.energy, 1055.05585262))

        // --- Power, in watts ------------------------------------------------------
        put(["HP", "h"], Unit(.power, 745.699871582270))
        put(["PS"], Unit(.power, 735.49875))
        put(["W", "w"], Unit(.power, 1, prefixing: .decimal))

        // --- Magnetism, in teslas -------------------------------------------------
        put(["T"], Unit(.magnetism, 1, prefixing: .decimal))
        put(["ga"], Unit(.magnetism, 1e-4, prefixing: .decimal))

        // --- Temperature ----------------------------------------------------------
        // Present so the measure is known; the factor is unused, because these convert
        // through `kelvin(_:from:)` rather than by multiplication.
        put(["C", "cel", "F", "fah", "K", "kel", "Rank", "Reau"], Unit(.temperature, 1))

        // --- Volume, in litres ----------------------------------------------------
        let cubicFoot = 28.316846592
        put(["l", "L", "lt"], Unit(.volume, 1, prefixing: .decimal))
        put(["tsp"], Unit(.volume, 4.92892159375e-3))
        put(["tspm"], Unit(.volume, 5e-3))
        put(["tbs"], Unit(.volume, 14.78676478125e-3))
        put(["oz"], Unit(.volume, 29.5735295625e-3))
        put(["cup"], Unit(.volume, 236.5882365e-3))
        put(["pt", "us_pt"], Unit(.volume, 473.176473e-3))
        put(["uk_pt"], Unit(.volume, 568.26125e-3))
        put(["qt"], Unit(.volume, 946.352946e-3))
        put(["uk_qt"], Unit(.volume, 1136.5225e-3))
        put(["gal"], Unit(.volume, 3.785411784))
        put(["uk_gal"], Unit(.volume, 4.54609))
        put(["barrel"], Unit(.volume, 158.987294928))
        put(["bushel"], Unit(.volume, 35.23907016688))
        put(["GRT", "regton"], Unit(.volume, cubicFoot * 100))
        put(["MTON"], Unit(.volume, cubicFoot * 40))
        // The cubed lengths. A litre is a cubic decimetre, so a cubic metre is 1,000 of
        // them, and every other cubed unit follows from its length.
        put(["m3", "m^3"], Unit(.volume, 1000, dimension: 3, prefixing: .decimal))
        put(["ang3", "ang^3"], Unit(.volume, 1e-27, dimension: 3, prefixing: .decimal))
        put(["ft3", "ft^3"], Unit(.volume, cubicFoot))
        put(["in3", "in^3"], Unit(.volume, pow(inch, 3) * 1000))
        put(["yd3", "yd^3"], Unit(.volume, pow(foot * 3, 3) * 1000))
        put(["mi3", "mi^3"], Unit(.volume, pow(foot * 5280, 3) * 1000))
        put(["Nmi3", "Nmi^3"], Unit(.volume, pow(1852, 3) * 1000))
        put(["ly3", "ly^3"], Unit(.volume, pow(lightYear, 3) * 1000))
        put(["Picapt3", "Picapt^3", "Pica3", "Pica^3"],
            Unit(.volume, pow(inch / 72, 3) * 1000))

        // --- Area, in square metres -----------------------------------------------
        put(["m2", "m^2"], Unit(.area, 1, dimension: 2, prefixing: .decimal))
        put(["ang2", "ang^2"], Unit(.area, 1e-20, dimension: 2, prefixing: .decimal))
        put(["ar"], Unit(.area, 100, prefixing: .decimal))
        put(["ha"], Unit(.area, 10000))
        put(["Morgen"], Unit(.area, 2500))
        put(["ft2", "ft^2"], Unit(.area, foot * foot))
        put(["in2", "in^2"], Unit(.area, inch * inch))
        put(["yd2", "yd^2"], Unit(.area, pow(foot * 3, 2)))
        put(["mi2", "mi^2"], Unit(.area, pow(foot * 5280, 2)))
        put(["Nmi2", "Nmi^2"], Unit(.area, pow(1852, 2)))
        put(["ly2", "ly^2"], Unit(.area, pow(lightYear, 2)))
        put(["Picapt2", "Picapt^2", "Pica2", "Pica^2"], Unit(.area, pow(inch / 72, 2)))
        put(["uk_acre"], Unit(.area, 4046.8564224))
        put(["us_acre"], Unit(.area, 4046.87261))

        // --- Information, in bits -------------------------------------------------
        put(["bit"], Unit(.information, 1, prefixing: .binary))
        put(["byte"], Unit(.information, 8, prefixing: .binary))

        // --- Speed, in metres per second ------------------------------------------
        put(["m/s", "m/sec"], Unit(.speed, 1, prefixing: .decimal))
        put(["m/h", "m/hr"], Unit(.speed, 1.0 / 3600, prefixing: .decimal))
        put(["mph"], Unit(.speed, foot * 5280 / 3600))
        put(["kn"], Unit(.speed, 1852.0 / 3600))
        put(["admkn"], Unit(.speed, 1853.184 / 3600))
        return table
    }()

    /// The decimal prefixes, longest first so `da` is tried before `d`.
    private static let decimalPrefixes: [(String, Double)] = [
        ("da", 1e1),
        ("Y", 1e24), ("Z", 1e21), ("E", 1e18), ("P", 1e15), ("T", 1e12), ("G", 1e9),
        ("M", 1e6), ("k", 1e3), ("h", 1e2), ("e", 1e1), ("d", 1e-1), ("c", 1e-2),
        ("m", 1e-3), ("u", 1e-6), ("n", 1e-9), ("p", 1e-12), ("f", 1e-15), ("a", 1e-18),
        ("z", 1e-21), ("y", 1e-24),
    ]

    /// The binary prefixes, which belong to the information units and to nothing else.
    private static let binaryPrefixes: [(String, Double)] = [
        ("Yi", 0x1p80), ("Zi", 0x1p70), ("Ei", 0x1p60), ("Pi", 0x1p50),
        ("Ti", 0x1p40), ("Gi", 0x1p30), ("Mi", 0x1p20), ("ki", 0x1p10),
    ]

    // MARK: - Reading a unit name

    /// A unit name resolved to a measure and a multiplier.
    private struct Resolved {
        let measure: Measure
        /// Base units per one of these, prefix included.
        let factor: Double
    }

    /// Reads a unit name, with any prefix it carries.
    ///
    /// **The whole name is tried first, always.** `mn` is a minute and not a milli-newton,
    /// `cwt` is a hundredweight and not a centi-watt, and `e` is an erg as well as being
    /// the deka prefix. Trying prefixes first would silently redefine every one of them.
    private static func resolve(_ name: String) -> Resolved? {
        if let unit = units[name] {
            return Resolved(measure: unit.measure, factor: unit.factor)
        }
        // Binary before decimal: `ki` and `k` both start the same way, and the binary
        // reading is the longer one.
        for (prefix, scale) in binaryPrefixes + decimalPrefixes where name.hasPrefix(prefix) {
            let remainder = String(name.dropFirst(prefix.count))
            guard let unit = units[remainder] else { continue }
            let isBinary = binaryPrefixes.contains { $0.0 == prefix }
            switch unit.prefixing {
            case .none:
                continue
            case .decimal where isBinary:
                continue
            case .decimal, .binary:
                // The prefix scales the length a unit is built from, so an area takes it
                // squared and a volume cubed.
                return Resolved(measure: unit.measure,
                                factor: unit.factor * pow(scale, Double(unit.dimension)))
            }
        }
        return nil
    }

    // MARK: - Temperature

    /// The temperature scales a prefix may be attached to.
    ///
    /// **`K` and nothing else, which took two measurements to establish.** This first
    /// refused prefixes everywhere, reasoning that a prefix and an offset do not compose —
    /// what is a milli-degree-Celsius? Excel answered `CONVERT(1, "mK", "K")` with `0.001`,
    /// so that was wrong. The correction then allowed them everywhere, and Excel answered
    /// `CONVERT(1, "mC", "C")` with `#N/A`.
    ///
    /// So the original reasoning was right about `C` and `F` and wrong about `K`, which no
    /// amount of thinking was going to produce. A prefix scales a magnitude, and only an
    /// absolute scale has one to scale.
    ///
    /// `Rank` is absolute too and is **not** listed, because it has not been measured — the
    /// pattern suggests it belongs here and the pattern has now been wrong twice on this
    /// exact question. It goes to Excel in the next round instead.
    private static let prefixableTemperatures: Set<String> = ["K", "kel"]

    /// A temperature unit with any prefix it carries.
    private static func temperatureScale(_ name: String) -> (unit: String, scale: Double)? {
        if kelvin(0, from: name) != nil { return (name, 1) }
        for (prefix, scale) in decimalPrefixes where name.hasPrefix(prefix) {
            let remainder = String(name.dropFirst(prefix.count))
            guard prefixableTemperatures.contains(remainder) else { continue }
            return (remainder, scale)
        }
        return nil
    }

    /// A temperature in kelvin, from whichever scale it was written in.
    private static func kelvin(_ value: Double, from unit: String) -> Double? {
        switch unit {
        case "C", "cel": return value + 273.15
        case "K", "kel": return value
        case "F", "fah": return (value + 459.67) * 5 / 9
        case "Rank": return value * 5 / 9
        case "Reau": return value * 1.25 + 273.15
        default: return nil
        }
    }

    /// A temperature in kelvin, written in whichever scale was asked for.
    private static func temperature(_ kelvin: Double, as unit: String) -> Double? {
        switch unit {
        case "C", "cel": return kelvin - 273.15
        case "K", "kel": return kelvin
        case "F", "fah": return kelvin * 9 / 5 - 459.67
        case "Rank": return kelvin * 9 / 5
        case "Reau": return (kelvin - 273.15) / 1.25
        default: return nil
        }
    }

    // MARK: - The function

    /// `CONVERT(number, from_unit, to_unit)`.
    public static let convert = ExcelFunction(
        name: "CONVERT", minArgs: 3, maxArgs: 3
    ) { values in
        if let error = BuiltinStatisticalDistributions.firstError(values) { return error }
        guard let amount = BuiltinStatisticalDistributions.real(values.first) else {
            return .error(.value)
        }
        guard case .text(let from) = values[1], case .text(let to) = values[2] else {
            return .error(.value)
        }

        // Temperature first: it is the one measure that does not convert by ratio, and
        // routing it through the ordinary path would drop the offset.
        if let source = temperatureScale(from) {
            guard let target = temperatureScale(to) else { return .error(.na) }
            let asKelvin = kelvin(amount * source.scale, from: source.unit)
            guard let asKelvin, let result = temperature(asKelvin, as: target.unit) else {
                return .error(.na)
            }
            return .number(result / target.scale)
        }
        // The other half of that: a temperature asked for from a non-temperature unit is a
        // measure mismatch, not an unknown unit, and both are `#N/A` anyway.
        guard temperatureScale(to) == nil else { return .error(.na) }

        guard let source = resolve(from), let target = resolve(to) else { return .error(.na) }
        guard source.measure == target.measure else { return .error(.na) }
        guard target.factor != 0 else { return .error(.na) }
        return .number(amount * source.factor / target.factor)
    }
}
