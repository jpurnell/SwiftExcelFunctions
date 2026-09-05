import Foundation
import SwiftExcelCore

/// Array: functions of a rectangle's shape rather than its contents.
///
/// Everywhere else in this package a range is somewhere values come from, and the
/// function cares only about the values. Here the rectangle *is* the subject:
/// `TRANSPOSE` changes nothing but the shape, and `COUNTBLANK` counts positions
/// that hold nothing at all.
///
/// Both became possible with SwiftExcelCore 0.3.0. Before it, a range flattened to
/// a list with no dimensions and with its empty cells removed — so `TRANSPOSE` had
/// no shape to exchange, and `COUNTBLANK` could not see a single one of the things
/// it counts.
///
/// Register all functions at once via ``all``:
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinArrayFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinArrayFunctions {

    /// All array functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [transpose, countblank]

    // MARK: - TRANSPOSE

    /// `TRANSPOSE(array)` — the array with its rows and columns exchanged.
    ///
    /// A column of twelve becomes a row of twelve; a 2×3 block becomes 3×2 with its
    /// elements moved accordingly. Blanks keep their positions, which for this
    /// function is most of the work: a rectangle with a hole must come back with the
    /// hole in the transposed place, not with the hole closed and everything after
    /// it shifted.
    ///
    /// A lone value is a 1×1 rectangle and comes back unchanged, so the degenerate
    /// case needs no special handling.
    ///
    /// ## What this does not do
    ///
    /// It does not spill. In Excel, `TRANSPOSE` is nearly always entered across a
    /// range of cells and its result fills them — `{=TRANSPOSE(B11:B32)}` written
    /// into `E5:Z5`. Evaluation here produces one value for one cell, so a
    /// transposed array is useful *inside* another formula
    /// (`SUM(TRANSPOSE(A1:A3))`) and has nowhere to go on its own. Writing a
    /// rectangle back across cells is a separate piece of work, deliberately not
    /// attempted here.
    public static let transpose = ExcelFunction(name: "TRANSPOSE", minArgs: 1, maxArgs: 1) { args in
        // An error in, the same error out — Excel propagates rather than
        // transposing a rectangle it could not build.
        if case .error(let excelError) = args[0] { return .error(excelError) }

        guard case .array(let matrix) = args[0] else {
            return .array(CellMatrix(single: args[0]))
        }
        return .array(matrix.transposed())
    }

    // MARK: - COUNTBLANK

    /// `COUNTBLANK(range)` — how many cells in the range hold nothing.
    ///
    /// Counts a blank cell and the empty string, which is the one place
    /// Excel treats `""` as empty: a formula that returned `""` leaves a cell that
    /// looks blank, and `COUNTBLANK` agrees with how it looks. Text of any other
    /// length, zero, and `FALSE` are all values and are not counted.
    ///
    /// This could not be written before ranges kept their blanks. The old read
    /// dropped empty cells on the way in, so the function would have been handed a
    /// list containing none of the things it exists to count and would have
    /// answered zero every time.
    public static let countblank = ExcelFunction(name: "COUNTBLANK", minArgs: 1, maxArgs: nil) { args in
        var count = 0
        for argument in args {
            count += blanks(in: argument)
        }
        return .number(Double(count))
    }

    /// Counts the empty positions in a value, descending into nested arrays.
    ///
    /// - Parameter value: The value to examine.
    /// - Returns: The number of blanks.
    private static func blanks(in value: CellValue) -> Int {
        switch value {
        case .blank:
            return 1
        case .text(let text):
            return text.isEmpty ? 1 : 0
        case .array(let matrix):
            return matrix.elements.reduce(0) { $0 + blanks(in: $1) }
        case .formula(_, let cached):
            return cached.map(blanks(in:)) ?? 1
        case .number, .bool, .error, .date:
            return 0
        }
    }
}
