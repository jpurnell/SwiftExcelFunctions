import Foundation
import SwiftExcelCore

/// Excel's byte-oriented text functions, under a single-byte locale.
///
/// `LENB`, `LEFTB`, `RIGHTB`, `MIDB`, `FINDB`, `SEARCHB` and `REPLACEB` count *bytes*
/// where their unsuffixed counterparts count characters. Under a DBCS locale —
/// Japanese, Chinese, Korean — a double-byte character counts as two, so
/// `LENB("あい")` is 4. Under any single-byte locale it counts as one and the answer
/// is 2.
///
/// **Excel's answer therefore depends on the machine it is running on**, and nothing
/// in a saved file records which locale produced a cached value. That is the one
/// case ADR-001 does not cover: there is no single Excel to match, so a choice had to
/// be made rather than discovered.
///
/// This package models no locale and takes the single-byte reading, which makes each
/// of these exactly its counterpart. See ADR-002 for why, and for the measurement
/// that would overturn it.
///
/// ## Why they delegate rather than duplicate
///
/// Each forwards to the function it equals. Reimplementing `LEFT` beside `LEFTB`
/// would create two behaviours that could drift — and the first thing to drift would
/// be an argument-coercion rule nobody thought to copy. One behaviour, two names, is
/// the whole content of this decision.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinTextByteFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinTextByteFunctions {

    /// All byte-oriented text functions, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        lenb, leftb, rightb, midb, findb, searchb, replaceb,
    ]

    /// Renames a function, keeping one behaviour behind two names.
    ///
    /// - Parameters:
    ///   - name: The byte-oriented name to register.
    ///   - other: The character-oriented function it equals under this locale.
    /// - Returns: The same behaviour, under the new name.
    private static func sameAs(_ name: String, _ other: ExcelFunction) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: other.minArgs, maxArgs: other.maxArgs) { values in
            try other.evaluate(values)
        }
    }

    /// `LENB(text)` — bytes in `text`; under a single-byte locale, its length.
    public static let lenb = sameAs("LENB", BuiltinTextFunctions.len)

    /// `LEFTB(text, [num_bytes])` — leading bytes; under a single-byte locale, `LEFT`.
    public static let leftb = sameAs("LEFTB", BuiltinTextFunctions.left)

    /// `RIGHTB(text, [num_bytes])` — trailing bytes; under a single-byte locale, `RIGHT`.
    public static let rightb = sameAs("RIGHTB", BuiltinTextFunctions.right)

    /// `MIDB(text, start_num, num_bytes)` — a run of bytes; under a single-byte
    /// locale, `MID`.
    public static let midb = sameAs("MIDB", BuiltinTextFunctions.mid)

    /// `FINDB(find_text, within_text, [start_num])` — byte position of a match.
    ///
    /// Case-sensitive and takes no wildcards, exactly as `FIND` does — the pairing
    /// with `SEARCHB` is the same trap as `FIND` and `SEARCH`, and choosing the wrong
    /// one is a bug that only appears on data you did not test with.
    public static let findb = sameAs("FINDB", BuiltinTextFunctions.find)

    /// `SEARCHB(find_text, within_text, [start_num])` — byte position, case-insensitive
    /// and wildcard-aware, exactly as `SEARCH`.
    public static let searchb = sameAs("SEARCHB", BuiltinTextFunctions.search)

    /// `REPLACEB(old_text, start_num, num_bytes, new_text)` — replaces a run of bytes;
    /// under a single-byte locale, `REPLACE`.
    public static let replaceb = sameAs("REPLACEB", BuiltinTextPrimitives.replace)
}
