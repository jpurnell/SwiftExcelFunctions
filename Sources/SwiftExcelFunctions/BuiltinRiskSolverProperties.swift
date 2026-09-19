import Foundation
import SwiftExcelCore

/// The property functions a `Psi*` distribution carries.
///
/// A distribution call can be written with modifiers attached to it:
///
/// ```
/// =PsiNormal(10, 2, PsiTruncate(5, 15))
/// =PsiNormal(10, 2, PsiShift(3), PsiUnits("days"))
/// ```
///
/// **None of these were registered, so any workbook using one failed outright.** An
/// unregistered name is `#NAME?`, and it is the *enclosing* call that fails — so
/// `PsiNormal(10, 2, PsiTruncate(5, 15))` produced no number at all rather than an
/// untruncated one. That is worse than the completeness gap it looked like from the
/// coverage matrix.
///
/// ## How a property reaches the distribution without the evaluator
///
/// `BuiltinRiskSolverDistributions.attached(_:_:)` sees each argument twice: the unevaluated
/// AST, which gives it the property's *name*, and the evaluated value. It cannot evaluate
/// anything itself, so a property that needs to carry two numbers — `PsiTruncate(5, 15)` —
/// cannot have them read out of its AST.
///
/// So each property **evaluates to its own arguments**: `PsiTruncate(5, 15)` answers the
/// 1×2 array `{5, 15}`, and `attached` reads the pair back off the value. No evaluator
/// changes, no second parsing path, and a property written on its own in a cell still shows
/// something truthful about itself.
public enum BuiltinRiskSolverProperties {

    /// Every property, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] =
        [psiShift, psiTruncate, psiTruncateP, psiUnits, psiCategory,
         psiStatic, psiLock, psiCollect]

    // MARK: - Modifiers that change the numbers

    /// `PsiShift(delta)` — moves every draw by a constant.
    ///
    /// The whole distribution slides; its spread and shape are untouched. Answers the shift
    /// itself, which is the number `attached` needs.
    public static let psiShift = ExcelFunction(
        name: "PSISHIFT", minArgs: 1, maxArgs: 1
    ) { values in values[0] }

    /// `PsiTruncate(min, max)` — restricts the distribution to a range of **values**.
    ///
    /// Draws outside `[min, max]` do not occur, and the remaining probability is rescaled so
    /// the truncated distribution still integrates to one. That rescaling is the part worth
    /// stating: a truncation that merely clamped would pile probability onto the two
    /// endpoints and report a spike where the model meant a bound.
    ///
    /// Either end may be omitted by passing a blank, which truncates on one side only.
    public static let psiTruncate = ExcelFunction(
        name: "PSITRUNCATE", minArgs: 1, maxArgs: 2
    ) { values in pair(values) }

    /// `PsiTruncateP(lower, upper)` — restricts the distribution by **probability**.
    ///
    /// `PsiTruncateP(0.05, 0.95)` keeps the middle ninety per cent. The same operation as
    /// ``psiTruncate`` expressed on the other axis, and the cheaper one: the probabilities are
    /// the mapping, where truncating by value has to find them first.
    public static let psiTruncateP = ExcelFunction(
        name: "PSITRUNCATEP", minArgs: 1, maxArgs: 2
    ) { values in pair(values) }

    // MARK: - Markers that carry no arithmetic

    /// `PsiUnits("days")` — a label for the units an input is measured in.
    public static let psiUnits = ExcelFunction(
        name: "PSIUNITS", minArgs: 1, maxArgs: 1
    ) { values in values[0] }

    /// `PsiCategory("Demand")` — a label grouping inputs in the model's reports.
    public static let psiCategory = ExcelFunction(
        name: "PSICATEGORY", minArgs: 1, maxArgs: 1
    ) { values in values[0] }

    /// `PsiStatic(TRUE)` — holds an input at one value for a whole run.
    ///
    /// Recognised and carried; **what it asks for is the engine's to honour**, not this
    /// package's. `FormulaEvaluator` draws once per evaluation and has no notion of a trial,
    /// so there is nothing here that could hold a value across trials. Registering it stops
    /// the enclosing distribution failing, which is the part that was broken.
    public static let psiStatic = ExcelFunction(
        name: "PSISTATIC", minArgs: 0, maxArgs: 1
    ) { values in values.first ?? .bool(true) }

    /// `PsiLock()` — fixes an input's value against re-sampling. As with ``psiStatic``, the
    /// engine's to honour.
    public static let psiLock = ExcelFunction(
        name: "PSILOCK", minArgs: 0, maxArgs: 1
    ) { values in values.first ?? .bool(true) }

    /// `PsiCollect(TRUE)` — whether the run should keep this cell's trial values.
    ///
    /// A directive to the engine about what to store, which a formula evaluator cannot act on.
    public static let psiCollect = ExcelFunction(
        name: "PSICOLLECT", minArgs: 0, maxArgs: 1
    ) { values in values.first ?? .bool(true) }

    /// Two arguments as a 1×2 array, so `attached` can read the pair back off the value.
    ///
    /// A missing second argument becomes a blank rather than a number, which is how a
    /// one-sided truncation says which side it left open.
    private static func pair(_ values: [CellValue]) -> CellValue {
        let second = values.count > 1 ? values[1] : CellValue.blank
        guard let matrix = CellMatrix(elements: [values[0], second], rows: 1, columns: 2) else {
            return .error(.value)
        }
        return .array(matrix)
    }
}
