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

    /// Whether the enclosing call wanted its arguments evaluated as **arrays**.
    ///
    /// `SUMPRODUCT` does and `SUM` does not, measured in round fifteen. `COLUMN` and `ROW`
    /// answer the whole range when this is set and the leftmost cell when it is not — which
    /// is the difference between 3 and 1 in the idiom that counts alternating columns.
    public let evaluatesArrays: Bool

    /// Where randomness comes from, when a formula asks for any.
    ///
    /// `nil` means none was supplied, and `RAND()` answers `#VALUE!` rather than
    /// reaching for system entropy. See ``RandomSource``.
    public let random: (any RandomSource)?

    /// A completed simulation run, when one has been supplied.
    ///
    /// `nil` means nothing has been simulated, and every `Psi*` statistic answers `#N/A`
    /// rather than a number. See ``SimulationResultProvider``.
    public let simulation: (any SimulationResultProvider)?

    /// Creates an evaluation context.
    ///
    /// - Parameters:
    ///   - callingCell: The cell being evaluated, or `nil` outside a sheet.
    ///   - currentSheet: The sheet an unqualified reference belongs to.
    ///   - cells: The provider to read cells through.
    ///   - arguments: The unevaluated argument trees.
    ///   - random: Where `RAND()` draws from, or `nil` for none.
    ///   - simulation: A completed run for the `Psi*` statistics, or `nil` for none.
    ///   - evaluatesArrays: Whether the enclosing call wants its arguments evaluated as
    ///     arrays. `false` — the ordinary case — is what `SUM` and every scalar call pass;
    ///     `SUMPRODUCT` passes `true`, and `COLUMN` and `ROW` read it to decide between the
    ///     whole range and its leftmost cell.
    public init(
        callingCell: CellAddress?,
        currentSheet: String,
        cells: any CellValueProvider,
        arguments: [FormulaAST],
        random: (any RandomSource)? = nil,
        simulation: (any SimulationResultProvider)? = nil,
        evaluatesArrays: Bool = false
    ) {
        self.random = random
        self.simulation = simulation
        self.callingCell = callingCell
        self.currentSheet = currentSheet
        self.cells = cells
        self.arguments = arguments
        self.evaluatesArrays = evaluatesArrays
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

    /// The sheet an argument names, where it names one.
    ///
    /// `GETPIVOTDATA`'s second argument is a cell of the pivot it means, and one corpus
    /// workbook renders a pivot at `M1` on dozens of sheets — one per week. Matching on the
    /// address alone would answer from whichever sheet happened to be read first.
    ///
    /// `nil` where the reference names no sheet, which means the formula's own.
    ///
    /// - Parameter index: Which argument to look at.
    /// - Returns: The sheet name, or `nil`.
    public func referencedSheet(at index: Int) -> String? {
        guard index < arguments.count, case .sheetRef(let reference) = arguments[index] else {
            return nil
        }
        return reference.sheetName
    }

    /// The whole range an argument names, rather than only its first cell.
    ///
    /// `COLUMN` needs this when its caller evaluates arguments as arrays: the answer is then
    /// every column in the range rather than the leftmost one.
    ///
    /// - Parameter index: Which argument to look at.
    /// - Returns: The range it names, or `nil` when it names none.
    public func referencedRange(at index: Int) -> CellRange? {
        guard index < arguments.count else { return nil }
        switch arguments[index] {
        case .cellRef(let ref): return CellRange(from: ref, to: ref)
        case .cellRange(let range): return range
        case .sheetRef(let reference): return reference.range
        default: return nil
        }
    }
}
