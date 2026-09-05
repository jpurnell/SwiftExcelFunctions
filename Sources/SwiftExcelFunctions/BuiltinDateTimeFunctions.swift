import Foundation
import SwiftExcelCore

/// Date category built-in Excel functions.
///
/// `TODAY`, `NOW`, `YEAR`, `MONTH`, `DAY`, `DATE`, `WEEKDAY`, `EOMONTH`, `EDATE`,
/// `DAYS`, `HOUR`, `MINUTE` and `SECOND`.
///
/// Excel date serial numbers count days since 1900-01-01, where serial 1 = Jan 1, 1900.
/// Excel has a known bug where it treats 1900 as a leap year (serial 60 = Feb 29, 1900,
/// which did not actually exist). This implementation matches that behavior.
///
/// Register all functions at once via ``all``:
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinDateTimeFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinDateTimeFunctions {

    /// All date functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        today, now, year, month, day, dateFunc,
        weekday, eomonth, edate, days, hour, minute, second,
    ]

    // MARK: - Day of week

    /// `WEEKDAY(serial, [type])` — which day of the week a date falls on.
    ///
    /// The type argument is the whole difficulty. Excel numbers the week three
    /// common ways and a model picks whichever suits it, so the function cannot
    /// simply return a calendar's own numbering:
    ///
    /// | Type | Week starts | Range |
    /// |---|---|---|
    /// | 1 (default) | Sunday | 1–7 |
    /// | 2 | Monday | 1–7 |
    /// | 3 | Monday | 0–6 |
    public static let weekday = ExcelFunction(name: "WEEKDAY", minArgs: 1, maxArgs: 2) { args in
        catching {
            let serial = Int(try toNumber(args[0]))
            guard serial >= 1 else { throw EvalError.numError }
            let type = args.count > 1 ? Int(try toNumber(args[1])) : 1

            // Serial 1 is 1900-01-01, a Sunday, so `serial % 7 == 1` is a Sunday.
            let sundayBased = ((serial % 7) + 6) % 7 + 1   // 1 = Sunday … 7 = Saturday
            switch type {
            case 1: return .number(Double(sundayBased))
            case 2: return .number(Double((sundayBased + 5) % 7 + 1))   // 1 = Monday
            case 3: return .number(Double((sundayBased + 5) % 7))       // 0 = Monday
            default: throw EvalError.numError
            }
        }
    }

    // MARK: - Month arithmetic

    /// `EOMONTH(serial, months)` — the last day of the month, `months` away.
    ///
    /// How a model steps to a period end: a settlement date, a quarter close, an
    /// accrual boundary. A negative offset walks backwards.
    public static let eomonth = ExcelFunction(name: "EOMONTH", minArgs: 2, maxArgs: 2) { args in
        catching {
            let serial = Int(try toNumber(args[0]))
            guard serial >= 1 else { throw EvalError.numError }
            let offset = Int(try toNumber(args[1]))
            let (year, month, _) = serialToComponents(serial)

            let shifted = (year * 12 + (month - 1)) + offset
            let targetYear = shifted / 12
            let targetMonth = shifted % 12 + 1
            let lastDay = daysInMonth(year: targetYear, month: targetMonth)
            return .number(componentsToSerial(year: targetYear, month: targetMonth, day: lastDay))
        }
    }

    /// `EDATE(serial, months)` — the same day of the month, `months` away.
    ///
    /// Where that day does not exist in the target month — the 31st of a
    /// thirty-day month, or a 29th outside a leap year — Excel clamps to the end
    /// rather than rolling into the next month.
    public static let edate = ExcelFunction(name: "EDATE", minArgs: 2, maxArgs: 2) { args in
        catching {
            let serial = Int(try toNumber(args[0]))
            guard serial >= 1 else { throw EvalError.numError }
            let offset = Int(try toNumber(args[1]))
            let (year, month, day) = serialToComponents(serial)

            let shifted = (year * 12 + (month - 1)) + offset
            let targetYear = shifted / 12
            let targetMonth = shifted % 12 + 1
            let clamped = min(day, daysInMonth(year: targetYear, month: targetMonth))
            return .number(componentsToSerial(year: targetYear, month: targetMonth, day: clamped))
        }
    }

    /// `DAYS(end, start)` — days between two dates, end first.
    ///
    /// The order is Excel's and is easy to get backwards; a negative result is a
    /// legitimate answer rather than an error.
    public static let days = ExcelFunction(name: "DAYS", minArgs: 2, maxArgs: 2) { args in
        catching {
            let end = try toNumber(args[0])
            let start = try toNumber(args[1])
            return .number((end.rounded(.down)) - (start.rounded(.down)))
        }
    }

    // MARK: - Time of day

    /// `HOUR(serial)` — the hour, from a serial's fractional part.
    public static let hour = ExcelFunction(name: "HOUR", minArgs: 1, maxArgs: 1) { args in
        catching { .number(Double(try secondsIntoDay(args[0]) / 3600)) }
    }

    /// `MINUTE(serial)` — the minute, from a serial's fractional part.
    public static let minute = ExcelFunction(name: "MINUTE", minArgs: 1, maxArgs: 1) { args in
        catching { .number(Double((try secondsIntoDay(args[0]) % 3600) / 60)) }
    }

    /// `SECOND(serial)` — the second, from a serial's fractional part.
    public static let second = ExcelFunction(name: "SECOND", minArgs: 1, maxArgs: 1) { args in
        catching { .number(Double(try secondsIntoDay(args[0]) % 60)) }
    }

    /// Seconds elapsed since midnight, from a serial's fractional part.
    ///
    /// Rounded to the nearest second before splitting, because a time written as
    /// a fraction of a day rarely lands exactly: 06:30:30 is 0.2711805555…, and
    /// truncating that yields 29 seconds rather than 30.
    private static func secondsIntoDay(_ value: CellValue) throws -> Int {
        let serial = try toNumber(value)
        guard serial >= 0 else { throw EvalError.numError }
        let fraction = serial - serial.rounded(.down)
        return Int((fraction * 86_400).rounded()) % 86_400
    }

    // MARK: - Calendar helpers

    /// Days in a month, Gregorian rules.
    ///
    /// 1900 is deliberately not special-cased here. Excel's phantom 29 February
    /// 1900 lives in the serial conversion, and duplicating it would apply the bug
    /// twice.
    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return isLeapYear(year) ? 29 : 28
        default: return 30
        }
    }

    /// Whether a year is a leap year, by the Gregorian rule.
    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    /// The Excel serial for a year, month and day.
    static func componentsToSerial(year: Int, month: Int, day: Int) -> Double {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return 0 }
        return dateToSerial(date)
    }

    // MARK: - Calendar and constants

    /// A Gregorian calendar with a fixed UTC time zone for date calculations.
    private static let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? TimeZone.current
        return cal
    }()

    /// The Excel epoch: January 1, 1900 as a `Date`.
    ///
    /// Excel serial 1 = Jan 1, 1900.
    /// We compute from the reference: serial = days_since_dec_31_1899.
    private static let excelEpoch: Date = {
        var components = DateComponents()
        components.year = 1899
        components.month = 12
        components.day = 31
        return calendar.date(from: components) ?? Date.distantPast
    }()

    // MARK: - Serial number conversion

    /// Converts a `Date` to an Excel serial number.
    ///
    /// Accounts for Excel's 1900 leap year bug: dates on or after March 1, 1900
    /// are shifted by +1.
    ///
    /// - Parameter date: The date to convert.
    /// - Returns: The Excel serial number.
    static func dateToSerial(_ date: Date) -> Double {
        let days = calendar.dateComponents([.day], from: excelEpoch, to: date).day ?? 0
        // Excel's bug: it thinks Feb 29, 1900 exists (serial 60).
        // Dates from March 1, 1900 onward need +1 to account for this phantom day.
        // March 1, 1900 should be serial 61 (60 for phantom Feb 29 + 1).
        // Without the bug, March 1, 1900 would be day 60 from epoch.
        if days >= 60 {
            return Double(days + 1)
        }
        return Double(days)
    }

    /// Converts an Excel serial number to year, month, day components.
    ///
    /// Handles Excel's 1900 leap year bug where serial 60 = Feb 29, 1900.
    ///
    /// - Parameter serial: The Excel serial number.
    /// - Returns: A tuple of (year, month, day).
    static func serialToComponents(_ serial: Int) -> (year: Int, month: Int, day: Int) {
        // Handle the phantom Feb 29, 1900
        if serial == 60 {
            return (1900, 2, 29)
        }

        // For serials > 60, subtract 1 to undo the phantom day offset
        let adjustedDays: Int
        if serial > 60 {
            adjustedDays = serial - 1
        } else {
            adjustedDays = serial
        }

        guard let date = calendar.date(byAdding: .day, value: adjustedDays, to: excelEpoch) else {
            return (1900, 1, 1)
        }

        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return (comps.year ?? 1900, comps.month ?? 1, comps.day ?? 1)
    }

    /// Converts year, month, day to an Excel serial number.
    ///
    /// Handles Excel's 1900 leap year bug.
    ///
    /// - Parameters:
    ///   - year: The year.
    ///   - month: The month (1-12).
    ///   - day: The day of month (1-31).
    /// - Returns: The Excel serial number, or nil if the date is invalid.
    static func componentsToSerial(year: Int, month: Int, day: Int) -> Int? {
        // Special case: the phantom Feb 29, 1900
        if year == 1900 && month == 2 && day == 29 {
            return 60
        }

        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        guard let date = calendar.date(from: comps) else { return nil }
        let days = calendar.dateComponents([.day], from: excelEpoch, to: date).day ?? 0

        // Adjust for the phantom day
        if days >= 60 {
            return days + 1
        }
        return days
    }

    // MARK: - Type coercion

    /// Extracts a `Double` from a `CellValue`.
    private static func toNumber(_ value: CellValue) throws -> Double {
        switch value {
        case .number(let n):
            return n
        case .text(let s):
            guard let n = Double(s) else { throw EvalError.typeMismatch }
            return n
        case .bool(let b):
            return b ? 1.0 : 0.0
        case .blank:
            return 0.0
        case .error(let e):
            throw EvalError.excelError(e)
        case .date(let d):
            return dateToSerial(d)
        case .formula(_, let cached):
            return try toNumber(cached ?? .blank)
        case .array:
            throw EvalError.typeMismatch
        }
    }

    /// Wraps a function body so that ``EvalError`` maps to the correct ``CellValue/error(_:)``.
    private static func catching(_ body: () throws -> CellValue) -> CellValue {
        do {
            return try body()
        } catch EvalError.excelError(let e) {
            return .error(e)
        } catch EvalError.numError {
            return .error(.num)
        } catch EvalError.div0Error {
            return .error(.div0)
        } catch {
            return .error(.value)
        }
    }

    // MARK: - TODAY

    /// `TODAY()` -- returns today's date as an Excel serial number.
    ///
    /// The serial number represents the current date with no time component.
    static let today = ExcelFunction(name: "TODAY", minArgs: 0, maxArgs: 0) { _ in
        let now = Date()
        let comps = calendar.dateComponents([.year, .month, .day], from: now)
        guard let dateOnly = calendar.date(from: comps) else {
            return .error(.value)
        }
        return .number(dateToSerial(dateOnly))
    }

    // MARK: - NOW

    /// `NOW()` -- returns the current date and time as an Excel serial number.
    ///
    /// The fractional part represents the time of day.
    static let now = ExcelFunction(name: "NOW", minArgs: 0, maxArgs: 0) { _ in
        let current = Date()
        let serial = dateToSerial(current)
        // Add fractional time
        let comps = calendar.dateComponents([.hour, .minute, .second], from: current)
        let hours = Double(comps.hour ?? 0)
        let minutes = Double(comps.minute ?? 0)
        let seconds = Double(comps.second ?? 0)
        let timeFraction = (hours * 3600 + minutes * 60 + seconds) / 86_400.0
        return .number(serial + timeFraction)
    }

    // MARK: - YEAR

    /// `YEAR(serial_number)` -- extracts the year from an Excel date serial number.
    static let year = ExcelFunction(name: "YEAR", minArgs: 1, maxArgs: 1) { args in
        catching {
            let serial = Int(try toNumber(args[0]))
            guard serial >= 1 else { throw EvalError.numError }
            let (y, _, _) = serialToComponents(serial)
            return .number(Double(y))
        }
    }

    // MARK: - MONTH

    /// `MONTH(serial_number)` -- extracts the month (1-12) from an Excel date serial number.
    static let month = ExcelFunction(name: "MONTH", minArgs: 1, maxArgs: 1) { args in
        catching {
            let serial = Int(try toNumber(args[0]))
            guard serial >= 1 else { throw EvalError.numError }
            let (_, m, _) = serialToComponents(serial)
            return .number(Double(m))
        }
    }

    // MARK: - DAY

    /// `DAY(serial_number)` -- extracts the day of the month (1-31) from an Excel date serial number.
    static let day = ExcelFunction(name: "DAY", minArgs: 1, maxArgs: 1) { args in
        catching {
            let serial = Int(try toNumber(args[0]))
            guard serial >= 1 else { throw EvalError.numError }
            let (_, _, d) = serialToComponents(serial)
            return .number(Double(d))
        }
    }

    // MARK: - DATE

    /// `DATE(year, month, day)` -- creates an Excel serial number from year, month, and day values.
    ///
    /// Returns `#VALUE!` if the resulting date cannot be represented.
    static let dateFunc = ExcelFunction(name: "DATE", minArgs: 3, maxArgs: 3) { args in
        catching {
            let y = Int(try toNumber(args[0]))
            let m = Int(try toNumber(args[1]))
            let d = Int(try toNumber(args[2]))

            // Excel treats year 0-1899 as 1900-3799
            let adjustedYear: Int
            if y >= 0 && y <= 1899 {
                adjustedYear = 1900 + y
            } else {
                adjustedYear = y
            }

            guard let serial = componentsToSerial(year: adjustedYear, month: m, day: d) else {
                throw EvalError.numError
            }
            guard serial >= 0 else { throw EvalError.numError }
            return .number(Double(serial))
        }
    }
}
