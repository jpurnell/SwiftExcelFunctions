import Foundation
import SwiftExcelCore

/// `PHONETIC(reference)` — the furigana stored alongside a cell.
///
/// The only function in the text family that reads a *cell* rather than a value, and it has
/// to be: the reading is not part of what the cell says. 山田 is the name; ヤマダ is how to
/// pronounce it, stored in an `<rPh>` run beside the text. By the time an argument reaches a
/// function it has been reduced to a value, and the reading is not in it.
///
/// So this is a context function, reaching the address through
/// ``EvaluationContext/referencedCell(at:)`` — the same seam `COLUMN(B5)` uses to recover an
/// address rather than the number inside it — and then asking the provider.
///
/// ## What had to exist first
///
/// Three things, in three packages, and the first was a bug rather than a gap:
///
/// | Where | What |
/// |---|---|
/// | SwiftXLSX 0.23.2 | stopped concatenating `<rPh>` text *into* cell values, which corrupted every affected cell |
/// | SwiftExcelCore 0.8.0 | `CellValueProvider.phonetic(at:)`, defaulting to `nil` |
/// | SwiftXLSX 0.24.0 | kept the readings and recorded them against the cell |
///
/// ```swift
/// var registry = FunctionRegistry()
/// registry.register(BuiltinPhonetic.phonetic)
/// ```
public enum BuiltinPhonetic {

    /// The function for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [phonetic]

    /// `PHONETIC(reference)` — the reading of the referenced cell, or empty text.
    ///
    /// A cell with no reading answers `""` rather than an error. Every workbook outside a
    /// Japanese locale is that case, and an error would make this a landmine in any sheet
    /// that merely mentions it. That choice is **not measured against Excel** — producing
    /// furigana needs a Japanese-locale editor — so it pins our answer rather than
    /// confirming theirs.
    public static let phonetic = ExcelFunction(
        name: "PHONETIC", minArgs: 1, maxArgs: 1
    ) { context, _ in
        guard let referenced = context.referencedCell(at: 0) else { return .error(.value) }
        return .text(context.cells.phonetic(at: referenced) ?? "")
    }
}
