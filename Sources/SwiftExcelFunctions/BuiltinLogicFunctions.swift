import Foundation
import SwiftExcelCore

/// Logic: what a formula branches on, and the predicates that decide.
///
/// `IF`, `AND`, `OR`, `NOT`, `IFERROR` and `IFNA` choose a path. `ISERROR`,
/// `ISERR`, `ISNA`, `ISBLANK`, `ISNUMBER`, `ISTEXT` and `NA` answer questions
/// about a value, which is what the choosing is usually based on — a formula
/// guarding a division writes `IF(ISERROR(...))`, and without both halves neither
/// is any use.
///
/// Every function here asks about a *value*. None needs to know which cell it was
/// called from, which is what separates them from ``BuiltinNavigationFunctions``.
///
/// Register all functions at once via ``all``:
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinLogicFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinLogicFunctions {

    /// All logical functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        ifFunc, and, or, not, iferror, ifna,
        isError, isErr, isNA, isBlank, isNumber, isText, na, isRef,
    ]

    /// `ISREF(value)` — true when the argument is a reference.
    ///
    /// The odd one out among the predicates. The others ask about a *value*, and
    /// a value is what a function is handed; this asks whether the argument was a
    /// reference at all, which is a fact about the formula rather than about
    /// anything in the sheet. `ISREF(A1)` is true whatever A1 holds, and
    /// `ISREF("A1")` is false however much the text looks like one.
    ///
    /// So it reads the argument tree, the same way `COLUMN(B5)` does — and is the
    /// only predicate here that needs an evaluation context at all.
    public static let isRef = ExcelFunction(
        name: "ISREF", minArgs: 1, maxArgs: 1, withoutContext: .bool(false)
    ) { context, _ in
        .bool(context.referencedCell(at: 0) != nil)
    }

    // MARK: - Predicates
    //
    // A predicate answers about its argument rather than propagating it. That is
    // the entire point: `ISERROR(1/0)` is TRUE, not `#DIV/0!`, or it could never
    // be used to guard anything.

    /// `ISERROR(value)` — true for any Excel error, `#N/A` included.
    public static let isError = ExcelFunction(name: "ISERROR", minArgs: 1, maxArgs: 1) { args in
        if case .error = args[0] { return .bool(true) }
        return .bool(false)
    }

    /// `ISERR(value)` — true for any Excel error **except** `#N/A`.
    ///
    /// The distinction is deliberate in Excel and worth keeping: `#N/A` means "no
    /// value here yet", while the others mean the arithmetic went wrong. A lookup
    /// that has not matched is not the same as a division by zero.
    public static let isErr = ExcelFunction(name: "ISERR", minArgs: 1, maxArgs: 1) { args in
        if case .error(let error) = args[0] { return .bool(error != .na) }
        return .bool(false)
    }

    /// `ISNA(value)` — true only for `#N/A`.
    public static let isNA = ExcelFunction(name: "ISNA", minArgs: 1, maxArgs: 1) { args in
        if case .error(.na) = args[0] { return .bool(true) }
        return .bool(false)
    }

    /// `ISBLANK(value)` — true only for an empty cell.
    ///
    /// An empty *string* is not blank. A cell holding `""` was written to, and a
    /// sheet that distinguishes the two is usually doing so on purpose.
    public static let isBlank = ExcelFunction(name: "ISBLANK", minArgs: 1, maxArgs: 1) { args in
        if case .blank = args[0] { return .bool(true) }
        return .bool(false)
    }

    /// `ISNUMBER(value)` — true for numbers, and for nothing else.
    ///
    /// Text that looks like a number is not a number, and a boolean is not one
    /// either, even though Excel will coerce both in arithmetic. The predicate
    /// reports the type the cell actually holds.
    public static let isNumber = ExcelFunction(name: "ISNUMBER", minArgs: 1, maxArgs: 1) { args in
        if case .number = args[0] { return .bool(true) }
        return .bool(false)
    }

    /// `ISTEXT(value)` — true for text, and for nothing else.
    public static let isText = ExcelFunction(name: "ISTEXT", minArgs: 1, maxArgs: 1) { args in
        if case .text = args[0] { return .bool(true) }
        return .bool(false)
    }

    /// `NA()` — the `#N/A` error, as a value.
    ///
    /// How a sheet says "deliberately absent" rather than "zero", so that anything
    /// reading it propagates the absence instead of averaging in a nought.
    public static let na = ExcelFunction(name: "NA", minArgs: 0, maxArgs: 0) { _ in
        .error(.na)
    }

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
