import Foundation
import SwiftExcelCore

/// Weeks, elapsed periods, and a time read out of text.
///
/// Four functions that have nothing in common except that each answers a question about a
/// date which the date family did not already answer:
///
/// | Function | Question |
/// |---|---|
/// | `WEEKNUM` | which week of the year, under one of ten numbering conventions |
/// | `ISOWEEKNUM` | which week of the year, under the one convention that is a standard |
/// | `DATEDIF` | how many whole years, months or days lie between two dates |
/// | `TIMEVALUE` | what fraction of a day a time written as text is |
public enum BuiltinWeekFunctions {

    /// All week and elapsed-period functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [weeknum, isoweeknum, datedif, timevalue]

    // MARK: - Which week

    /// `WEEKNUM(serial, [return_type])` — the week of the year a date falls in.
    ///
    /// **Week 1 is the week containing 1 January**, however few days of it that is. A
    /// Saturday 1 January is week 1 all by itself and the following Sunday starts week 2.
    /// That is not the ISO rule and is not meant to be; `ISOWEEKNUM` is beside it for when
    /// the ISO rule is what a model wants.
    ///
    /// The return type says which day the week starts on:
    ///
    /// | Type | Week starts | | Type | Week starts |
    /// |---|---|---|---|---|
    /// | 1 *(default)*, 17 | Sunday | | 14 | Thursday |
    /// | 2, 11 | Monday | | 15 | Friday |
    /// | 12 | Tuesday | | 16 | Saturday |
    /// | 13 | Wednesday | | 21 | ISO — Monday, and the ISO year rule |
    ///
    /// Type 21 is `ISOWEEKNUM` under another name, which is why it is the only type here
    /// that can answer 52 or 53 for a day in January.
    public static let weeknum = ExcelFunction(name: "WEEKNUM", minArgs: 1, maxArgs: 2) { args in
        if let error = firstError(args) { return error }
        guard let serial = serial(args[0]) else { return .error(.value) }
        guard serial >= 1 else { return .error(.num) }
        let requested = args.count > 1 ? number(args[1]) : 1
        guard let requested, requested.isFinite, requested.magnitude < 1e9 else {
            return .error(.value)
        }
        let type = Int(requested)
        if type == 21 { return isoWeek(of: serial) }
        guard let startDay = weekStart(forType: type) else { return .error(.num) }

        let (year, _, _) = BuiltinDateTimeFunctions.serialToComponents(serial)
        guard let january1 = BuiltinDateTimeFunctions.componentsToSerial(year: year, month: 1, day: 1)
        else { return .error(.num) }
        // How far into its own week 1 January sits, counting from the chosen start day.
        let offset = (WeekendMask.weekdayNumber(of: january1) - startDay + 7) % 7
        let dayOfYear = serial - january1 + 1
        return .number(Double((dayOfYear + offset - 1) / 7 + 1))
    }

    /// `ISOWEEKNUM(serial)` — the ISO 8601 week of the year.
    ///
    /// **Week 1 is the week containing the first Thursday**, so the first days of January
    /// can belong to week 52 or 53 of the year before, and the last days of December can
    /// belong to week 1 of the year after. 1 January 2012 is week 52; 31 December 2012 is
    /// week 1.
    ///
    /// That is the whole difference from `WEEKNUM`, and it is a difference of up to a
    /// year in the answer rather than of one in the week.
    public static let isoweeknum = ExcelFunction(name: "ISOWEEKNUM", minArgs: 1, maxArgs: 1) { args in
        if let error = firstError(args) { return error }
        guard let serial = serial(args[0]) else { return .error(.value) }
        guard serial >= 1 else { return .error(.num) }
        return isoWeek(of: serial)
    }

    /// The ISO week number of a serial.
    ///
    /// Found through the Thursday of that date's week, which is the definition rather than
    /// a trick: the ISO year is whichever year that Thursday falls in, and the week number
    /// is how many Thursdays have passed in it.
    ///
    /// - Parameter serial: An Excel date serial.
    /// - Returns: The week number, or `#NUM!` if the date has no representable January.
    private static func isoWeek(of serial: Int) -> CellValue {
        // Monday = 1 … Sunday = 7, which is the ISO numbering rather than Excel's.
        let isoWeekday = (WeekendMask.weekdayNumber(of: serial) + 5) % 7 + 1
        let thursday = serial + (4 - isoWeekday)
        let (year, _, _) = BuiltinDateTimeFunctions.serialToComponents(thursday)
        guard let january1 = BuiltinDateTimeFunctions.componentsToSerial(year: year, month: 1, day: 1)
        else { return .error(.num) }
        return .number(Double((thursday - january1) / 7 + 1))
    }

    /// Which day a numbered week starts on, as an Excel weekday number.
    ///
    /// - Parameter type: The `return_type` argument.
    /// - Returns: 1 for Sunday through 7 for Saturday, or `nil` for a type Excel rejects.
    private static func weekStart(forType type: Int) -> Int? {
        switch type {
        case 1, 17: return 1        // Sunday
        case 2, 11: return 2        // Monday
        case 12: return 3
        case 13: return 4
        case 14: return 5
        case 15: return 6
        case 16: return 7           // Saturday
        default: return nil
        }
    }

    // MARK: - How long between

    /// `DATEDIF(start_date, end_date, unit)` — whole periods between two dates.
    ///
    /// | Unit | Counts |
    /// |---|---|
    /// | `"Y"` | complete years |
    /// | `"M"` | complete months |
    /// | `"D"` | days |
    /// | `"YM"` | complete months, ignoring years |
    /// | `"YD"` | days, ignoring years |
    /// | `"MD"` | days, ignoring months and years |
    ///
    /// **`"MD"` is wrong in Excel and is wrong here too.** Microsoft's own reference says
    /// so — "not recommended … may result in a negative number, a zero, or an inaccurate
    /// result" — and `DATEDIF("2016-01-31", "2016-03-01", "MD")` answers −1 rather than
    /// refusing. This package reproduces that, because ADR-001 makes Excel the
    /// specification and because a caller comparing the two would otherwise find *us*
    /// disagreeing with the sheet in the one unit Microsoft warns about.
    ///
    /// A start date after the end date is `#NUM!` in every unit, which is the check `"MD"`
    /// would need internally and does not do.
    public static let datedif = ExcelFunction(name: "DATEDIF", minArgs: 3, maxArgs: 3) { args in
        if let error = firstError(args) { return error }
        guard let start = serial(args[0]), let end = serial(args[1]),
              case .text(let unit) = args[2] else { return .error(.value) }
        guard start <= end else { return .error(.num) }

        let from = BuiltinDateTimeFunctions.serialToComponents(start)
        let to = BuiltinDateTimeFunctions.serialToComponents(end)
        // A month is complete only when the day of the month has come round again.
        let dayShort = to.day < from.day
        let months = (to.year - from.year) * 12 + (to.month - from.month) - (dayShort ? 1 : 0)

        switch unit.uppercased() {
        case "D": return .number(Double(end - start))
        case "M": return .number(Double(months))
        case "Y": return .number(Double(months / 12))
        case "YM": return .number(Double(months % 12))
        case "YD": return elapsedDaysIgnoringYears(from: from, to: to, end: end)
        case "MD": return .number(Double(daysIgnoringMonths(from: from, to: to)))
        default: return .error(.num)
        }
    }

    /// Days between two dates with the years taken out.
    ///
    /// The start is moved to the end's year, and back one year again if that puts it
    /// after the end — which is the case a January-to-December pair always is.
    ///
    /// - Parameters:
    ///   - from: The start date's components.
    ///   - to: The end date's components.
    ///   - end: The end date's serial.
    /// - Returns: The day count, or `#NUM!` if the moved date is not representable.
    private static func elapsedDaysIgnoringYears(
        from: (year: Int, month: Int, day: Int),
        to: (year: Int, month: Int, day: Int),
        end: Int
    ) -> CellValue {
        let sameYear = (from.month, from.day) <= (to.month, to.day) ? to.year : to.year - 1
        guard let moved = BuiltinDateTimeFunctions.componentsToSerial(
            year: sameYear, month: from.month, day: from.day) else { return .error(.num) }
        return .number(Double(end - moved))
    }

    /// Days between two dates with the months and years taken out.
    ///
    /// - Parameters:
    ///   - from: The start date's components.
    ///   - to: The end date's components.
    /// - Returns: The day count, which may be negative — see ``datedif``.
    private static func daysIgnoringMonths(
        from: (year: Int, month: Int, day: Int),
        to: (year: Int, month: Int, day: Int)
    ) -> Int {
        guard to.day < from.day else { return to.day - from.day }
        // Borrow from the month before the end date, which is what produces the negative
        // answers: borrowing 29 days to cover a gap of 30 leaves −1.
        let previousMonth = to.month == 1 ? 12 : to.month - 1
        let previousYear = to.month == 1 ? to.year - 1 : to.year
        let borrowed = BuiltinDateTimeFunctions.daysInMonth(year: previousYear, month: previousMonth)
        return to.day - from.day + borrowed
    }

    // MARK: - A time written down

    /// `TIMEVALUE(time_text)` — the fraction of a day a time is.
    ///
    /// `TIMEVALUE("2:24 PM")` is `0.6`. The date part of the text, if there is one, is
    /// discarded: this answers what time of day, not which day.
    ///
    /// Written out rather than handed to a `DateFormatter`, because a formatter reads
    /// what the *machine's locale* says and a spreadsheet's text is whatever was typed.
    /// A locale that writes 24-hour times would refuse `"2:24 PM"` on one machine and
    /// accept it on another, and nothing in the file would say which had happened.
    public static let timevalue = ExcelFunction(name: "TIMEVALUE", minArgs: 1, maxArgs: 1) { args in
        if let error = firstError(args) { return error }
        guard case .text(let text) = args[0] else { return .error(.value) }
        guard let fraction = dayFraction(of: text) else { return .error(.value) }
        return .number(fraction)
    }

    /// Reads a time out of text.
    ///
    /// - Parameter text: The argument as written, date part and all.
    /// - Returns: The fraction of a day, or `nil` if the text names no time.
    static func dayFraction(of text: String) -> Double? {
        var body = text.uppercased().trimmingCharacters(in: .whitespaces)

        // A meridiem, if it is there, is at the end and changes how the hour reads.
        var meridiem: String?
        for suffix in ["AM", "PM"] where body.hasSuffix(suffix) {
            meridiem = suffix
            body = String(body.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        // Anything before the last space is a date, and a date is not what this answers.
        if let space = body.lastIndex(of: " ") {
            body = String(body[body.index(after: space)...])
        }

        let parts = body.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        guard let hour = Int(parts[0]), let minute = Int(parts[1]) else { return nil }
        let second: Double? = parts.count == 3 ? Double(parts[2]) : 0
        guard let second, second >= 0, second < 60 else { return nil }
        guard minute >= 0, minute < 60 else { return nil }

        guard let hourOfDay = hour24(hour, meridiem: meridiem) else { return nil }
        return (Double(hourOfDay) * 3600 + Double(minute) * 60 + second) / 86_400
    }

    /// The hour on a 24-hour clock.
    ///
    /// - Parameters:
    ///   - hour: The hour as written.
    ///   - meridiem: `"AM"`, `"PM"`, or `nil` when the text carried neither.
    /// - Returns: 0 through 23, or `nil` for an hour that names no time. Noon and midnight
    ///   are the awkward pair: `12 AM` is hour 0 and `12 PM` is hour 12.
    private static func hour24(_ hour: Int, meridiem: String?) -> Int? {
        switch meridiem {
        case "AM":
            guard (1...12).contains(hour) else { return nil }
            return hour == 12 ? 0 : hour
        case "PM":
            guard (1...12).contains(hour) else { return nil }
            return hour == 12 ? 12 : hour + 12
        default:
            guard (0...23).contains(hour) else { return nil }
            return hour
        }
    }

    // MARK: - Arguments

    /// A value as an Excel serial, truncated to a whole day.
    private static func serial(_ value: CellValue) -> Int? {
        guard let number = number(value), number.isFinite, number >= 0 else { return nil }
        return Int(number)
    }

    /// A value as a number, when it is one.
    private static func number(_ value: CellValue) -> Double? {
        switch value {
        case .number(let number): return number
        case .bool(let flag): return flag ? 1 : 0
        case .date(let date): return BuiltinDateTimeFunctions.dateToSerial(date)
        case .text(let text): return Double(text)
        case .formula(_, let cached): return cached.flatMap(number)
        default: return nil
        }
    }

    /// The first argument that is an error, if any.
    private static func firstError(_ args: [CellValue]) -> CellValue? {
        for argument in args {
            if case .error = argument { return argument }
        }
        return nil
    }
}
