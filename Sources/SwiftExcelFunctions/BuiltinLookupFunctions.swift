import Foundation
import SwiftExcelCore

/// Lookup category built-in Excel functions.
///
/// Provides implementations of 4 standard Excel lookup functions:
/// `VLOOKUP`, `HLOOKUP`, `INDEX`, and `MATCH`.
///
/// Register all functions at once via ``all``:
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinLookupFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinLookupFunctions {

    /// All lookup functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [vlookup, hlookup, index, match]

    // MARK: - Type coercion

    /// Extracts a `Double` from a `CellValue`, applying Excel-style type coercion.
    private static func toNumber(_ value: CellValue) throws -> Double {
        switch value {
        case .number(let n):
            return n
        case .text(let s):
            guard let n = Double(s) else { throw EvalError.typeMismatch }
            return n
        case .bool(let b):
            return b ? 1.0 : 0.0
        case .blank:
            return 0.0
        case .error(let e):
            throw EvalError.excelError(e)
        case .date(let d):
            return d.timeIntervalSinceReferenceDate / 86_400.0
        case .formula(_, let cached):
            return try toNumber(cached ?? .blank)
        case .array:
            throw EvalError.typeMismatch
        }
    }

    /// Wraps a function body so that ``EvalError`` maps to the correct ``CellValue/error(_:)``.
    private static func catching(_ body: () throws -> CellValue) -> CellValue {
        do {
            return try body()
        } catch EvalError.excelError(let e) {
            return .error(e)
        } catch EvalError.numError {
            return .error(.num)
        } catch EvalError.div0Error {
            return .error(.div0)
        } catch {
            return .error(.value)
        }
    }

    /// Extracts the flat array of values from a `CellValue`.
    ///
    /// If the value is `.array(...)`, returns the elements. Otherwise returns a single-element array.
    private static func toArray(_ value: CellValue) -> [CellValue] {
        if case .array(let elements) = value {
            return elements
        }
        return [value]
    }

    /// Determines whether range_lookup is exact match (false) or approximate (true).
    ///
    /// - Parameter value: The range_lookup argument.
    /// - Returns: `true` for approximate match, `false` for exact.
    private static func isApproximate(_ value: CellValue) -> Bool {
        switch value {
        case .bool(let b):
            return b
        case .number(let n):
            return n != 0
        case .blank:
            return true // default is approximate
        default:
            return true
        }
    }

    /// Compares two `CellValue` instances for equality in lookup context.
    ///
    /// Text comparison is case-insensitive. Numbers and bools compare by value.
    private static func valuesEqual(_ lhs: CellValue, _ rhs: CellValue) -> Bool {
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)):
            return a == b
        case (.text(let a), .text(let b)):
            return a.caseInsensitiveCompare(b) == .orderedSame
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.blank, .blank):
            return true
        // Cross-type: number to text coercion for lookups
        case (.number(let n), .text(let s)):
            return Double(s).map { $0 == n } ?? false
        case (.text(let s), .number(let n)):
            return Double(s).map { $0 == n } ?? false
        default:
            return false
        }
    }

    /// Compares two `CellValue` instances for ordering in approximate match lookups.
    ///
    /// Returns negative if lhs < rhs, 0 if equal, positive if lhs > rhs.
    /// Returns nil if values are not comparable.
    private static func compareValues(_ lhs: CellValue, _ rhs: CellValue) -> Int? {
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)):
            if a < b { return -1 }
            if a > b { return 1 }
            return 0
        case (.text(let a), .text(let b)):
            let result = a.caseInsensitiveCompare(b)
            switch result {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        default:
            return nil
        }
    }

    // MARK: - VLOOKUP

    /// `VLOOKUP(lookup_value, table_array, col_index_num, [range_lookup])` -- vertical lookup.
    ///
    /// Searches for `lookup_value` in the first column of the table and returns
    /// a value from the same row in the specified column.
    ///
    /// The `table_array` should be a flat `.array(...)` organized row-major.
    /// The number of columns is inferred from `col_index_num` (minimum column count).
    /// Rows = total elements / columns.
    ///
    /// - `range_lookup` = `FALSE` (or 0): exact match
    /// - `range_lookup` = `TRUE` (or 1, default): approximate match (data must be sorted ascending)
    ///
    /// Returns `#N/A` if not found, `#REF!` if `col_index_num` is out of bounds.
    static let vlookup = ExcelFunction(name: "VLOOKUP", minArgs: 3, maxArgs: 4) { args in
        catching {
            let lookupValue = args[0]
            let tableData = toArray(args[1])
            let colIndex = Int(try toNumber(args[2]))
            let approximate = args.count > 3 ? isApproximate(args[3]) : true

            guard colIndex >= 1 else { return .error(.value) }
            guard tableData.count >= colIndex else { return .error(.ref) }

            // Infer number of columns: at least colIndex
            let numCols = colIndex
            // But the actual table might have more columns. We need to figure this out.
            // If the total count is divisible by colIndex, use colIndex as the column count.
            // Otherwise try to find the best fit.
            let inferredCols: Int
            if tableData.count % numCols == 0 {
                inferredCols = numCols
            } else {
                // Try to find the smallest number >= colIndex that divides evenly
                var cols = numCols
                while cols <= tableData.count {
                    if tableData.count % cols == 0 {
                        break
                    }
                    cols += 1
                }
                inferredCols = cols <= tableData.count ? cols : numCols
            }

            let numRows = tableData.count / inferredCols
            guard numRows > 0 else { return .error(.na) }
            guard colIndex <= inferredCols else { return .error(.ref) }

            if approximate {
                // Approximate match: find largest value <= lookup_value
                var bestRow: Int?
                for row in 0..<numRows {
                    let cellValue = tableData[row * inferredCols]
                    if let cmp = compareValues(cellValue, lookupValue) {
                        if cmp <= 0 {
                            bestRow = row
                        } else {
                            break // Data is sorted, so stop when we pass the value
                        }
                    }
                }
                guard let foundRow = bestRow else { return .error(.na) }
                return tableData[foundRow * inferredCols + (colIndex - 1)]
            } else {
                // Exact match
                for row in 0..<numRows {
                    let cellValue = tableData[row * inferredCols]
                    if valuesEqual(cellValue, lookupValue) {
                        return tableData[row * inferredCols + (colIndex - 1)]
                    }
                }
                return .error(.na)
            }
        }
    }

    // MARK: - HLOOKUP

    /// `HLOOKUP(lookup_value, table_array, row_index_num, [range_lookup])` -- horizontal lookup.
    ///
    /// Searches for `lookup_value` in the first row of the table and returns
    /// a value from the same column in the specified row.
    ///
    /// The `table_array` should be a flat `.array(...)` organized row-major.
    /// Since we cannot infer the number of columns from a flat array for HLOOKUP,
    /// we treat the first row as having all elements up to the first occurrence
    /// of `row_index_num` rows fitting evenly.
    ///
    /// Returns `#N/A` if not found, `#REF!` if `row_index_num` is out of bounds.
    static let hlookup = ExcelFunction(name: "HLOOKUP", minArgs: 3, maxArgs: 4) { args in
        catching {
            let lookupValue = args[0]
            let tableData = toArray(args[1])
            let rowIndex = Int(try toNumber(args[2]))
            let approximate = args.count > 3 ? isApproximate(args[3]) : true

            guard rowIndex >= 1 else { return .error(.value) }
            guard !tableData.isEmpty else { return .error(.na) }

            // For HLOOKUP, we need to know the number of columns.
            // We infer: numRows = rowIndex (minimum), numCols = total / numRows
            let numRows = rowIndex
            guard tableData.count >= numRows else { return .error(.ref) }

            let inferredRows: Int
            if tableData.count % numRows == 0 {
                inferredRows = numRows
            } else {
                var rows = numRows
                while rows <= tableData.count {
                    if tableData.count % rows == 0 {
                        break
                    }
                    rows += 1
                }
                inferredRows = rows <= tableData.count ? rows : numRows
            }

            let numCols = tableData.count / inferredRows
            guard numCols > 0 else { return .error(.na) }
            guard rowIndex <= inferredRows else { return .error(.ref) }

            if approximate {
                var bestCol: Int?
                for col in 0..<numCols {
                    let cellValue = tableData[col] // First row
                    if let cmp = compareValues(cellValue, lookupValue) {
                        if cmp <= 0 {
                            bestCol = col
                        } else {
                            break
                        }
                    }
                }
                guard let foundCol = bestCol else { return .error(.na) }
                return tableData[(rowIndex - 1) * numCols + foundCol]
            } else {
                for col in 0..<numCols {
                    let cellValue = tableData[col] // First row
                    if valuesEqual(cellValue, lookupValue) {
                        return tableData[(rowIndex - 1) * numCols + col]
                    }
                }
                return .error(.na)
            }
        }
    }

    // MARK: - INDEX

    /// `INDEX(array, row_num, [col_num])` -- returns the value at a position in an array.
    ///
    /// With just `row_num`: treats array as 1D and returns the element at that 1-based position.
    /// With both `row_num` and `col_num`: requires 2D indexing (not fully supported for flat arrays).
    ///
    /// Returns `#REF!` if the index is out of bounds.
    static let index = ExcelFunction(name: "INDEX", minArgs: 2, maxArgs: 3) { args in
        catching {
            let data = toArray(args[0])
            let rowNum = Int(try toNumber(args[1]))

            guard rowNum >= 1 else { return .error(.value) }

            if args.count == 2 {
                // 1D access
                guard rowNum <= data.count else { return .error(.ref) }
                return data[rowNum - 1]
            } else {
                // 2D access: col_num provided
                let colNum = Int(try toNumber(args[2]))
                guard colNum >= 1 else { return .error(.value) }
                // Without knowing dimensions, treat as: index = (rowNum - 1) * colNum_count + (colNum - 1)
                // But we don't know colNum_count. Use colNum as the stride hint.
                // Best effort: assume square-ish or use colNum as the total column count
                let index = (rowNum - 1) * colNum + (colNum - 1)
                // Actually, this doesn't work without knowing dimensions.
                // More practical: if col == 1, just do 1D access by row
                // For now, treat as flat: index = (rowNum - 1) when col is provided,
                // we need the number of columns. Let's use a simple heuristic:
                // find smallest cols >= colNum that divides evenly
                let numCols: Int
                if data.count % colNum == 0 && colNum <= data.count {
                    numCols = Swift.max(colNum, 1)
                } else {
                    numCols = colNum
                }
                let flatIndex = (rowNum - 1) * numCols + (colNum - 1)
                guard flatIndex >= 0, flatIndex < data.count else { return .error(.ref) }
                return data[flatIndex]
            }
        }
    }

    // MARK: - MATCH

    /// `MATCH(lookup_value, lookup_array, [match_type])` -- finds the position of a value in an array.
    ///
    /// - `match_type` = 1 (default): finds largest value <= `lookup_value` (array must be sorted ascending)
    /// - `match_type` = 0: exact match
    /// - `match_type` = -1: finds smallest value >= `lookup_value` (array must be sorted descending)
    ///
    /// Returns a 1-based position. Returns `#N/A` if not found.
    static let match = ExcelFunction(name: "MATCH", minArgs: 2, maxArgs: 3) { args in
        catching {
            let lookupValue = args[0]
            let lookupArray = toArray(args[1])
            let matchType: Int
            if args.count > 2 {
                matchType = Int(try toNumber(args[2]))
            } else {
                matchType = 1
            }

            guard !lookupArray.isEmpty else { return .error(.na) }

            switch matchType {
            case 0:
                // Exact match
                for (i, val) in lookupArray.enumerated() {
                    if valuesEqual(val, lookupValue) {
                        return .number(Double(i + 1))
                    }
                }
                return .error(.na)

            case 1:
                // Sorted ascending: find largest <= lookup_value
                var bestIndex: Int?
                for (i, val) in lookupArray.enumerated() {
                    if let cmp = compareValues(val, lookupValue) {
                        if cmp <= 0 {
                            bestIndex = i
                        } else {
                            break
                        }
                    }
                }
                guard let found = bestIndex else { return .error(.na) }
                return .number(Double(found + 1))

            case -1:
                // Sorted descending: find smallest >= lookup_value
                var bestIndex: Int?
                for (i, val) in lookupArray.enumerated() {
                    if let cmp = compareValues(val, lookupValue) {
                        if cmp >= 0 {
                            bestIndex = i
                        } else {
                            break
                        }
                    }
                }
                guard let found = bestIndex else { return .error(.na) }
                return .number(Double(found + 1))

            default:
                return .error(.na)
            }
        }
    }
}
