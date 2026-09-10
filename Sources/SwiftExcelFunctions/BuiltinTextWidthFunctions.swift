import Foundation
import SwiftExcelCore

/// `DBCS`, `JIS` and `ASC` — converting between half-width and full-width forms.
///
/// **These are one function under two names.** Microsoft's own description says so: "the
/// name of the function (and the characters that it converts) depends upon your language
/// settings." `JIS` is what Japanese-language Excel calls `DBCS`. Both spellings are
/// registered, because a workbook may carry either, and both reach the same implementation,
/// because two would drift — the first thing to diverge being a coercion nobody thought to
/// copy across.
///
/// ## Why this is not arithmetic on scalars
///
/// The obvious implementation adds `0xFEE0` to every printable ASCII scalar, which maps
/// `!`…`~` onto `！`…`～` correctly and then gets two things wrong:
///
/// - **The space.** Its full-width form is the ideographic space `U+3000`, in a different
///   block, not `U+FF00 + 0x20`.
/// - **Voiced katakana.** Half-width writes `ｶ` and `ﾞ` as two scalars; full-width writes
///   the single character `ガ`. The conversion composes, so the string gets *shorter*, and
///   any per-character mapping cannot express that.
///
/// Foundation's `StringTransform.fullwidthToHalfwidth` handles both, and is applied in
/// reverse. Using it rather than a table is not laziness: the table is large, locale-adjacent
/// and exactly the kind of thing that rots.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinTextWidthFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinTextWidthFunctions {

    /// All three for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [dbcs, jis, asc]

    /// `DBCS(text)` — half-width characters widened to full-width.
    public static let dbcs = widen(named: "DBCS")

    /// `JIS(text)` — the same function, under the name Japanese-language Excel gives it.
    public static let jis = widen(named: "JIS")

    /// `ASC(text)` — full-width characters narrowed to half-width.
    ///
    /// The inverse of ``dbcs``, and asymmetric in the same two places: the ideographic space
    /// `U+3000` narrows to an ordinary space, and a composed katakana **decomposes** — `ガ`
    /// becomes `ｶ` followed by a separate `ﾞ`, so the string gets *longer*. Widening shortens
    /// and narrowing lengthens, which is why neither can be a per-character map.
    public static let asc = ExcelFunction(name: "ASC", minArgs: 1, maxArgs: 1) { args in
        BuiltinTextFunctions.catching {
            let source = try BuiltinTextFunctions.toString(args[0])
            return .text(source.applyingTransform(.fullwidthToHalfwidth, reverse: false)
                         ?? source)
        }
    }

    /// Builds the widening function under a given name.
    ///
    /// - Parameter name: The Excel spelling to register.
    /// - Returns: The function.
    static func widen(named name: String) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 1, maxArgs: 1) { args in
            BuiltinTextFunctions.catching {
                let source = try BuiltinTextFunctions.toString(args[0])
                // `reverse: true` runs halfwidth → fullwidth. The transform is documented
                // never to fail for this direction, but the fallback keeps the input rather
                // than inventing an error Excel would not produce.
                return .text(source.applyingTransform(.fullwidthToHalfwidth, reverse: true)
                             ?? source)
            }
        }
    }
}
