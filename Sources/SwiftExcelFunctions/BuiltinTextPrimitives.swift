import Foundation
import SwiftExcelCore

/// The text primitives — characters, exact comparison, repetition, joining, splitting,
/// positional replacement, and the number/text boundary.
///
/// Thirteen of the thirty-two text rows. The remainder are recorded rather than left
/// unreviewed: the byte-oriented `*B` family and `DBCS`/`JIS`/`PHONETIC` are meaningful
/// only under a double-byte locale, and `DETECTLANGUAGE`/`TRANSLATE` reach a network
/// service, which puts them where the cube and web functions already are.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinTextPrimitives.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinTextPrimitives {

    /// All text primitives for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        char, code, exact, rept, concat, textJoin,
        textBefore, textAfter, replace, tFunction, value, fixed
    ]

    // MARK: - Characters

    /// `CHAR(number)` — the character at a code point, 1 through 255.
    ///
    /// Excel's range is the single-byte set; 0 and 256 are `#VALUE!` rather than a Unicode
    /// scalar, because this function predates Unicode and its callers rely on the bound.
    public static let char = ExcelFunction(name: "CHAR", minArgs: 1, maxArgs: 1) { values in
        if let error = firstError(values) { return error }
        guard let n = real(values.first), n >= 1, n < 256 else { return .error(.value) }
        guard let scalar = Unicode.Scalar(UInt8(n.rounded(.towardZero))) as Unicode.Scalar? else {
            return .error(.value)
        }
        return .text(String(Character(scalar)))
    }

    /// `CODE(text)` — the code of the **first** character.
    ///
    /// Not the inverse of ``char`` over a whole string: `CODE("Alphabet")` is 65, the code
    /// of `A`, and the rest is ignored.
    public static let code = ExcelFunction(name: "CODE", minArgs: 1, maxArgs: 1) { values in
        if let error = firstError(values) { return error }
        guard let text = string(values.first), let first = text.unicodeScalars.first
        else { return .error(.value) }
        return .number(Double(first.value))
    }

    // MARK: - Comparison

    /// `EXACT(text1, text2)` — whether two strings are identical, **case included**.
    ///
    /// The entire reason the function exists: `=` compares case-insensitively in Excel, so
    /// `"Word" = "word"` is TRUE and `EXACT("Word","word")` is FALSE.
    public static let exact = ExcelFunction(name: "EXACT", minArgs: 2, maxArgs: 2) { values in
        if let error = firstError(values) { return error }
        guard let lhs = string(values.first), let rhs = string(values.dropFirst().first)
        else { return .error(.value) }
        return .bool(lhs == rhs)
    }

    // MARK: - Building

    /// `REPT(text, number_times)` — text repeated. Zero times is the empty string.
    public static let rept = ExcelFunction(name: "REPT", minArgs: 2, maxArgs: 2) { values in
        if let error = firstError(values) { return error }
        guard let text = string(values.first), let times = real(values.dropFirst().first),
              times >= 0 else { return .error(.value) }
        return .text(String(repeating: text, count: Int(times.rounded(.towardZero))))
    }

    /// `CONCAT(text1, …)` — everything joined, no separator.
    public static let concat = ExcelFunction(name: "CONCAT", minArgs: 1, maxArgs: nil) { values in
        if let error = firstError(values) { return error }
        return .text(values.compactMap { string($0) }.joined())
    }

    /// `TEXTJOIN(delimiter, ignore_empty, text1, …)` — joined with a separator.
    ///
    /// `ignore_empty` is the argument that earns its place. With `FALSE` an empty value
    /// still contributes a delimiter — `a`, ``, `b` joins to `a--b` — and with `TRUE` it
    /// contributes nothing at all.
    public static let textJoin = ExcelFunction(name: "TEXTJOIN", minArgs: 3, maxArgs: nil) { values in
        if let error = firstError(values) { return error }
        guard let delimiter = string(values.first) else { return .error(.value) }
        let ignoreEmpty: Bool
        switch values[1] {
        case .bool(let b): ignoreEmpty = b
        case .number(let n): ignoreEmpty = n != 0
        default: return .error(.value)
        }

        let parts = values.dropFirst(2).compactMap { string($0) }
        return .text((ignoreEmpty ? parts.filter { !$0.isEmpty } : parts)
            .joined(separator: delimiter))
    }

    // MARK: - Splitting

    /// The index at which the requested instance of a delimiter begins.
    ///
    /// A **negative** instance counts from the end, which is how a caller takes the last
    /// field without knowing how many there are.
    static func occurrence(
        of delimiter: String, in text: String, instance: Int
    ) -> Range<String.Index>? {
        guard !delimiter.isEmpty, instance != 0 else { return nil }
        var ranges: [Range<String.Index>] = []
        var searchFrom = text.startIndex
        while let found = text.range(of: delimiter, range: searchFrom..<text.endIndex) {
            ranges.append(found)
            searchFrom = found.upperBound
        }
        let index = instance > 0 ? instance - 1 : ranges.count + instance
        guard index >= 0, index < ranges.count else { return nil }
        return ranges[index]
    }

    /// Builds `TEXTBEFORE` or `TEXTAFTER`.
    static func split(_ name: String, before: Bool) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 2, maxArgs: 3) { values in
            if let error = firstError(values) { return error }
            guard let text = string(values.first), let delimiter = string(values.dropFirst().first)
            else { return .error(.value) }

            var instance = 1
            if values.count > 2 {
                guard let n = real(values[2]) else { return .error(.value) }
                instance = Int(n.rounded(.towardZero))
            }
            // A delimiter that does not occur is a well-formed question with no answer.
            guard let found = occurrence(of: delimiter, in: text, instance: instance) else {
                return .error(.na)
            }
            return .text(String(before ? text[text.startIndex..<found.lowerBound]
                                       : text[found.upperBound...]))
        }
    }

    /// `TEXTBEFORE(text, delimiter, [instance])` — everything before a delimiter.
    public static let textBefore = split("TEXTBEFORE", before: true)
    /// `TEXTAFTER(text, delimiter, [instance])` — everything after a delimiter.
    public static let textAfter = split("TEXTAFTER", before: false)

    /// `REPLACE(old_text, start_num, num_chars, new_text)` — replacement by position.
    ///
    /// `start_num` is 1-based, as every Excel string position is.
    public static let replace = ExcelFunction(name: "REPLACE", minArgs: 4, maxArgs: 4) { values in
        if let error = firstError(values) { return error }
        guard let text = string(values.first),
              let start = real(values[1]), start >= 1,
              let count = real(values[2]), count >= 0,
              let replacement = string(values[3]) else { return .error(.value) }

        let characters = Array(text)
        let from = min(Int(start) - 1, characters.count)
        let to = min(from + Int(count), characters.count)
        return .text(String(characters[0..<from]) + replacement + String(characters[to...]))
    }

    // MARK: - The number/text boundary

    /// `T(value)` — the value if it is text, and the empty string otherwise.
    ///
    /// **It tests a type rather than converting one.** `T(19)` is empty, not `"19"` —
    /// which is the opposite of what the name suggests to anyone expecting `TEXT`.
    public static let tFunction = ExcelFunction(name: "T", minArgs: 1, maxArgs: 1) { values in
        if let error = firstError(values) { return error }
        if case .text(let t)? = values.first { return .text(t) }
        return .text("")
    }

    /// `VALUE(text)` — text parsed as a number.
    ///
    /// Currency symbols and thousands separators are tolerated because a spreadsheet's text
    /// often arrives formatted; anything left over is `#VALUE!` rather than a partial parse.
    public static let value = ExcelFunction(name: "VALUE", minArgs: 1, maxArgs: 1) { values in
        if let error = firstError(values) { return error }
        guard let text = string(values.first) else { return .error(.value) }
        if case .number(let n)? = values.first { return .number(n) }

        let stripped = text
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
        guard !stripped.isEmpty, let parsed = Double(stripped) else { return .error(.value) }
        return .number(parsed)
    }

    /// `FIXED(number, [decimals], [no_commas])` — a number as text, rounded and grouped.
    ///
    /// A **negative** `decimals` rounds to the left of the point: `FIXED(1234.567, -1)` is
    /// `1,230`. Rounding happens before formatting, not after.
    public static let fixed = ExcelFunction(name: "FIXED", minArgs: 1, maxArgs: 3) { values in
        if let error = firstError(values) { return error }
        guard let number = real(values.first) else { return .error(.value) }

        var decimals = 2
        if values.count > 1, let d = real(values[1]) { decimals = Int(d.rounded(.towardZero)) }
        var commas = true
        if values.count > 2 {
            switch values[2] {
            case .bool(let b): commas = !b
            case .number(let n): commas = n == 0
            default: return .error(.value)
            }
        }

        let scale = pow(10.0, Double(decimals))
        guard scale != 0 else { return .error(.num) }
        let rounded = (number * scale).rounded() / scale

        let formatter = NumberFormatter()
        formatter.numberStyle = commas ? .decimal : .none
        formatter.usesGroupingSeparator = commas
        formatter.minimumFractionDigits = max(decimals, 0)
        formatter.maximumFractionDigits = max(decimals, 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        guard let text = formatter.string(from: NSNumber(value: rounded)) else {
            return .error(.value)
        }
        return .text(text)
    }

    // MARK: - Shared

    /// The first error among the arguments, propagated rather than absorbed.
    static func firstError(_ values: [CellValue]) -> CellValue? {
        values.first { if case .error = $0 { return true } else { return false } }
    }

    /// A finite number from a cell value.
    static func real(_ value: CellValue?) -> Double? {
        switch value {
        case .number(let d): return d.isFinite ? d : nil
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// A cell value as the text Excel would show for it.
    static func string(_ value: CellValue?) -> String? {
        switch value {
        case .text(let t): return t
        case .number(let d):
            return d.rounded() == d && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .blank: return ""
        default: return nil
        }
    }
}
