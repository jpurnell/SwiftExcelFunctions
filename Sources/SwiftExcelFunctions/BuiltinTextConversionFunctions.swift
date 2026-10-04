import Foundation
import SwiftExcelCore

/// Turning values into text, text into values, and text into pieces.
///
/// | Function | What it does |
/// |---|---|
/// | `DOLLAR` | a number as currency text, rounded to the places asked for |
/// | `VALUETOTEXT` | one value as text, concisely or strictly |
/// | `ARRAYTOTEXT` | a whole rectangle as text, likewise |
/// | `TEXTSPLIT` | text cut into a rectangle by delimiters |
/// | `REGEXTEST`, `REGEXEXTRACT`, `REGEXREPLACE` | the 2024 regular-expression trio |
///
/// ## Concise and strict
///
/// `VALUETOTEXT` and `ARRAYTOTEXT` both take a `format` argument, and the two modes answer
/// different questions. **Concise** (0, the default) is what a person would read: `TRUE`,
/// `1234.5`, `hello`. **Strict** (1) is what a formula would parse back: text gains quotes,
/// an array gains its braces and separators, and the result could be pasted into a cell.
///
/// The distinction matters because concise mode loses the difference between the number 7
/// and the text "7", and strict mode does not.
public enum BuiltinTextConversionFunctions {

    /// All conversion functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        dollar, valueToText, arrayToText, textSplit,
        regexTest, regexExtract, regexReplace,
    ]

    // MARK: - Currency

    /// `DOLLAR(number, [decimals])` — a number as currency text.
    ///
    /// Rounds rather than truncates, and a **negative** `decimals` rounds to the left of the
    /// point: `DOLLAR(-1234.567, -2)` is `($1,200)`. Negative amounts are written in
    /// parentheses, which is the accounting convention Excel uses here and nowhere else.
    ///
    /// The currency symbol is `$`, without a locale to say otherwise — the same decision
    /// ADR-002 records for the byte functions, and for the same reason: this package models
    /// no locale, and inventing one would be less faithful than admitting it.
    public static let dollar = ExcelFunction(name: "DOLLAR", minArgs: 1, maxArgs: 2) { args in
        if let error = firstError(args) { return error }
        guard let number = numeric(args[0]) else { return .error(.value) }
        let places = args.count > 1 ? numeric(args[1]) : 2
        guard let places, places.isFinite, places.magnitude < 128 else { return .error(.value) }

        let digits = Int(places.rounded(.towardZero))
        let scale = pow(10.0, Double(digits))
        let rounded = (number * scale).rounded() / scale
        let shown = Swift.max(0, digits)

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        // Set explicitly: the POSIX locale leaves grouping off, and `groupingSeparator`
        // alone only says what the separator would be if there were one.
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = shown
        formatter.maximumFractionDigits = shown
        guard let body = formatter.string(from: NSNumber(value: Swift.abs(rounded))) else {
            return .error(.value)
        }
        return .text(rounded < 0 ? "($\(body))" : "$\(body)")
    }

    // MARK: - Values as text

    /// `VALUETOTEXT(value, [format])` — one value as text.
    public static let valueToText = ExcelFunction(
        name: "VALUETOTEXT", minArgs: 1, maxArgs: 2
    ) { args in
        guard let strict = mode(args, at: 1) else { return .error(.value) }
        return .text(describe(args[0].resolved, strict: strict))
    }

    /// `ARRAYTOTEXT(array, [format])` — a rectangle as text.
    ///
    /// Concise mode joins with `", "` and loses the shape. Strict mode writes the array
    /// literal Excel would accept back: `{1,2;3,4}`, comma between columns and semicolon
    /// between rows.
    public static let arrayToText = ExcelFunction(
        name: "ARRAYTOTEXT", minArgs: 1, maxArgs: 2
    ) { args in
        guard let strict = mode(args, at: 1) else { return .error(.value) }
        guard case .array(let matrix) = args[0] else {
            return .text(describe(args[0].resolved, strict: strict))
        }
        guard strict else {
            return .text(matrix.elements.map { describe($0, strict: false) }
                .joined(separator: ", "))
        }
        var rows: [String] = []
        for row in 0..<matrix.rows {
            let cells = (0..<matrix.columns).compactMap { column in
                matrix[row, column]
            }
            rows.append(cells.map { describe($0, strict: true) }.joined(separator: ","))
        }
        return .text("{" + rows.joined(separator: ";") + "}")
    }

    /// The `format` argument: 0 concise, 1 strict.
    ///
    /// - Parameters:
    ///   - args: The call's arguments.
    ///   - index: Where the format sits.
    /// - Returns: Whether strict was asked for, or `nil` for a format that is neither.
    private static func mode(_ args: [CellValue], at index: Int) -> Bool? {
        guard args.count > index else { return false }
        guard let value = numeric(args[index]) else { return nil }
        switch value.rounded(.towardZero) {
        case 0: return false
        case 1: return true
        default: return nil
        }
    }

    /// One value, written out.
    ///
    /// - Parameters:
    ///   - value: The value.
    ///   - strict: Whether to write it so a formula could read it back.
    /// - Returns: Its text.
    static func describe(_ value: CellValue, strict: Bool) -> String {
        switch value {
        case .text(let text): return strict ? "\"\(text)\"" : text
        case .number(let number): return number == number.rounded() && number.magnitude < 1e15
            ? String(Int(number)) : String(number)
        case .bool(let flag): return flag ? "TRUE" : "FALSE"
        case .error(let error): return error.rawValue
        case .blank: return strict ? "\"\"" : ""
        case .date(let date): return describe(
            .number(BuiltinDateTimeFunctions.dateToSerial(date)), strict: strict)
        case .formula(_, let cached): return describe(cached ?? .blank, strict: strict)
        case .lambda: return ExcelError.calc.rawValue
        case .array(let matrix): return matrix.elements
            .map { describe($0, strict: strict) }.joined(separator: ", ")
        }
    }

    // MARK: - Splitting

    /// `TEXTSPLIT(text, col_delimiter, [row_delimiter], [ignore_empty], [match_mode], [pad_with])`
    ///
    /// Cuts text into a rectangle: columns by the first delimiter, rows by the second.
    ///
    /// **Rows are cut first.** `TEXTSPLIT("a,b;c,d", ",", ";")` is a 2×2 rectangle, not a
    /// four-element row, and the row delimiter is the outer one however it is written.
    ///
    /// Ragged rows are padded with `#N/A` unless `pad_with` says otherwise — Excel's answer,
    /// and the one that makes a shape out of text that had none.
    public static let textSplit = ExcelFunction(name: "TEXTSPLIT", minArgs: 2, maxArgs: 6) { args in
        if let error = firstError(args) { return error }
        guard case .text(let text) = args[0].resolved else { return .error(.value) }
        let columnDelimiters = delimiters(args[1])
        let rowDelimiters = args.count > 2 ? delimiters(args[2]) : []
        guard !columnDelimiters.isEmpty || !rowDelimiters.isEmpty else { return .error(.value) }

        let ignoreEmpty = args.count > 3 ? (numeric(args[3]) ?? 0) != 0 : false
        let caseSensitive = args.count > 4 ? (numeric(args[4]) ?? 0) == 0 : true
        let padding = args.count > 5 ? args[5].resolved : .error(.na)

        let lines = rowDelimiters.isEmpty
            ? [text]
            : split(text, on: rowDelimiters, caseSensitive: caseSensitive,
                    ignoreEmpty: ignoreEmpty)
        let grid = lines.map { line in
            columnDelimiters.isEmpty
                ? [line]
                : split(line, on: columnDelimiters, caseSensitive: caseSensitive,
                        ignoreEmpty: ignoreEmpty)
        }
        let width = grid.map(\.count).max() ?? 0
        guard width > 0, !grid.isEmpty else { return .error(.value) }

        var elements: [CellValue] = []
        for row in grid {
            for column in 0..<width {
                elements.append(column < row.count ? .text(row[column]) : padding)
            }
        }
        guard let matrix = CellMatrix(elements: elements, rows: grid.count, columns: width) else {
            return .error(.value)
        }
        return .array(matrix)
    }

    /// The delimiters one argument names, which may be an array of them.
    private static func delimiters(_ value: CellValue) -> [String] {
        switch value.resolved {
        case .text(let text): return text.isEmpty ? [] : [text]
        case .array(let matrix): return matrix.elements.flatMap { delimiters($0) }
        case .blank: return []
        default: return [describe(value.resolved, strict: false)]
        }
    }

    /// Splits text on any of several delimiters.
    ///
    /// - Parameters:
    ///   - text: What to cut.
    ///   - delimiters: The cuts to make, any of which applies.
    ///   - caseSensitive: Whether a delimiter must match in case.
    ///   - ignoreEmpty: Whether to drop the empty pieces two adjacent delimiters leave.
    /// - Returns: The pieces, in order.
    private static func split(
        _ text: String, on delimiters: [String], caseSensitive: Bool, ignoreEmpty: Bool
    ) -> [String] {
        var pieces = [text]
        for delimiter in delimiters where !delimiter.isEmpty {
            pieces = pieces.flatMap { piece in
                caseSensitive
                    ? piece.components(separatedBy: delimiter)
                    : insensitiveSplit(piece, on: delimiter)
            }
        }
        return ignoreEmpty ? pieces.filter { !$0.isEmpty } : pieces
    }

    /// Splits text on a delimiter, ignoring case.
    private static func insensitiveSplit(_ text: String, on delimiter: String) -> [String] {
        guard !delimiter.isEmpty else { return [text] }
        var pieces: [String] = []
        var remainder = Substring(text)
        // Bounded: each step consumes at least the delimiter, which is not empty.
        while let found = remainder.range(of: delimiter, options: .caseInsensitive) {
            pieces.append(String(remainder[remainder.startIndex..<found.lowerBound]))
            remainder = remainder[found.upperBound...]
        }
        pieces.append(String(remainder))
        return pieces
    }

    // MARK: - Regular expressions

    /// The longest text the regular-expression functions will search, in UTF-16 code units.
    ///
    /// Excel's own limit on the text a cell can hold is 32,767 characters, counted the way
    /// `LEN` counts them. Nothing a workbook can put in a cell is longer, so this refuses
    /// nothing Excel accepts — it bounds a host that hands the function text from elsewhere.
    public static let maximumRegexSubjectLength = 32_767

    /// The longest pattern the regular-expression functions will compile, in UTF-16 code units.
    ///
    /// Excel limits a formula's content to 8,192 characters, so no pattern written into a
    /// formula is longer. A pattern read from a cell could reach 32,767, but a pattern is a
    /// program, and one four times the length of any formula is not one a person wrote.
    public static let maximumRegexPatternLength = 8_192

    /// How long one call may spend matching before it gives up with `#VALUE!`.
    ///
    /// The length limits and the shape check leave patterns that are slow rather than
    /// unbounded — quadratic on a long run of digits, say — and on a full-length cell those
    /// run for over a minute. Ordinary patterns finish in microseconds, so a second is
    /// generous; it is a ceiling on the damage, not a budget anything should approach.
    public static let regexMatchDeadline: Duration = .seconds(1)

    /// `REGEXTEST(text, pattern, [case_sensitivity])` — whether the pattern is in the text.
    ///
    /// `#VALUE!` for a pattern that will not compile, and for input outside the bounds
    /// described on ``maximumRegexPatternLength``.
    public static let regexTest = ExcelFunction(name: "REGEXTEST", minArgs: 2, maxArgs: 3) { args in
        withRegex(args) { search in
            guard let matches = search.matches(limit: 1) else { return .error(.value) }
            return .bool(!matches.isEmpty)
        }
    }

    /// `REGEXEXTRACT(text, pattern, [return_mode], [case_sensitivity])` — what matched.
    ///
    /// | `return_mode` | Returns |
    /// |---|---|
    /// | 0 *(default)* | the first match |
    /// | 1 | every match, as a column |
    /// | 2 | the capture groups of the first match, as a row |
    ///
    /// `#N/A` when nothing matched, which is the answer that lets `IFNA` do its job.
    public static let regexExtract = ExcelFunction(
        name: "REGEXEXTRACT", minArgs: 2, maxArgs: 4
    ) { args in
        let mode = args.count > 2 ? (numeric(args[2]).map { Int($0.rounded(.towardZero)) }) : 0
        guard let mode, (0...2).contains(mode) else { return .error(.value) }
        return withRegex(args, caseArgument: 3) { search in
            // Only mode 1 wants more than the first match, so only mode 1 looks for more.
            guard let matches = search.matches(limit: mode == 1 ? nil : 1) else { return .error(.value) }
            guard let first = matches.first else { return .error(.na) }

            switch mode {
            case 1:
                let all = matches.map { CellValue.text(search.piece($0.range)) }
                return .array(CellMatrix(column: all))
            case 2:
                guard first.numberOfRanges > 1 else { return .error(.na) }
                let groups = (1..<first.numberOfRanges).map { CellValue.text(search.piece(first.range(at: $0))) }
                return .array(CellMatrix(row: groups))
            default:
                return .text(search.piece(first.range))
            }
        }
    }

    /// `REGEXREPLACE(text, pattern, replacement, [occurrence], [case_sensitivity])`
    ///
    /// `occurrence` omitted or 0 replaces every match; a positive *n* replaces the *n*th;
    /// a negative *n* counts from the end.
    ///
    /// `#VALUE!` when the replacement, or the text that replacing would produce, is longer
    /// than a cell can hold — the answer `CONCAT` and `REPT` give for the same overflow.
    public static let regexReplace = ExcelFunction(
        name: "REGEXREPLACE", minArgs: 3, maxArgs: 5
    ) { args in
        guard case .text(let replacement) = args[2].resolved else { return .error(.value) }
        guard replacement.utf16.count <= maximumRegexSubjectLength else { return .error(.value) }
        let occurrence = args.count > 3 ? (numeric(args[3]).map { Int($0.rounded(.towardZero)) }) : 0
        guard let occurrence else { return .error(.value) }

        return withRegex(args, caseArgument: 4) { search in
            // A positive occurrence needs no match past its own; the rest need them all.
            guard let matches = search.matches(limit: occurrence > 0 ? occurrence : nil) else {
                return .error(.value)
            }
            guard occurrence != 0 else { return search.replacing(matches, with: replacement) }
            let index = occurrence > 0 ? occurrence - 1 : matches.count + occurrence
            guard matches.indices.contains(index) else { return .text(search.text) }
            return search.replacing([matches[index]], with: replacement)
        }
    }

    /// A compiled pattern and the text it is to search, with matching held to a deadline.
    private struct BoundedSearch {
        let expression: NSRegularExpression
        let text: String

        /// The matches, in order, or `nil` if ``regexMatchDeadline`` passed first.
        ///
        /// - Parameter limit: Stop after this many matches; `nil` for every match.
        /// - Returns: `nil` rather than a partial list when the deadline passed: a caller
        ///   that was told "no match" could not tell it from "did not finish looking".
        func matches(limit: Int?) -> [NSTextCheckingResult]? {
            let deadline = ContinuousClock.now + BuiltinTextConversionFunctions.regexMatchDeadline
            var found: [NSTextCheckingResult] = []
            var expired = false
            let whole = NSRange(text.startIndex..., in: text)
            // `.reportProgress` is what makes the deadline real: the block is also called,
            // with no result, at intervals while a long match is still running.
            expression.enumerateMatches(in: text, options: [.reportProgress], range: whole) { result, _, stop in
                if let result {
                    found.append(result)
                    if let limit, found.count >= limit {
                        stop.pointee = true
                        return
                    }
                }
                if ContinuousClock.now >= deadline {
                    expired = true
                    stop.pointee = true
                }
            }
            return expired ? nil : found
        }

        /// The text a match range covers; empty for a group that took no part in the match.
        func piece(_ range: NSRange) -> String {
            guard let converted = Range(range, in: text) else { return "" }
            return String(text[converted])
        }

        /// The text with each of `matches` replaced by the template, expanded per match.
        ///
        /// - Returns: The new text, or `#VALUE!` once it would be longer than a cell holds.
        ///   The length is checked as the text is built, so an overflowing result is never
        ///   assembled only to be thrown away.
        func replacing(_ matches: [NSTextCheckingResult], with template: String) -> CellValue {
            let source = text as NSString
            let limit = BuiltinTextConversionFunctions.maximumRegexSubjectLength
            var output = ""
            var cursor = 0
            var length = 0
            for match in matches {
                let kept = source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                let replaced = expression.replacementString(for: match, in: text, offset: 0, template: template)
                length += kept.utf16.count + replaced.utf16.count
                guard length <= limit else { return .error(.value) }
                output += kept + replaced
                cursor = match.range.location + match.range.length
            }
            let tail = source.substring(from: cursor)
            guard length + tail.utf16.count <= limit else { return .error(.value) }
            return .text(output + tail)
        }
    }

    /// Builds the expression and hands it to a body, or reports why it could not.
    ///
    /// Three things are refused before anything is compiled, because the pattern is whatever
    /// the workbook says it is: text or a pattern longer than Excel could have held, and a
    /// pattern whose shape makes a backtracking engine exponential (see ``RegexShape``).
    ///
    /// - Parameters:
    ///   - args: The call's arguments, text first and pattern second.
    ///   - caseArgument: Where the case-sensitivity flag sits, if the function has one.
    ///   - body: What to do with the compiled expression.
    /// - Returns: The body's answer, or `#VALUE!` for a pattern that will not compile or an
    ///   input that is refused.
    private static func withRegex(
        _ args: [CellValue], caseArgument: Int = 2,
        _ body: (BoundedSearch) -> CellValue
    ) -> CellValue {
        if let error = firstError(args) { return error }
        guard case .text(let text) = args[0].resolved,
              case .text(let pattern) = args[1].resolved else { return .error(.value) }

        // Microsoft documents no error values for these functions. `#VALUE!` is what this
        // package already answers for a pattern that will not compile, and what Excel answers
        // when text outgrows a cell, so a refusal reads the same as either.
        guard text.utf16.count <= maximumRegexSubjectLength,
              pattern.utf16.count <= maximumRegexPatternLength,
              RegexShape.catastrophicGroups(in: pattern).isEmpty else { return .error(.value) }

        // Excel's flag is *case sensitivity*: 0, the default, is sensitive.
        let sensitive = args.count > caseArgument ? (numeric(args[caseArgument]) ?? 0) == 0 : true
        let options: NSRegularExpression.Options = sensitive ? [] : [.caseInsensitive]
        let expression: NSRegularExpression
        do {
            // SECURITY: the pattern is the workbook's by design; it is at most 8,192 units against at most 32,767 of text, nested repetition is refused above, and matching stops at a one-second deadline.
            expression = try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            // A pattern that will not compile is `#VALUE!`, which is what Excel answers and
            // is the only thing to say: the caller wrote it, the error names a position in
            // a string this package never saw, and there is no partial interpretation worth
            // guessing at.
            return .error(.value)
        }
        return body(BoundedSearch(expression: expression, text: text))
    }

    // MARK: - Shared

    /// A value as a number, when it is one.
    private static func numeric(_ value: CellValue) -> Double? {
        switch value.resolved {
        case .number(let number): return number
        case .bool(let flag): return flag ? 1 : 0
        case .text(let text): return Double(text)
        case .blank: return 0
        default: return nil
        }
    }

    /// The first argument that is an error, propagated rather than absorbed.
    private static func firstError(_ args: [CellValue]) -> CellValue? {
        for argument in args {
            if case .error = argument { return argument }
        }
        return nil
    }
}
