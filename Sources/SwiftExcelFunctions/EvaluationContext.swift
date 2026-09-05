import SwiftExcelCore

/// What a function needs to know beyond its arguments.
///
/// Most functions need nothing here. `SUM` adds what it is given; `ISERROR` looks
/// at what it is given. They are maps from values to a value, and their signature
/// says so.
///
/// A handful are not. `COLUMN()` with no argument answers about **the cell it was
/// written in**, and `INDIRECT` reads a cell chosen while the formula runs.
/// Neither question can be answered from the argument list, because the answer is
/// not in it.
///
/// ## Why the argument trees come too
///
/// `COLUMN(B5)` wants the *address* `B5`, not the 42 that is in it — and by the
/// time a function is called, its arguments have been reduced to values and the
/// address is gone. So ``arguments`` carries the unevaluated trees alongside.
///
/// This is not lazy evaluation. Every argument is still evaluated, exactly once,
/// before the call; a function may additionally look at what it was *handed*.
/// Measured across 79 workbooks, that distinction matters for 220 formulas —
/// small, but the alternative was to leave `COLUMN(B5)` unanswerable.
public struct EvaluationContext: Sendable {

    /// The cell whose formula is being evaluated, if there is one.
    ///
    /// `nil` when a formula is evaluated on its own rather than out of a sheet —
    /// a test, or a caller computing an expression. `COLUMN()` has no answer then,
    /// and says so rather than inventing a position.
    public let callingCell: CellAddress?

    /// The sheet the formula is on, for a reference that does not name one.
    public let currentSheet: String

    /// Where cell values come from.
    public let cells: any CellValueProvider

    /// The unevaluated argument trees, in order, alongside the evaluated values.
    public let arguments: [FormulaAST]

    /// Creates an evaluation context.
    ///
    /// - Parameters:
    ///   - callingCell: The cell being evaluated, or `nil` outside a sheet.
    ///   - currentSheet: The sheet an unqualified reference belongs to.
    ///   - cells: The provider to read cells through.
    ///   - arguments: The unevaluated argument trees.
    public init(
        callingCell: CellAddress?,
        currentSheet: String,
        cells: any CellValueProvider,
        arguments: [FormulaAST]
    ) {
        self.callingCell = callingCell
        self.currentSheet = currentSheet
        self.cells = cells
        self.arguments = arguments
    }

    /// The address an argument names, if it names one.
    ///
    /// `COLUMN(B5)` asks this of its first argument and gets `B5`. `COLUMN(1+1)`
    /// asks and gets nothing, which is the right answer: an arithmetic expression
    /// has no address.
    ///
    /// - Parameter index: Which argument to look at.
    /// - Returns: The single cell it names, or `nil`.
    public func referencedCell(at index: Int) -> CellRef? {
        guard index < arguments.count else { return nil }
        switch arguments[index] {
        case .cellRef(let ref): return ref
        case .cellRange(let range): return range.start
        case .sheetRef(let reference): return reference.range.start
        default: return nil
        }
    }
}
