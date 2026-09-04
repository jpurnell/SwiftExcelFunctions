import Foundation
import SwiftExcelCore

/// Logical category built-in Excel functions.
///
/// Provides implementations of 6 standard Excel logical functions:
/// `IF`, `AND`, `OR`, `NOT`, `IFERROR`, and `IFNA`.
///
/// Register all functions at once via ``all``:
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinLogicalFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinLogicalFunctions {

    /// All logical functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [ifFunc, and, or, not, iferror, ifna]

    // MARK: - Truthiness

    /// Evaluates the truthiness of a `CellValue` using Excel semantics.
    ///
    /// - Truthy: `.bool(true)`, `.number(non-zero)`
    /// - Falsy: `.bool(false)`, `.number(0)`, `.blank`
    /// - `.text` returns `#VALUE!` error
    /// - `.error` propagates the error
    ///
    /// - Parameter value: The cell value to test.
    /// - Returns: A boolean result, or throws on type mismatch / error propagation.
    private static func isTruthy(_ value: CellValue) throws -> Bool {
        switch value {
        case .bool(let b):
            return b
        case .number(let n):
            return n != 0
        case .blank:
            return false
        case .error(let e):
            throw EvalError.excelError(e)
        case .text:
            throw EvalError.typeMismatch
        case .date:
            throw EvalError.typeMismatch
        case .formula(_, let cached):
            return try isTruthy(cached ?? .blank)
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

    /// Flattens nested arrays in a list of `CellValue` arguments into a single flat list.
    private static func flatten(_ args: [CellValue]) -> [CellValue] {
        var result: [CellValue] = []
        for arg in args {
            if case .array(let elements) = arg {
                result.append(contentsOf: flatten(elements))
            } else {
                result.append(arg)
            }
        }
        return result
    }

    // MARK: - IF

    /// `IF(logical_test, value_if_true, value_if_false)` -- conditional evaluation.
    ///
    /// Returns the second argument if `logical_test` is truthy, otherwise returns
    /// the third argument. Returns `#VALUE!` if the test is a text value.
    static let ifFunc = ExcelFunction(name: "IF", minArgs: 2, maxArgs: 3) { args in
        catching {
            let test = try isTruthy(args[0])
            if test {
                return args[1]
            } else {
                return args.count > 2 ? args[2] : .bool(false)
            }
        }
    }

    // MARK: - AND

    /// `AND(logical1, [logical2], ...)` -- TRUE if all arguments are truthy.
    ///
    /// Flattens arrays before evaluation. Ignores blanks within arrays.
    static let and = ExcelFunction(name: "AND", minArgs: 1, maxArgs: nil) { args in
        catching {
            let flat = flatten(args)
            guard !flat.isEmpty else { return .error(.value) }
            for value in flat {
                let result = try isTruthy(value)
                if !result { return .bool(false) }
            }
            return .bool(true)
        }
    }

    // MARK: - OR

    /// `OR(logical1, [logical2], ...)` -- TRUE if any argument is truthy.
    ///
    /// Flattens arrays before evaluation. Ignores blanks within arrays.
    static let or = ExcelFunction(name: "OR", minArgs: 1, maxArgs: nil) { args in
        catching {
            let flat = flatten(args)
            guard !flat.isEmpty else { return .error(.value) }
            for value in flat {
                let result = try isTruthy(value)
                if result { return .bool(true) }
            }
            return .bool(false)
        }
    }

    // MARK: - NOT

    /// `NOT(logical)` -- inverts a boolean value.
    ///
    /// Returns `TRUE` if the argument is falsy, `FALSE` if truthy.
    static let not = ExcelFunction(name: "NOT", minArgs: 1, maxArgs: 1) { args in
        catching {
            let result = try isTruthy(args[0])
            return .bool(!result)
        }
    }

    // MARK: - IFERROR

    /// `IFERROR(value, value_if_error)` -- returns `value_if_error` if the first
    /// argument is any Excel error, otherwise returns the first argument.
    static let iferror = ExcelFunction(name: "IFERROR", minArgs: 2, maxArgs: 2) { args in
        if case .error = args[0] {
            return args[1]
        }
        return args[0]
    }

    // MARK: - IFNA

    /// `IFNA(value, value_if_na)` -- returns `value_if_na` if the first argument
    /// is specifically `#N/A`, otherwise returns the first argument unchanged
    /// (including other errors).
    static let ifna = ExcelFunction(name: "IFNA", minArgs: 2, maxArgs: 2) { args in
        if case .error(let e) = args[0], e == .na {
            return args[1]
        }
        return args[0]
    }
}
