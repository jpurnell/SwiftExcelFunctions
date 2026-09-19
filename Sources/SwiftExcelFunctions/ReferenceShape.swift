import Foundation
import SwiftExcelCore

/// `ROWS` and `COLUMNS` answer from the **reference**, not from the values behind it.
///
/// ## The defect this exists to fix
///
/// `ROWS(A:A)` is **1,048,576** in Excel, on every sheet, whatever is in column A. This
/// package answered the height of the used range instead — 10 on a sheet with ten rows of
/// data, 0 on an empty one.
///
/// That was not a wrong formula. It follows from a decision that is right for every other
/// function: `CellRange.clipped(to:)` pulls a whole-column reference back to the used range,
/// because `$B:$B` in a real workbook means "whatever is in column B" and the alternative is
/// materialising 1,048,576 values per reference. Every function that *reads* those values
/// wants the clipped range.
///
/// `ROWS` and `COLUMNS` do not read them. They count positions, and a position exists whether
/// or not anything was typed into it. So they are answered here, from the reference as
/// written, before the range is resolved into values at all.
///
/// `CellRange`'s own documentation had already worked half of this out. It keeps a whole
/// **row** at its full 16,384 columns and gives the reason — "`INDEX`, `COLUMNS`, `ROWS` and
/// the lookups all count *positions*" — while clipping a whole column, where the same
/// argument applies and the cost of not clipping is a thousand times higher. The resolution
/// is that the clipping is correct and the counting should never have gone through it.
///
/// ## What is deliberately not intercepted
///
/// A computed reference — `ROWS(OFFSET(…))`, `ROWS(INDIRECT("A:A"))` — and an array literal
/// both fall through to the ordinary path, which is right for them: an array's shape *is* its
/// values, and a computed reference has to be computed before it has a shape. Only a
/// reference written in the formula, or a name that points directly at one, is answered here.
enum ReferenceShape {

    /// Answers `ROWS` or `COLUMNS` from an unevaluated argument, when it names a reference.
    ///
    /// - Parameters:
    ///   - function: The function being called, already arity-checked by the caller.
    ///   - arguments: Its argument nodes, unevaluated.
    ///   - names: The resolver, so a defined name pointing at a whole column counts like one.
    ///   - sheet: The sheet the formula sits on, since a name means different things on
    ///     different sheets.
    /// - Returns: The count, or `nil` to let the ordinary path evaluate the argument.
    static func evaluate(
        _ function: String, arguments: [FormulaAST],
        names: NameResolver, inSheet sheet: String
    ) -> CellValue? {
        guard function == "ROWS" || function == "COLUMNS" else { return nil }
        guard arguments.count == 1 else { return nil }
        guard let range = range(of: arguments[0], names: names, inSheet: sheet) else {
            return nil
        }
        return .number(Double(function == "ROWS" ? range.rowCount : range.columnCount))
    }

    /// The range a node names, when it names one directly.
    ///
    /// - Parameters:
    ///   - node: The argument as written.
    ///   - names: The resolver, for a defined name.
    ///   - sheet: The sheet the formula sits on.
    /// - Returns: The range, or `nil` when the node is not a plain reference.
    private static func range(
        of node: FormulaAST, names: NameResolver, inSheet sheet: String
    ) -> CellRange? {
        switch node {
        case .cellRange(let range):
            return range
        case .sheetRef(let reference):
            return reference.range
        case .namedRange(let name):
            // A name that points at a whole column is the common case in a real workbook —
            // it is how a model says "this column" — so resolving it here is most of the
            // value, not an extra.
            switch names.resolve(name, inSheet: sheet) {
            case .range(let range): return range
            case .sheetRange(let reference): return reference.range
            // A single cell is 1×1 either way, and a formula or an unreadable refers-to has
            // no shape until it is evaluated. Both fall through.
            default: return nil
            }
        default:
            return nil
        }
    }
}
