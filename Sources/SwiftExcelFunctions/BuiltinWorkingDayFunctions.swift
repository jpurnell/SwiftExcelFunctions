import Foundation
import SwiftExcelCore

/// Working days: counting them, and stepping by them.
///
/// `WORKDAY` already lives in ``BuiltinDateTimeFunctions`` because it arrived with the
/// date family. The three here are the rest of the shape:
///
/// | Function | Question |
/// |---|---|
/// | `NETWORKDAYS` | how many working days lie between two dates, both counted |
/// | `NETWORKDAYS.INTL` | the same, for a week that does not rest on Saturday and Sunday |
/// | `WORKDAY.INTL` | `WORKDAY`, likewise |
///
/// ## The weekend is an argument, and it has two spellings
///
/// The `.INTL` pair take a weekend as either a **code** or a **mask**, and both are in
/// real use because Excel's own dialog writes the code while anyone building a schedule
/// by hand writes the mask:
///
/// ```
/// NETWORKDAYS.INTL(start, end, 11)          Sunday is the only day off
/// NETWORKDAYS.INTL(start, end, "0000011")   Saturday and Sunday, written out
/// ```
///
/// The mask reads Monday first and marks a **non-working** day with `1`, which is the
/// opposite of the intuition that `1` means a day that counts. Getting it backwards
/// produces a plausible number rather than an error, so the mask is parsed in exactly one
/// place here and tested against both ends of the week.
///
/// A mask of all sevens — every day a weekend — is `#VALUE!` rather than zero. Excel
/// refuses it, and it is the one case where the answer would otherwise be an infinite
/// loop in ``workdayINTL``.
public enum BuiltinWorkingDayFunctions {

    /// All working-day functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [networkdays, networkdaysINTL, workdayINTL]

    // MARK: - Counting

    /// `NETWORKDAYS(start_date, end_date, [holidays])` — working days between two dates.
    ///
    /// **Both endpoints count.** A Monday to the following Friday is 5, not 4, and a
    /// single working day to itself is 1. That is what makes this the function a timesheet
    /// uses, and it is the detail most reimplementations get wrong.
    ///
    /// A start after the end returns a **negative** count rather than an error: Excel
    /// treats the pair as an interval walked backwards.
    public static let networkdays = ExcelFunction(
        name: "NETWORKDAYS", minArgs: 2, maxArgs: 3
    ) { args in
        if let error = firstError(args) { return error }
        guard let start = serial(args[0]), let end = serial(args[1]) else { return .error(.value) }
        return count(from: start, to: end,
                     weekend: WeekendMask.saturdaySunday,
                     holidays: holidays(in: args, from: 2))
    }

    /// `NETWORKDAYS.INTL(start_date, end_date, [weekend], [holidays])` — the same count,
    /// for a week that rests on other days.
    ///
    /// The weekend defaults to Saturday and Sunday, so the two-argument call is
    /// `NETWORKDAYS` exactly.
    public static let networkdaysINTL = ExcelFunction(
        name: "NETWORKDAYS.INTL", minArgs: 2, maxArgs: 4
    ) { args in
        if let error = firstError(args) { return error }
        guard let start = serial(args[0]), let end = serial(args[1]) else { return .error(.value) }
        let weekend = args.count > 2 ? WeekendMask.reading(args[2]) : .mask(.saturdaySunday)
        switch weekend {
        case .refusal(let error): return .error(error)
        case .mask(let mask):
            return count(from: start, to: end, weekend: mask,
                         holidays: holidays(in: args, from: 3))
        }
    }

    // MARK: - Stepping

    /// `WORKDAY.INTL(start_date, days, [weekend], [holidays])` — a date a number of
    /// working days away, for a week that rests on other days.
    ///
    /// **The start date is not counted and is not snapped.** One working day after a
    /// Saturday is the Monday; zero working days after a Saturday is that Saturday,
    /// unchanged. Excel does not move a weekend start to the nearest working day, and code
    /// written on the assumption that it does is wrong twice a week.
    public static let workdayINTL = ExcelFunction(
        name: "WORKDAY.INTL", minArgs: 2, maxArgs: 4
    ) { args in
        if let error = firstError(args) { return error }
        guard let start = serial(args[0]), let days = number(args[1]) else { return .error(.value) }
        let weekend = args.count > 2 ? WeekendMask.reading(args[2]) : .mask(.saturdaySunday)
        switch weekend {
        case .refusal(let error): return .error(error)
        case .mask(let mask):
            return step(from: start, by: Int(days), weekend: mask,
                        holidays: holidays(in: args, from: 3))
        }
    }

    // MARK: - The two operations, once each

    /// Working days in a closed interval.
    ///
    /// - Parameters:
    ///   - start: The first serial, which is counted.
    ///   - end: The last serial, which is counted too.
    ///   - weekend: Which days do not work.
    ///   - holidays: Serials to skip whatever day they fall on.
    /// - Returns: The count, negative when `start` is after `end`.
    static func count(from start: Int, to end: Int,
                      weekend: WeekendMask, holidays: Set<Int>) -> CellValue {
        let low = Swift.min(start, end)
        let high = Swift.max(start, end)
        guard low >= 1 else { return .error(.num) }
        var counted = 0
        for serial in low...high where !weekend.isWeekend(serial) && !holidays.contains(serial) {
            counted += 1
        }
        return .number(Double(start <= end ? counted : -counted))
    }

    /// The serial a number of working days from another.
    ///
    /// - Parameters:
    ///   - start: The starting serial, which is not counted.
    ///   - days: How many working days to move, signed.
    ///   - weekend: Which days do not work.
    ///   - holidays: Serials to skip whatever day they fall on.
    /// - Returns: The serial reached, or `#NUM!` if the walk runs past Excel's calendar.
    static func step(from start: Int, by days: Int,
                     weekend: WeekendMask, holidays: Set<Int>) -> CellValue {
        guard start >= 1 else { return .error(.num) }
        guard days != 0 else { return .number(Double(start)) }
        let stride = days > 0 ? 1 : -1
        var remaining = Swift.abs(days)
        var serial = start
        // Bounded by Excel's own calendar rather than by trust: a caller asking for a
        // million working days should get #NUM!, and a mask with no working day in it
        // would otherwise never terminate.
        var steps = 0
        while remaining > 0 && steps < Self.calendarLength {
            steps += 1
            serial += stride
            guard serial >= 1 else { return .error(.num) }
            if !weekend.isWeekend(serial) && !holidays.contains(serial) { remaining -= 1 }
        }
        guard remaining == 0 else { return .error(.num) }
        return .number(Double(serial))
    }

    /// Serial 2,958,465 is 31 December 9999, the last date Excel has.
    private static let calendarLength = 2_958_465

    // MARK: - Arguments

    /// The holidays named from a given argument onwards.
    ///
    /// - Parameters:
    ///   - args: The call's arguments.
    ///   - index: Where the holidays argument sits, which differs between the plain and
    ///     `.INTL` spellings.
    /// - Returns: The serials, with anything that is not a number ignored — Excel accepts
    ///   a range with blanks in it, which is what a holiday list on a sheet always has.
    private static func holidays(in args: [CellValue], from index: Int) -> Set<Int> {
        guard args.count > index else { return [] }
        var serials: Set<Int> = []
        for value in flattened(args[index]) {
            if let serial = serial(value) { serials.insert(serial) }
        }
        return serials
    }

    /// A value as an Excel serial, truncated to a whole day.
    private static func serial(_ value: CellValue) -> Int? {
        guard let number = number(value) else { return nil }
        guard number.isFinite, number >= 0, number < Double(calendarLength) else { return nil }
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

    /// An argument's elements, flattened.
    private static func flattened(_ value: CellValue) -> [CellValue] {
        if case .array(let matrix) = value { return matrix.elements }
        return [value]
    }

    /// The first argument that is an error, if any.
    private static func firstError(_ args: [CellValue]) -> CellValue? {
        for argument in args {
            if case .error = argument { return argument }
        }
        return nil
    }
}

/// Which days of the week do not work.
///
/// Stored as the set of Excel weekday numbers — 1 for Sunday through 7 for Saturday, the
/// numbering `WEEKDAY` uses with no type argument — because that is what a serial converts
/// to arithmetically. The *input* spellings both read Monday-first, and the conversion
/// happens once, here.
struct WeekendMask: Sendable, Equatable {

    /// The Excel weekday numbers that do not work, 1 = Sunday … 7 = Saturday.
    let days: Set<Int>

    /// The default everywhere: Saturday and Sunday.
    static let saturdaySunday = WeekendMask(days: [1, 7])

    /// Whether a serial falls on a non-working day.
    ///
    /// - Parameter serial: An Excel date serial.
    /// - Returns: `true` when that date is a weekend under this mask.
    func isWeekend(_ serial: Int) -> Bool {
        days.contains(Self.weekdayNumber(of: serial))
    }

    /// The weekday of a serial, 1 = Sunday through 7 = Saturday.
    ///
    /// Arithmetic rather than a `Calendar`, for the same reason `WEEKDAY` is: Excel's
    /// serials contain a phantom 29 February 1900, so a real calendar disagrees with them
    /// for the first two months of the epoch. Serial 1 is 1 January 1900, which Excel calls
    /// a Sunday.
    ///
    /// - Parameter serial: An Excel date serial.
    /// - Returns: The weekday number.
    static func weekdayNumber(of serial: Int) -> Int {
        ((serial % 7) + 6) % 7 + 1
    }

    /// Reads the weekend argument, in either of its two spellings.
    ///
    /// - Parameter value: The argument as written.
    /// - Returns: The mask, or the error Excel gives.
    static func reading(_ value: CellValue) -> WeekendReading {
        // Text is a mask and a number is a code, with no crossing over. `"0000011"` reads
        // as the number 11 if given the chance — Saturday and Sunday spelled out becomes
        // "Sunday only", a plausible answer four days a week — so the type of the
        // argument decides, not what it looks like.
        if case .text(let text) = value { return mask(fromString: text) }
        guard let number = numeric(value), number.isFinite, number.magnitude < 1e9 else {
            return .refusal(.value)
        }
        return mask(fromCode: Int(number))
    }

    /// The numbered weekends, which is what Excel's own dialog writes.
    ///
    /// | Code | Days off | | Code | Days off |
    /// |---|---|---|---|---|
    /// | 1 | Saturday, Sunday | | 11 | Sunday |
    /// | 2 | Sunday, Monday | | 12 | Monday |
    /// | 3 | Monday, Tuesday | | 13 | Tuesday |
    /// | 4 | Tuesday, Wednesday | | 14 | Wednesday |
    /// | 5 | Wednesday, Thursday | | 15 | Thursday |
    /// | 6 | Thursday, Friday | | 16 | Friday |
    /// | 7 | Friday, Saturday | | 17 | Saturday |
    ///
    /// The 1–7 block is consecutive *pairs* walking forward from the weekend everybody
    /// means; the 11–17 block is single days walking forward from Sunday. There is no
    /// code 8, 9 or 10, and asking for one is `#NUM!`.
    ///
    /// - Parameter code: The number as written.
    /// - Returns: The mask, or `#NUM!`.
    private static func mask(fromCode code: Int) -> WeekendReading {
        // Monday-first index of the first day off, for each block.
        let pairs = [1: 5, 2: 6, 3: 0, 4: 1, 5: 2, 6: 3, 7: 4]
        if let first = pairs[code] {
            return .mask(WeekendMask(days: [excelWeekday(mondayFirst: first),
                                            excelWeekday(mondayFirst: (first + 1) % 7)]))
        }
        let singles = [11: 6, 12: 0, 13: 1, 14: 2, 15: 3, 16: 4, 17: 5]
        if let only = singles[code] {
            return .mask(WeekendMask(days: [excelWeekday(mondayFirst: only)]))
        }
        return .refusal(.num)
    }

    /// The seven-character mask, Monday first, `1` for a day that does **not** work.
    ///
    /// - Parameter text: The argument as written.
    /// - Returns: The mask, or `#VALUE!` for the wrong length, a character that is neither
    ///   `0` nor `1`, or a week with no working day in it at all.
    private static func mask(fromString text: String) -> WeekendReading {
        let characters = Array(text)
        guard characters.count == 7 else { return .refusal(.value) }
        var days: Set<Int> = []
        for (index, character) in characters.enumerated() {
            switch character {
            case "1": days.insert(excelWeekday(mondayFirst: index))
            case "0": break
            default: return .refusal(.value)
            }
        }
        // Excel refuses a week that never works rather than answering zero, and refusing
        // is also what keeps `WORKDAY.INTL` from walking the calendar to its end.
        guard days.count < 7 else { return .refusal(.value) }
        return .mask(WeekendMask(days: days))
    }

    /// Converts a Monday-first index into Excel's Sunday-first weekday number.
    ///
    /// - Parameter index: 0 for Monday through 6 for Sunday.
    /// - Returns: 1 for Sunday through 7 for Saturday.
    private static func excelWeekday(mondayFirst index: Int) -> Int {
        (index + 1) % 7 + 1
    }

    /// A value as a number, when it is one.
    private static func numeric(_ value: CellValue) -> Double? {
        switch value {
        case .number(let number): return number
        case .bool(let flag): return flag ? 1 : 0
        case .formula(_, let cached): return cached.flatMap(numeric)
        default: return nil
        }
    }
}

/// What reading the weekend argument produced.
///
/// A two-case enum rather than `Result`, because ``ExcelError`` is a `CellValue`'s payload
/// rather than a Swift `Error` — and making it one so that `Result` could carry it would
/// change a public type of SwiftExcelCore's to suit one private function here.
enum WeekendReading: Sendable, Equatable {

    /// The argument named a weekend.
    case mask(WeekendMask)

    /// The argument named nothing Excel accepts, and this is the error it gives.
    case refusal(ExcelError)
}
