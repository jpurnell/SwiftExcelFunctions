import Foundation
import SwiftExcelCore

/// Excel's operators, applied to rectangles.
///
/// `A1:A10*2` is ten products, and `--(names=$C4)` is ten ones and zeros. An evaluator that
/// coerces a rectangle to a single number instead answers **one** number — and in the
/// `SUMPRODUCT` idiom that surrounds these comparisons, that one number is `0`.
///
/// ```
/// SUMPRODUCT(--(area=$C4), --(dates>=S$3))
/// ```
///
/// Every term collapses to `FALSE`, `--FALSE` is `0`, and the whole formula answers zero
/// while looking entirely healthy. **407 cells in one workbook** answered zero this way
/// before the operators learned to broadcast — found by the workbook checker, whose first
/// corpus run reported them as defects in someone's spreadsheet.
///
/// ## The rule, which is not "same shape or nothing"
///
/// The result is as tall as the taller operand and as wide as the wider one. A side with a
/// single row is reused down the rectangle and a side with a single column is reused across
/// it, so a row vector against a column vector produces a **matrix** — `{1,2,3}` times
/// `{1;2}` is 2×3, which is Excel's answer and surprises most people once.
///
/// Where a side has more than one row but fewer than the result, the missing elements are
/// `#N/A` rather than repeated or clipped: Excel refuses to guess what was meant, and so
/// does this.
enum ArrayBroadcast {

    /// Applies a binary operator across two values, whatever shape they are.
    ///
    /// - Parameters:
    ///   - left: The left operand.
    ///   - right: The right operand.
    ///   - operation: What to do with one element of each.
    /// - Returns: The operator's own answer when neither side is a rectangle; otherwise a
    ///   rectangle of answers.
    static func combine(
        _ left: CellValue, _ right: CellValue,
        _ operation: (CellValue, CellValue) throws -> CellValue
    ) rethrows -> CellValue {
        guard isBroadcast(left, right) else { return try operation(left, right) }
        let (rows, columns) = resultShape(left, right)
        var elements: [CellValue] = []
        elements.reserveCapacity(rows * columns)
        for row in 0..<rows {
            for column in 0..<columns {
                guard let a = element(of: left, row: row, column: column),
                      let b = element(of: right, row: row, column: column) else {
                    // Outside one operand's rectangle. Excel puts #N/A here rather than
                    // repeating an edge or clipping the result to the smaller side.
                    elements.append(.error(.na))
                    continue
                }
                elements.append(try operation(a, b))
            }
        }
        guard let matrix = CellMatrix(elements: elements, rows: rows, columns: columns) else {
            return .error(.value)
        }
        return .array(matrix)
    }

    /// Applies a unary operator across a value, whatever shape it is.
    ///
    /// - Parameters:
    ///   - value: The operand.
    ///   - operation: What to do with one element.
    /// - Returns: The operator's own answer for a single value; a rectangle of answers for
    ///   a rectangle.
    static func mapped(
        _ value: CellValue, _ operation: (CellValue) throws -> CellValue
    ) rethrows -> CellValue {
        guard case .array(let matrix) = value else { return try operation(value) }
        let elements = try matrix.elements.map { try operation($0) }
        guard let result = CellMatrix(elements: elements,
                                      rows: matrix.rows, columns: matrix.columns) else {
            return .error(.value)
        }
        return .array(result)
    }

    /// Whether either side is a rectangle, in which case the operator broadcasts.
    ///
    /// - Parameters:
    ///   - left: The left operand.
    ///   - right: The right operand.
    /// - Returns: `true` when at least one is an array.
    static func isBroadcast(_ left: CellValue, _ right: CellValue) -> Bool {
        shape(of: left) != nil || shape(of: right) != nil
    }

    /// The dimensions of an operand, or `nil` when it is a single value.
    private static func shape(of value: CellValue) -> (rows: Int, columns: Int)? {
        guard case .array(let matrix) = value else { return nil }
        return (matrix.rows, matrix.columns)
    }

    /// The dimensions of the answer.
    private static func resultShape(_ left: CellValue, _ right: CellValue) -> (Int, Int) {
        let a = shape(of: left) ?? (1, 1)
        let b = shape(of: right) ?? (1, 1)
        return (Swift.max(a.rows, b.rows), Swift.max(a.columns, b.columns))
    }

    /// One element of an operand, with a single row or column reused.
    ///
    /// - Parameters:
    ///   - value: The operand.
    ///   - row: Which row of the result is being filled.
    ///   - column: Which column of the result is being filled.
    /// - Returns: The element to use, or `nil` when the operand does not reach that far.
    private static func element(of value: CellValue, row: Int, column: Int) -> CellValue? {
        guard case .array(let matrix) = value else { return value }
        guard matrix.rows > 0, matrix.columns > 0 else { return nil }
        // A single row is reused down the rectangle, a single column across it. Anything
        // else must reach the position on its own.
        let sourceRow = matrix.rows == 1 ? 0 : row
        let sourceColumn = matrix.columns == 1 ? 0 : column
        guard sourceRow < matrix.rows, sourceColumn < matrix.columns else { return nil }
        return matrix[sourceRow, sourceColumn]
    }
}
