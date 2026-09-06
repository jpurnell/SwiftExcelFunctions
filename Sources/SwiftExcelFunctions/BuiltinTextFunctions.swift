import Foundation
import SwiftExcelCore

/// Text category built-in Excel functions.
///
/// Provides implementations of 9 standard Excel text functions:
/// `LEN`, `LEFT`, `RIGHT`, `MID`, `TRIM`, `UPPER`, `LOWER`, `CONCATENATE`, and `TEXT`.
///
/// Register all functions at once via ``all``:
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinTextFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinTextFunctions {

    /// All text functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        len, left, right, mid, trim, upper, lower, concatenate, text,
        find, search, substitute, proper, clean, numbervalue,
    ]

    // MARK: - Type coercion

    /// Coerces a `CellValue` to a `String` using Excel text-function semantics.
    ///
    /// - Numbers: string representation via `String(n)` with integer formatting for whole numbers
    /// - Bools: `"TRUE"` / `"FALSE"`
    /// - Blanks: `""`
    /// - Errors: propagated
    ///
    /// - Parameter value: The cell value to convert.
    /// - Returns: The string representation.
    /// - Throws: ``EvalError`` on error values.
    private static func toString(_ value: CellValue) throws -> String {
        switch value {
        case .text(let s):
            return s
        case .number(let n):
            return formatNumber(n)
        case .bool(let b):
            return b ? "TRUE" : "FALSE"
        case .blank:
            return ""
        case .error(let e):
            throw EvalError.excelError(e)
        case .date(let d):
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.string(from: d)
        case .formula(_, let cached):
            return try toString(cached ?? .blank)
        case .array:
            throw EvalError.typeMismatch
        }
    }

    /// Formats a Double as a string, using integer format for whole numbers.
    private static func formatNumber(_ n: Double) -> String {
        if n == n.rounded(.towardZero) && !n.isInfinite && !n.isNaN {
            let intVal = Int(exactly: n)
            if let intVal {
                return String(intVal)
            }
        }
        return String(n)
    }

    /// Extracts a `Double` from a `CellValue`, applying Excel-style type coercion.
    private static func toNumber(_ value: CellValue) throws -> Double {
        switch value {
        case .number(let n):
            return n
        case .text(let s):
            guard let n = Double(s) else {
                throw EvalError.typeMismatch
            }
            return n
        case .bool(let b):
            return b ? 1.0 : 0.0
        case .blank:
            return 0.0
        case .error(let e):
            throw EvalError.excelError(e)
        case .date(let d):
            return d.timeIntervalSinceReferenceDate / 86_400.0
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

    // MARK: - LEN

    /// `LEN(text)` -- returns the number of characters in a text string.
    static let len = ExcelFunction(name: "LEN", minArgs: 1, maxArgs: 1) { args in
        catching {
            let s = try toString(args[0])
            return .number(Double(s.count))
        }
    }

    // MARK: - LEFT

    /// `LEFT(text, [num_chars])` -- returns the leftmost characters from a text string.
    ///
    /// `num_chars` defaults to 1 if omitted.
    static let left = ExcelFunction(name: "LEFT", minArgs: 1, maxArgs: 2) { args in
        catching {
            let s = try toString(args[0])
            let count: Int
            if args.count > 1 {
                let n = try toNumber(args[1])
                guard n >= 0 else { throw EvalError.numError }
                count = Int(n)
            } else {
                count = 1
            }
            let endIndex = s.index(s.startIndex, offsetBy: Swift.min(count, s.count))
            return .text(String(s[s.startIndex..<endIndex]))
        }
    }

    // MARK: - RIGHT

    /// `RIGHT(text, [num_chars])` -- returns the rightmost characters from a text string.
    ///
    /// `num_chars` defaults to 1 if omitted.
    static let right = ExcelFunction(name: "RIGHT", minArgs: 1, maxArgs: 2) { args in
        catching {
            let s = try toString(args[0])
            let count: Int
            if args.count > 1 {
                let n = try toNumber(args[1])
                guard n >= 0 else { throw EvalError.numError }
                count = Int(n)
            } else {
                count = 1
            }
            let actual = Swift.min(count, s.count)
            let startIndex = s.index(s.endIndex, offsetBy: -actual)
            return .text(String(s[startIndex..<s.endIndex]))
        }
    }

    // MARK: - MID

    /// `MID(text, start_num, num_chars)` -- returns characters from the middle of a text string.
    ///
    /// `start_num` is 1-based. Returns `#VALUE!` if `start_num` < 1 or `num_chars` < 0.
    static let mid = ExcelFunction(name: "MID", minArgs: 3, maxArgs: 3) { args in
        catching {
            let s = try toString(args[0])
            let startNum = try toNumber(args[1])
            let numChars = try toNumber(args[2])
            guard startNum >= 1 else { throw EvalError.numError }
            guard numChars >= 0 else { throw EvalError.numError }
            let startIdx = Int(startNum) - 1 // Convert to 0-based
            let count = Int(numChars)
            guard startIdx < s.count else { return .text("") }
            let start = s.index(s.startIndex, offsetBy: startIdx)
            let end = s.index(start, offsetBy: Swift.min(count, s.count - startIdx))
            return .text(String(s[start..<end]))
        }
    }

    // MARK: - TRIM

    /// `TRIM(text)` -- removes leading and trailing spaces and collapses internal
    /// runs of spaces to single spaces.
    static let trim = ExcelFunction(name: "TRIM", minArgs: 1, maxArgs: 1) { args in
        catching {
            let s = try toString(args[0])
            // Split on spaces, filter empties, rejoin
            let words = s.split(separator: " ", omittingEmptySubsequences: true)
            return .text(words.joined(separator: " "))
        }
    }

    // MARK: - UPPER

    /// `UPPER(text)` -- converts text to uppercase.
    static let upper = ExcelFunction(name: "UPPER", minArgs: 1, maxArgs: 1) { args in
        catching {
            let s = try toString(args[0])
            return .text(s.uppercased())
        }
    }

    // MARK: - LOWER

    /// `LOWER(text)` -- converts text to lowercase.
    static let lower = ExcelFunction(name: "LOWER", minArgs: 1, maxArgs: 1) { args in
        catching {
            let s = try toString(args[0])
            return .text(s.lowercased())
        }
    }

    // MARK: - CONCATENATE

    /// `CONCATENATE(text1, [text2], ...)` -- joins all arguments as strings.
    ///
    /// All arguments are coerced to strings before joining.
    static let concatenate = ExcelFunction(name: "CONCATENATE", minArgs: 1, maxArgs: nil) { args in
        catching {
            var result = ""
            for arg in args {
                result += try toString(arg)
            }
            return .text(result)
        }
    }

    // MARK: - TEXT

    /// `TEXT(value, format_text)` -- formats a number as a string using a format code.
    ///
    /// Supported format codes:
    /// - `"0"` — integer, no decimals
    /// - `"0.00"` — 2 decimal places
    /// - `"0.0"` — 1 decimal place (and other `0.0+` patterns)
    /// - `"#,##0"` — thousands separator, no decimals
    /// - `"#,##0.00"` — thousands separator, 2 decimals
    /// - `"0%"` — percentage, no decimals
    /// - `"0.00%"` — percentage, 2 decimals
    ///
    /// For unsupported formats, returns `String(number)`.
    static let text = ExcelFunction(name: "TEXT", minArgs: 2, maxArgs: 2) { args in
        catching {
            let n = try toNumber(args[0])
            let fmt = try toString(args[1])
            return .text(applyFormat(n, fmt))
        }
    }

    /// Applies an Excel-style number format to a Double.
    ///
    /// - Parameters:
    ///   - number: The numeric value to format.
    ///   - format: The format string.
    /// - Returns: The formatted string.
    private static func applyFormat(_ number: Double, _ format: String) -> String {
        // Percentage formats
        if format.hasSuffix("%") {
            let pct = number * 100
            let fmtWithoutPercent = String(format.dropLast())
            let decimals = decimalPlaces(from: fmtWithoutPercent) ?? 0
            return formatDecimal(pct, decimals: decimals) + "%"
        }

        // Thousands separator formats
        if format.contains(",") {
            let decimals = decimalPlaces(from: format) ?? 0
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = decimals
            formatter.maximumFractionDigits = decimals
            formatter.groupingSeparator = ","
            formatter.decimalSeparator = "."
            return formatter.string(from: NSNumber(value: number)) ?? formatNumber(number)
        }

        // Plain decimal formats like "0", "0.00", "0.0"
        if let decimals = decimalPlaces(from: format) {
            return formatDecimal(number, decimals: decimals)
        }

        // Fallback
        return formatNumber(number)
    }

    /// Formats a number with the specified number of decimal places.
    private static func formatDecimal(_ value: Double, decimals: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        formatter.groupingSeparator = ""
        formatter.decimalSeparator = "."
        return formatter.string(from: NSNumber(value: value)) ?? formatNumber(value)
    }

    /// Extracts the number of decimal places from a format string like `"0.00"` or `"0"`.
    ///
    /// - Parameter format: The format string.
    /// - Returns: The number of decimal digits, or `nil` if the format is unrecognized.
    private static func decimalPlaces(from format: String) -> Int? {
        // Remove non-format characters (like #, commas)
        let cleaned = format.replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: ",", with: "")
        if cleaned == "0" { return 0 }
        guard cleaned.hasPrefix("0.") else { return nil }
        let afterDot = cleaned.dropFirst(2)
        guard afterDot.allSatisfy({ $0 == "0" }) else { return nil }
        return afterDot.count
    }

    // MARK: - Searching

    /// `FIND(find_text, within_text, [start_num])` — where one string sits inside
    /// another, counting from 1.
    ///
    /// Case-**sensitive**, and takes no wildcards. `SEARCH` is the other way round on
    /// both counts, which is the whole reason both exist; picking the wrong one is a
    /// bug that only shows up on data you did not test with.
    ///
    /// `#VALUE!` when the text is not there, when `start_num` is below 1, and when it
    /// is past the end of the string. An empty `find_text` matches at `start_num`,
    /// because there is a nothing at every position.
    public static let find = ExcelFunction(name: "FIND", minArgs: 2, maxArgs: 3) { args in
        try locate(args, caseSensitive: true, wildcards: false)
    }

    /// `SEARCH(find_text, within_text, [start_num])` — like ``find``, but
    /// case-insensitive and taking wildcards.
    ///
    /// `?` matches any single character and `*` any run of them, including none. A
    /// literal `?` or `*` is written `~?` or `~*`.
    public static let search = ExcelFunction(name: "SEARCH", minArgs: 2, maxArgs: 3) { args in
        try locate(args, caseSensitive: false, wildcards: true)
    }

    /// The shared body of ``find`` and ``search``.
    ///
    /// - Parameters:
    ///   - args: The function's arguments.
    ///   - caseSensitive: Whether case matters.
    ///   - wildcards: Whether `?` and `*` are patterns rather than characters.
    /// - Returns: The 1-based position, or `#VALUE!`.
    private static func locate(
        _ args: [CellValue], caseSensitive: Bool, wildcards: Bool
    ) throws -> CellValue {
        if let error = firstError(args) { return error }
        let needle = try toString(args[0])
        let haystack = try toString(args[1])
        var start = 1
        if args.count > 2 {
            start = Int(try toNumber(args[2]))
        }
        let characters = Array(haystack)
        guard start >= 1, start <= Swift.max(characters.count, 1) else { return .error(.value) }
        // An empty needle is found immediately: there is a nothing at every position.
        guard !needle.isEmpty else { return .number(Double(start)) }

        let from = start - 1
        guard from <= characters.count else { return .error(.value) }
        let subject = caseSensitive ? haystack : haystack.lowercased()
        let pattern = caseSensitive ? needle : needle.lowercased()
        let subjectCharacters = Array(subject)

        for offset in from..<subjectCharacters.count {
            if wildcards {
                if wildcardMatch(Array(pattern), subjectCharacters, at: offset) {
                    return .number(Double(offset + 1))
                }
            } else if subjectCharacters[offset...].starts(with: Array(pattern)) {
                return .number(Double(offset + 1))
            }
        }
        return .error(.value)
    }

    /// Whether a wildcard pattern matches the subject starting at an offset.
    ///
    /// Recursive on the pattern, and bounded by it: every branch consumes a pattern
    /// character, so the recursion cannot outlive the pattern's length.
    ///
    /// - Parameters:
    ///   - pattern: The pattern, as characters. `?` is any one, `*` is any run,
    ///     `~` escapes the next character.
    ///   - subject: The string being searched.
    ///   - offset: Where in the subject to start.
    /// - Returns: Whether the pattern matches from there.
    private static func wildcardMatch(
        _ pattern: [Character], _ subject: [Character], at offset: Int
    ) -> Bool {
        guard let first = pattern.first else { return true }
        if first == "*" {
            let rest = Array(pattern.dropFirst())
            for end in offset...subject.count where wildcardMatch(rest, subject, at: end) {
                return true
            }
            return false
        }
        guard offset < subject.count else { return false }
        if first == "~", pattern.count > 1 {
            guard subject[offset] == pattern[1] else { return false }
            return wildcardMatch(Array(pattern.dropFirst(2)), subject, at: offset + 1)
        }
        guard first == "?" || subject[offset] == first else { return false }
        return wildcardMatch(Array(pattern.dropFirst()), subject, at: offset + 1)
    }

    // MARK: - Replacing

    /// `SUBSTITUTE(text, old_text, new_text, [instance_num])` — replaces text by
    /// content rather than by position.
    ///
    /// Case-sensitive. Without `instance_num` every occurrence goes; with it, only
    /// that one, counting from 1. An instance beyond the count changes nothing rather
    /// than erroring — Excel treats "replace the fifth of three" as a no-op.
    ///
    /// An empty `old_text` also changes nothing. There is a nothing between every
    /// pair of characters, and replacing all of them would be an unbounded answer to
    /// a question nobody meant to ask.
    public static let substitute = ExcelFunction(
        name: "SUBSTITUTE", minArgs: 3, maxArgs: 4
    ) { args in
        if let error = firstError(args) { return error }
        let subject = try toString(args[0])
        let old = try toString(args[1])
        let new = try toString(args[2])
        guard !old.isEmpty else { return .text(subject) }

        guard args.count > 3 else {
            return .text(subject.replacingOccurrences(of: old, with: new))
        }
        let instance = Int(try toNumber(args[3]))
        guard instance >= 1 else { return .error(.value) }

        var result = ""
        var remaining = Substring(subject)
        var seen = 0
        while let range = remaining.range(of: old) {
            seen += 1
            result += remaining[remaining.startIndex..<range.lowerBound]
            result += (seen == instance) ? new : old
            remaining = remaining[range.upperBound...]
            if seen == instance { break }
        }
        return .text(result + remaining)
    }

    // MARK: - Tidying

    /// `PROPER(text)` — capitalises the first letter of each word.
    ///
    /// A letter starts a word when the character before it is not a letter, which is
    /// why Excel renders `2-cent's worth` as `2-Cent'S Worth`. That looks like a bug
    /// and is the documented behaviour; matching it is the point.
    public static let proper = ExcelFunction(name: "PROPER", minArgs: 1, maxArgs: 1) { args in
        if let error = firstError(args) { return error }
        let subject = try toString(args[0])
        var result = ""
        var previousWasLetter = false
        for character in subject {
            if character.isLetter {
                result.append(previousWasLetter
                    ? Character(character.lowercased())
                    : Character(character.uppercased()))
            } else {
                result.append(character)
            }
            previousWasLetter = character.isLetter
        }
        return .text(result)
    }

    /// `CLEAN(text)` — removes the non-printing characters.
    ///
    /// The first 32 in ASCII, which is what Excel documents: the control codes that
    /// arrive with text pasted out of another system and show up as boxes.
    public static let clean = ExcelFunction(name: "CLEAN", minArgs: 1, maxArgs: 1) { args in
        if let error = firstError(args) { return error }
        let subject = try toString(args[0])
        return .text(String(subject.unicodeScalars.filter { $0.value >= 32 }))
    }

    /// `NUMBERVALUE(text, [decimal_separator], [group_separator])` — reads a number
    /// from text using the separators it is given.
    ///
    /// The point of it is that the separators are stated rather than inherited from
    /// the machine, so `2.500,27` reads as two and a half thousand wherever the sheet
    /// is opened. `VALUE` asks the locale; this asks the caller.
    ///
    /// Empty text is 0. Anything that is not a number is `#VALUE!`.
    public static let numbervalue = ExcelFunction(
        name: "NUMBERVALUE", minArgs: 1, maxArgs: 3
    ) { args in
        if let error = firstError(args) { return error }
        let subject = try toString(args[0]).trimmingCharacters(in: .whitespaces)
        guard !subject.isEmpty else { return .number(0) }

        let decimal = args.count > 1 ? try toString(args[1]) : "."
        let group = args.count > 2 ? try toString(args[2]) : ","
        var cleaned = subject
        if !group.isEmpty { cleaned = cleaned.replacingOccurrences(of: group, with: "") }
        if !decimal.isEmpty, decimal != "." {
            cleaned = cleaned.replacingOccurrences(of: decimal, with: ".")
        }
        // Excel reads a trailing percent sign and divides accordingly.
        var scale = 1.0
        while cleaned.hasSuffix("%") {
            cleaned.removeLast()
            scale /= 100
        }
        guard let value = Double(cleaned) else { return .error(.value) }
        return .number(value * scale)
    }

    /// The first argument that is an error, if any.
    ///
    /// Excel propagates an error through a function rather than absorbing it.
    ///
    /// - Parameter args: The arguments as evaluated.
    /// - Returns: The error to propagate, or `nil`.
    private static func firstError(_ args: [CellValue]) -> CellValue? {
        for argument in args {
            if case .error = argument { return argument }
        }
        return nil
    }
}
