import Foundation
import SwiftExcelCore

/// Excel's date and time format codes, for `TEXT`.
///
/// ## Why this exists
///
/// `TEXT` handled number formats and nothing else, so `TEXT(41583, "ddd")` returned
/// `"41583"` where Excel returns `"Tue"` — the serial, formatted as a number, because no
/// branch recognised the code. The oracle found 127 cells doing exactly that across 46 real
/// workbooks, every one of them `"ddd"`.
///
/// ## Two things that are easy to get wrong
///
/// **`m` means minute or month depending on what surrounds it.** After an hour code, or
/// before a seconds code, it is minutes; otherwise months. `"h:mm"` and `"mm/dd"` use the
/// same two characters for different things, and reading them the same way is wrong in one
/// case without ever looking wrong.
///
/// **The weekday comes from the serial, not from a `Calendar`.** `WEEKDAY` already computes
/// it as `((serial % 7) + 6) % 7 + 1`, which is exact for every serial including Excel's
/// phantom 29 February 1900 — the bug lives in the serial numbering itself, so arithmetic on
/// serials inherits it correctly and a real calendar does not. Two routes to a weekday that
/// could disagree is the failure this package exists to prevent, and it is not hypothetical:
/// `IMPOWER` and `IMPRODUCT` disagreed about `i²` for exactly that reason.
enum ExcelDateFormat {

    /// Weekday names, Sunday first, matching the serial arithmetic's 1 = Sunday.
    private static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday",
                                   "Thursday", "Friday", "Saturday"]

    /// Month names, January first.
    private static let months = ["January", "February", "March", "April", "May", "June",
                                 "July", "August", "September", "October", "November",
                                 "December"]

    /// Whether a format code asks for a date or a time at all.
    ///
    /// Number formats are digits and punctuation — `0`, `#`, `,`, `.`, `%` — so any of the
    /// date letters outside a quoted run settles it.
    ///
    /// - Parameter format: The format code.
    /// - Returns: `true` if it should be read as a date format.
    static func isDateFormat(_ format: String) -> Bool {
        var quoted = false
        for character in format {
            if character == "\"" { quoted.toggle(); continue }
            guard !quoted else { continue }
            if "dmyhsDMYHS".contains(character) { return true }
        }
        return false
    }

    /// Formats an Excel serial number against a date format code.
    ///
    /// - Parameters:
    ///   - serial: The serial, whose whole part is the day and fraction the time.
    ///   - format: The format code.
    /// - Returns: The formatted text, or `nil` if the serial is not a date Excel can show.
    static func format(serial: Double, _ format: String) -> String? {
        let days = Int(serial.rounded(.down))
        guard days >= 1 else { return nil }
        let (year, month, day) = BuiltinDateTimeFunctions.serialToComponents(days)

        // The same arithmetic `WEEKDAY` uses: 1 = Sunday.
        let weekday = ((days % 7) + 6) % 7

        // The fraction is the time of day. Rounded to the second, as Excel shows it.
        let fraction = serial - Double(days)
        let secondsInDay = Int((fraction * 86400).rounded())
        let hour24 = min(23, secondsInDay / 3600)
        let minute = (secondsInDay % 3600) / 60
        let second = secondsInDay % 60

        let tokens = tokenize(format)
        let usesTwelveHour = tokens.contains { $0.lowercased().hasPrefix("am/pm") }
        var out = ""
        for (index, token) in tokens.enumerated() {
            out += render(token, at: index, in: tokens,
                          year: year, month: month, day: day, weekday: weekday,
                          hour24: hour24, minute: minute, second: second,
                          twelveHour: usesTwelveHour)
        }
        return out
    }

    // MARK: - Reading the code

    /// Splits a format code into runs of one repeated letter, quoted literals, and
    /// everything else a character at a time.
    private static func tokenize(_ format: String) -> [String] {
        var tokens: [String] = []
        var characters = Array(format)
        var index = 0
        // Bounded: `index` strictly increases on every branch.
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                var literal = ""
                index += 1
                while index < characters.count, characters[index] != "\"" {
                    literal.append(characters[index])
                    index += 1
                }
                index += 1
                tokens.append("\"" + literal)
                continue
            }
            let lower = Character(character.lowercased())
            if "dmyhs".contains(lower) {
                var run = ""
                while index < characters.count,
                      Character(characters[index].lowercased()) == lower {
                    run.append(characters[index])
                    index += 1
                }
                tokens.append(run)
                continue
            }
            // AM/PM, in either spelling Excel accepts. Longest first: `AM/PM` begins with
            // the same letter as `A/P`, and matching the short one would leave `M/PM`.
            let rest = String(characters[index...])
            if let marker = ["AM/PM", "am/pm", "A/P", "a/p"].first(where: rest.hasPrefix) {
                tokens.append(marker)
                index += marker.count
                continue
            }
            tokens.append(String(character))
            index += 1
        }
        return tokens
    }

    /// Whether an `m` run means minutes rather than months.
    ///
    /// Excel's rule: minutes when the code follows an hour code or precedes a seconds code,
    /// ignoring anything that is not a date letter in between.
    private static func meansMinutes(at index: Int, in tokens: [String]) -> Bool {
        func letter(_ token: String) -> Character? {
            guard let first = token.first, !token.hasPrefix("\"") else { return nil }
            let lower = Character(first.lowercased())
            return "dmyhs".contains(lower) ? lower : nil
        }
        for previous in tokens[..<index].reversed() {
            guard let kind = letter(previous) else { continue }
            if kind == "h" { return true }
            break
        }
        for next in tokens[(index + 1)...] {
            guard let kind = letter(next) else { continue }
            if kind == "s" { return true }
            break
        }
        return false
    }

    // MARK: - Writing it out

    private static func render(
        _ token: String, at index: Int, in tokens: [String],
        year: Int, month: Int, day: Int, weekday: Int,
        hour24: Int, minute: Int, second: Int, twelveHour: Bool
    ) -> String {
        if token.hasPrefix("\"") { return String(token.dropFirst()) }
        switch token.lowercased() {
        case "yyyy", "yyy": return padded(year, to: 4)
        case "yy", "y": return padded(year % 100, to: 2)
        case "mmmmm": return String(months[safe: month - 1]?.prefix(1) ?? "")
        case "mmmm": return months[safe: month - 1] ?? ""
        case "mmm": return String(months[safe: month - 1]?.prefix(3) ?? "")
        case "mm":
            return meansMinutes(at: index, in: tokens) ? padded(minute, to: 2)
                                                       : padded(month, to: 2)
        case "m":
            return meansMinutes(at: index, in: tokens) ? String(minute) : String(month)
        case "dddd": return weekdays[safe: weekday] ?? ""
        case "ddd": return String(weekdays[safe: weekday]?.prefix(3) ?? "")
        case "dd": return padded(day, to: 2)
        case "d": return String(day)
        case "hh": return padded(twelveHour ? hourIn12(hour24) : hour24, to: 2)
        case "h": return String(twelveHour ? hourIn12(hour24) : hour24)
        case "ss": return padded(second, to: 2)
        case "s": return String(second)
        case "am/pm": return hour24 < 12 ? "AM" : "PM"
        case "a/p": return hour24 < 12 ? "A" : "P"
        default: return token
        }
    }

    /// Twelve-hour clock, where midnight and noon are both 12 rather than 0.
    private static func hourIn12(_ hour24: Int) -> Int {
        let hour = hour24 % 12
        return hour == 0 ? 12 : hour
    }

    private static func padded(_ value: Int, to width: Int) -> String {
        let digits = String(value)
        guard digits.count < width else { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}

private extension Array {
    /// The element at an index, or `nil` where the index is outside the array.
    ///
    /// A month of 13 or a weekday of 7 would be a defect upstream, and trapping on it inside
    /// a formatter turns a wrong number into a crashed process.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
