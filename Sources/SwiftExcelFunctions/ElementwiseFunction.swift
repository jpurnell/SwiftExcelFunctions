import Foundation
import SwiftExcelCore

public extension ExcelFunction {

    /// The same function, applied to each element when it is handed an array.
    ///
    /// ## What this is for
    ///
    /// Excel applies a scalar function across a range without being asked.
    /// `RIGHT($BQ$1:$BW$1, 1)` is seven last-characters, not an error, and
    /// `SUMPRODUCT(BQ10:BW10, VALUE(RIGHT($BQ$1:$BW$1, 1)))` depends on it: the inner call
    /// has to produce a seven-element array for the outer one to multiply against.
    ///
    /// **This was four hundred cells.** They were the single largest defect the Excel oracle
    /// found — one formula shape, repeated down four hundred rows of one workbook, answering
    /// `#VALUE!` because `RIGHT` called `toString` on a range and `VALUE` did the same to
    /// what `RIGHT` returned.
    ///
    /// ## Written once
    ///
    /// Wrapping the functions that need it beats teaching each of them to unpack an array:
    /// a dozen copies of the same loop is a dozen chances to broadcast differently, and the
    /// difference would show up as a shape rather than as an error.
    ///
    /// ## Shapes
    ///
    /// A single-element array broadcasts against a larger one, which is how a scalar
    /// argument beside a range behaves. Two arrays of genuinely different shapes are
    /// `#VALUE!` rather than a guess about which to clip.
    ///
    /// - Returns: A function with the same name and arity that maps over array arguments.
    func mappedOverArrays() -> ExcelFunction {
        let base = self
        return ExcelFunction(name: base.name, minArgs: base.minArgs, maxArgs: base.maxArgs) {
            arguments in
            let matrices = arguments.map { value -> CellMatrix? in
                guard case .array(let matrix) = value else { return nil }
                return matrix
            }
            let present = matrices.compactMap { $0 }
            // No array: the ordinary call, unchanged and no slower for the check.
            guard !present.isEmpty else { return try base.evaluate(arguments) }

            let rows = present.map(\.rows).max() ?? 1
            let columns = present.map(\.columns).max() ?? 1
            for matrix in present where !(matrix.rows == 1 && matrix.columns == 1) {
                guard matrix.rows == rows, matrix.columns == columns else {
                    return .error(.value)
                }
            }

            var results: [CellValue] = []
            results.reserveCapacity(rows * columns)
            for row in 0..<rows {
                for column in 0..<columns {
                    var scalars: [CellValue] = []
                    scalars.reserveCapacity(arguments.count)
                    for (argument, matrix) in zip(arguments, matrices) {
                        guard let matrix else {
                            scalars.append(argument)
                            continue
                        }
                        if matrix.rows == 1, matrix.columns == 1 {
                            scalars.append(matrix.elements.first ?? .blank)
                        } else {
                            scalars.append(matrix.element(row: row, column: column) ?? .blank)
                        }
                    }
                    results.append(try base.evaluate(scalars))
                }
            }
            guard let matrix = CellMatrix(elements: results, rows: rows, columns: columns) else {
                return .error(.value)
            }
            return .array(matrix)
        }
    }
}
