import Foundation
import SwiftExcelCore

/// Evaluates a `FormulaAST` to a concrete `CellValue`.
///
/// The evaluator walks the AST tree recursively, resolving cell references via a
/// `CellValueProvider`, named ranges via a `NameResolver`, and function calls
/// via a ``FunctionRegistry``.
///
/// The provider is the seam: anything that can answer "what is in this cell"
/// will do, and nothing here needs to know what a workbook or a file is.
///
/// ```swift
/// import SwiftExcelCore
///
/// struct Cells: CellValueProvider {
///     let values: [CellRef: CellValue]
///     func value(at ref: CellRef) -> CellValue? { values[ref] }
///     func value(at ref: CellRef, inSheet: String) -> CellValue? { values[ref] }
///
///     // Where the data stops. Answering this is what lets `$A:$A` be read at all,
///     // and `matrix(in:)` then comes free from the protocol's own default.
///     func lastPopulatedCell() -> CellRef? {
///         guard let column = values.keys.map(\.column).max(),
///               let row = values.keys.map(\.row).max() else { return nil }
///         return CellRef(column: column, row: row)
///     }
///     func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
///
///     func values(in range: CellRange) -> [CellValue] { range.cells.compactMap { values[$0] } }
///     func values(in range: CellRange, inSheet: String) -> [CellValue] { self.values(in: range) }
/// }
///
/// let cells = Cells(values: [CellRef("A1"): .number(1)])
/// let names = NamedRangeCollection()
/// let result = try FormulaEvaluator.evaluate(
///     .add(.number(1), .number(2)),
///     cells: cells,
///     names: names
/// )
/// // result == .number(3)
/// ```
///
/// ## Type Coercion
///
/// The evaluator applies Excel-style type coercion for arithmetic and comparison:
/// - `.text("5")` coerces to `5.0`; non-numeric text yields `.error(.value)`
/// - `.bool(true)` coerces to `1.0`, `.bool(false)` to `0.0`
/// - `.blank` coerces to `0.0` for numbers, `""` for strings
/// - `.error` values propagate immediately
///
/// ## Depth Limit
///
/// Evaluation depth is capped at 256 to prevent stack overflow on deeply nested formulas.
public enum FormulaEvaluator {

    /// The maximum evaluation depth before raising ``EvaluationError/evaluationDepthExceeded``.
    public static let maxDepth = 256

    /// Errors that can occur during formula evaluation.
    public enum EvaluationError: Error, Equatable, Sendable {
        /// The function name was not found in the registry.
        case unknownFunction(String)
        /// The argument count did not match the function's expected range.
        case argumentCount(function: String, expected: ClosedRange<Int>, got: Int)
        /// A circular reference was detected.
        case circularReference // LIVE: public API for consumers
        /// A type mismatch occurred during coercion.
        case typeMismatch(expected: String, got: String)
        /// The evaluation recursion depth exceeded ``FormulaEvaluator/maxDepth``.
        case evaluationDepthExceeded
    }

    /// Evaluates a formula AST to a concrete cell value.
    ///
    /// - Parameters:
    ///   - ast: The formula AST to evaluate.
    ///   - cells: A provider for looking up cell values.
    ///   - names: A resolver for named range identifiers.
    ///   - functions: The function registry (defaults to ``FunctionRegistry/builtin``).
    ///   - callingCell: The cell this formula was written in. `COLUMN()` and
    ///     `ROW()` answer about it, so leaving it `nil` — which is right when a
    ///     formula is evaluated on its own rather than out of a sheet — makes
    ///     them report that there is no position rather than invent one.
    ///   - currentSheet: The sheet an unqualified reference belongs to, used by
    ///     `INDIRECT` when the text it is given does not name a sheet itself.
    ///   - random: Where `RAND()` and `RANDBETWEEN()` draw from. `nil` — the
    ///     default — means they answer `#VALUE!`, because this package supplies
    ///     no randomness of its own and will not invent any.
    /// - Returns: The resulting `CellValue`.
    /// - Throws: ``EvaluationError`` if evaluation fails.
    public static func evaluate(
        _ ast: FormulaAST,
        cells: CellValueProvider,
        names: NameResolver,
        functions: FunctionRegistry = .builtin,
        at callingCell: CellAddress? = nil,
        inSheet currentSheet: String = "",
        random: (any RandomSource)? = nil
    ) throws -> CellValue {
        try evaluateNode(
            ast, cells: cells, names: names, functions: functions,
            callingCell: callingCell, currentSheet: currentSheet,
            random: random, depth: 0)
    }

    // MARK: - Private Recursive Evaluator

    private static func evaluateNode(
        _ ast: FormulaAST,
        cells: CellValueProvider,
        names: NameResolver,
        functions: FunctionRegistry,
        callingCell: CellAddress?,
        currentSheet: String,
        random: (any RandomSource)?,
        depth: Int
    ) throws -> CellValue {
        guard depth < maxDepth else {
            throw EvaluationError.evaluationDepthExceeded
        }

        let nextDepth = depth + 1

        switch ast {
        // MARK: Literals
        case .number(let n):
            return .number(n)
        case .text(let s):
            return .text(s)
        case .bool(let b):
            return .bool(b)
        case .error(let e):
            return .error(e)

        case .missing:
            // An argument that is not there evaluates to blank, and the function
            // decides what that means for it. `ADDRESS` reads an omitted fourth
            // argument as its default reference style; `IFERROR` reads an omitted
            // second as empty. Neither is 0, so blank is what gets passed and the
            // interpretation stays where it belongs.
            return .blank

        // MARK: References
        case .cellRef(let ref):
            return cells.value(at: ref) ?? .blank

        case .cellRange(let range):
            return .array(cells.matrix(in: range))

        case .sheetRef(let sheetRef):
            let range = sheetRef.range
            if range.start == range.end {
                // Single cell reference
                return cells.value(at: range.start, inSheet: sheetRef.sheetName) ?? .blank
            } else {
                return .array(cells.matrix(in: range, inSheet: sheetRef.sheetName))
            }

        case .namedRange(let name):
            guard let target = names.resolve(name, inSheet: nil) else {
                return .error(.name)
            }
            return try evaluateNamedTarget(
                target, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth
            )

        // MARK: Arithmetic
        case .add(let lhs, let rhs):
            let left = try evaluateNode(lhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = right { return right }
            return try addValues(left, right)

        case .subtract(let lhs, let rhs):
            let left = try evaluateNode(lhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = right { return right }
            return try subtractValues(left, right)

        case .multiply(let lhs, let rhs):
            let left = try evaluateNode(lhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = right { return right }
            return try multiplyValues(left, right)

        case .divide(let lhs, let rhs):
            let left = try evaluateNode(lhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = right { return right }
            return try divideValues(left, right)

        case .power(let lhs, let rhs):
            let left = try evaluateNode(lhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = right { return right }
            return try powerValues(left, right)

        case .negate(let expr):
            let value = try evaluateNode(expr, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = value { return value }
            return try negateValue(value)

        case .concatenate(let lhs, let rhs):
            let left = try evaluateNode(lhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = right { return right }
            return .text(coerceToString(left) + coerceToString(right))

        // MARK: Comparison
        case .equal(let lhs, let rhs):
            let left = try evaluateNode(lhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = right { return right }
            return .bool(compareValues(left, right) == .orderedSame)

        case .notEqual(let lhs, let rhs):
            let left = try evaluateNode(lhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = right { return right }
            return .bool(compareValues(left, right) != .orderedSame)

        case .greaterThan(let lhs, let rhs):
            let left = try evaluateNode(lhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = right { return right }
            return .bool(compareValues(left, right) == .orderedDescending)

        case .lessThan(let lhs, let rhs):
            let left = try evaluateNode(lhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = right { return right }
            return .bool(compareValues(left, right) == .orderedAscending)

        case .greaterOrEqual(let lhs, let rhs):
            let left = try evaluateNode(lhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = right { return right }
            let cmp = compareValues(left, right)
            return .bool(cmp == .orderedDescending || cmp == .orderedSame)

        case .lessOrEqual(let lhs, let rhs):
            let left = try evaluateNode(lhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth)
            if case .error = right { return right }
            let cmp = compareValues(left, right)
            return .bool(cmp == .orderedAscending || cmp == .orderedSame)

        // MARK: Function Call
        case .function(let name, let args):
            guard let fn = functions.function(named: name) else {
                throw EvaluationError.unknownFunction(name)
            }
            let maxArgs = fn.maxArgs ?? Int.max
            let expectedRange = fn.minArgs...maxArgs
            guard expectedRange.contains(args.count) else {
                throw EvaluationError.argumentCount(
                    function: name, expected: fn.minArgs...(fn.maxArgs ?? fn.minArgs), got: args.count
                )
            }
            var evaluatedArgs: [CellValue] = []
            evaluatedArgs.reserveCapacity(args.count)
            for arg in args {
                let val = try evaluateNode(
                    arg, cells: cells, names: names, functions: functions, callingCell: callingCell, currentSheet: currentSheet, random: random, depth: nextDepth
                )
                evaluatedArgs.append(val)
            }
            // A function that needs more than its arguments gets the context;
            // everything else keeps the signature it has always had.
            if let inContext = fn.evaluateInContext {
                let context = EvaluationContext(
                    callingCell: callingCell,
                    currentSheet: currentSheet,
                    cells: cells,
                    arguments: args,
                    random: random)
                return try inContext(context, evaluatedArgs)
            }
            return try fn.evaluate(evaluatedArgs)
        }
    }

    // MARK: - Named Range Resolution

    private static func evaluateNamedTarget(
        _ target: NamedRangeTarget,
        cells: CellValueProvider,
        names: NameResolver,
        functions: FunctionRegistry,
        callingCell: CellAddress?,
        currentSheet: String,
        random: (any RandomSource)?,
        depth: Int
    ) throws -> CellValue {
        switch target {
        case .cell(let ref):
            return cells.value(at: ref) ?? .blank
        case .range(let range):
            return .array(cells.matrix(in: range))
        case .sheetCell(let sheetRef):
            return cells.value(at: sheetRef.range.start, inSheet: sheetRef.sheetName) ?? .blank
        case .sheetRange(let sheetRef):
            return .array(cells.matrix(in: sheetRef.range, inSheet: sheetRef.sheetName))
        case .formula(let ast):
            return try evaluateNode(
                ast, cells: cells, names: names, functions: functions,
                callingCell: callingCell, currentSheet: currentSheet, random: random, depth: depth)
        }
    }

    // MARK: - Type Coercion

    /// Coerces a `CellValue` to a `Double`, following Excel semantics.
    ///
    /// - `.number(n)` -> `n`
    /// - `.text(s)` -> parsed Double, or throws typeMismatch
    /// - `.bool(true)` -> `1.0`, `.bool(false)` -> `0.0`
    /// - `.blank` -> `0.0`
    /// - `.error` -> propagated (should be caught before calling)
    /// - `.date` -> serial date number
    /// - `.formula` -> coerce cached value
    /// - `.array` -> typeMismatch
    private static func coerceToNumber(_ value: CellValue) throws -> Double {
        switch value {
        case .number(let n):
            return n
        case .text(let s):
            guard let n = Double(s) else {
                throw EvaluationError.typeMismatch(expected: "number", got: "text(\(s))")
            }
            return n
        case .bool(let b):
            return b ? 1.0 : 0.0
        case .blank:
            return 0.0
        case .error:
            // Errors should be caught before calling coercion
            throw EvaluationError.typeMismatch(expected: "number", got: "error")
        case .date(let d):
            return d.timeIntervalSinceReferenceDate / 86_400.0
        case .formula(_, let cached):
            return try coerceToNumber(cached ?? .blank)
        case .array:
            throw EvaluationError.typeMismatch(expected: "number", got: "array")
        }
    }

    /// Coerces a `CellValue` to a `String`, following Excel semantics.
    ///
    /// - `.text(s)` -> `s`
    /// - `.number(n)` -> formatted number string
    /// - `.bool(true)` -> `"TRUE"`, `.bool(false)` -> `"FALSE"`
    /// - `.blank` -> `""`
    /// - `.error(e)` -> error description
    /// - `.date` -> ISO date string
    /// - `.formula` -> coerce cached value
    /// - `.array` -> `""`
    private static func coerceToString(_ value: CellValue) -> String {
        switch value {
        case .text(let s):
            return s
        case .number(let n):
            if n.truncatingRemainder(dividingBy: 1) == 0 && Swift.abs(n) < 1e15 {
                return String(Int(n))
            }
            return String(n)
        case .bool(let b):
            return b ? "TRUE" : "FALSE"
        case .blank:
            return ""
        case .error(let e):
            return e.rawValue
        case .date(let d):
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: d)
        case .formula(_, let cached):
            return coerceToString(cached ?? .blank)
        case .array:
            return ""
        }
    }

    // MARK: - Arithmetic Operations

    private static func addValues(_ left: CellValue, _ right: CellValue) throws -> CellValue {
        do {
            let l = try coerceToNumber(left)
            let r = try coerceToNumber(right)
            return .number(l + r)
        } catch {
            return .error(.value)
        }
    }

    private static func subtractValues(_ left: CellValue, _ right: CellValue) throws -> CellValue {
        do {
            let l = try coerceToNumber(left)
            let r = try coerceToNumber(right)
            return .number(l - r)
        } catch {
            return .error(.value)
        }
    }

    private static func multiplyValues(_ left: CellValue, _ right: CellValue) throws -> CellValue {
        do {
            let l = try coerceToNumber(left)
            let r = try coerceToNumber(right)
            return .number(l * r)
        } catch {
            return .error(.value)
        }
    }

    private static func divideValues(_ left: CellValue, _ right: CellValue) throws -> CellValue {
        do {
            let l = try coerceToNumber(left)
            let r = try coerceToNumber(right)
            guard r != 0 else { return .error(.div0) }
            return .number(l / r)
        } catch {
            return .error(.value)
        }
    }

    private static func powerValues(_ left: CellValue, _ right: CellValue) throws -> CellValue {
        do {
            let l = try coerceToNumber(left)
            let r = try coerceToNumber(right)
            let result = pow(l, r)
            guard result.isFinite else { return .error(.num) }
            return .number(result)
        } catch {
            return .error(.value)
        }
    }

    private static func negateValue(_ value: CellValue) throws -> CellValue {
        do {
            let n = try coerceToNumber(value)
            return .number(-n)
        } catch {
            return .error(.value)
        }
    }

    // MARK: - Comparison

    /// Compares two cell values using Excel comparison semantics.
    ///
    /// Excel comparison rules:
    /// - Numbers are compared numerically
    /// - Strings are compared case-insensitively
    /// - Booleans: FALSE < TRUE
    /// - Different types: numbers < text < booleans (Excel ordering)
    /// - Blank is treated as 0 for numeric comparison, "" for string
    private static func compareValues(_ left: CellValue, _ right: CellValue) -> ComparisonResult {
        let lNorm = normalizeForComparison(left)
        let rNorm = normalizeForComparison(right)

        switch (lNorm, rNorm) {
        case (.number(let a), .number(let b)):
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
            return .orderedSame

        case (.text(let a), .text(let b)):
            return a.caseInsensitiveCompare(b)

        case (.bool(let a), .bool(let b)):
            if a == b { return .orderedSame }
            // FALSE < TRUE
            return a ? .orderedDescending : .orderedAscending

        // Excel type ordering: number < text < bool
        case (.number, .text): return .orderedAscending
        case (.text, .number): return .orderedDescending
        case (.number, .bool): return .orderedAscending
        case (.bool, .number): return .orderedDescending
        case (.text, .bool): return .orderedAscending
        case (.bool, .text): return .orderedDescending

        default:
            return .orderedSame
        }
    }

    /// Normalizes a value for comparison, converting blank to its default comparand.
    private static func normalizeForComparison(_ value: CellValue) -> CellValue {
        switch value {
        case .blank:
            return .number(0)
        case .formula(_, let cached):
            return normalizeForComparison(cached ?? .blank)
        default:
            return value
        }
    }
}
