import Foundation
import SwiftExcelCore

/// The six functions that take a `LAMBDA` and do something with it.
///
/// `MAP`, `REDUCE`, `SCAN`, `BYROW`, `BYCOL` and `MAKEARRAY` — the payoff for the five steps
/// before them. Each is a handful of lines once a lambda is a value that can be called, and
/// none of them would be expressible at all without that.
///
/// ## Why these are special forms
///
/// Not because their arguments must go unevaluated — they must not; `MAP(A1:A4, f)` evaluates
/// both. It is that **calling** the lambda needs the evaluator, and an `ExcelFunction` closure
/// is handed values and no way to evaluate anything. So the evaluator reaches these the way it
/// reaches `LET`, and hands them the means to call back into itself.
///
/// ## Iteration is not recursion
///
/// `REDUCE` over 2,000 elements is 2,000 calls and it works, where a recursion 2,000 deep does
/// not — the stack guard stops that at about 160. These loop in Swift; only the lambda body is
/// evaluated recursively, and it returns before the next element is reached. The conformance
/// round found the same thing in Excel: `REDUCE` reached 8,192 with no limit found, while a
/// recursive `LAMBDA` refuses at 4,096.
enum BuiltinHigherOrderFunctions {

    /// The registry entries, for their names and arities. Every one is intercepted by the
    /// evaluator before its closure could run; the closures say so rather than guessing.
    static let all: [ExcelFunction] = [
        form("MAP", minArgs: 2), form("REDUCE", minArgs: 3), form("SCAN", minArgs: 3),
        form("BYROW", minArgs: 2), form("BYCOL", minArgs: 2), form("MAKEARRAY", minArgs: 3),
    ]

    /// Whether the evaluator must reach this name before dispatching normally.
    static func governs(_ canonicalName: String) -> Bool {
        all.contains { $0.name == canonicalName }
    }

    private static func form(_ name: String, minArgs: Int) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: minArgs, maxArgs: nil) { _ in
            // Reached only if something calls this directly with values in hand. By then
            // there is no way to invoke the lambda, which is the whole of what it does.
            .error(.calc)
        }
    }

    /// How a higher-order function calls the lambda it was given.
    typealias Invoke = (_ lambda: CellValue, _ arguments: [CellValue]) throws -> CellValue

    /// Evaluates one of the six.
    ///
    /// - Parameters:
    ///   - name: the canonical name.
    ///   - arguments: the evaluated arguments; the lambda is the last for all but `MAKEARRAY`.
    ///   - invoke: calls a lambda value with arguments.
    /// - Returns: the result, or `nil` if this is not one of the six.
    static func evaluate(
        _ name: String, arguments: [CellValue], invoke: Invoke
    ) throws -> CellValue? {
        guard governs(name) else { return nil }

        // Both checks happen here, before any iteration, because both are facts about the
        // *call* rather than about an element. Left to the loop they answer correctly and in
        // the wrong shape: `MAP(A1:A4, 3)` returned a four-element array of `#VALUE!`, which
        // is a rectangle of the right verdict where one verdict belongs.
        guard case .lambda(let parameters, _, _)? = arguments.last else { return .error(.value) }

        // How many values this function will hand the lambda. Exact, not at-most: omission is
        // something a formula author writes, and `MAP` is not an author.
        let expected: Int
        switch name {
        case "MAP": expected = arguments.count - 1   // one value per array
        case "REDUCE", "SCAN", "MAKEARRAY": expected = 2
        default: expected = 1                        // BYROW, BYCOL — one line at a time
        }
        guard parameters.count == expected else { return .error(.value) }

        switch name {
        case "MAP": return try map(arguments, invoke)
        case "REDUCE": return try fold(arguments, invoke, keepingSteps: false)
        case "SCAN": return try fold(arguments, invoke, keepingSteps: true)
        case "BYROW": return try by(arguments, invoke, rows: true)
        case "BYCOL": return try by(arguments, invoke, rows: false)
        case "MAKEARRAY": return try makeArray(arguments, invoke)
        default: return nil
        }
    }

    // MARK: - One at a time

    /// `MAP(array, [array…], lambda)` — the lambda applied to matching positions.
    private static func map(_ arguments: [CellValue], _ invoke: Invoke) throws -> CellValue {
        guard let lambda = arguments.last else { return .error(.value) }
        let arrays = arguments.dropLast().map(matrix(of:))
        guard let first = arrays.first else { return .error(.value) }

        // Every array must be the same shape, because `MAP` walks them together and there is
        // no position in one that corresponds to nothing in another.
        guard arrays.allSatisfy({ $0.rows == first.rows && $0.columns == first.columns }) else {
            return .error(.value)
        }

        var results: [CellValue] = []
        results.reserveCapacity(first.elements.count)
        for position in first.elements.indices {
            results.append(try invoke(lambda, arrays.map { $0.elements[position] }))
        }
        return shaped(results, rows: first.rows, columns: first.columns)
    }

    /// `REDUCE(initial, array, lambda)` and `SCAN`, which differ only in what they keep.
    private static func fold(
        _ arguments: [CellValue], _ invoke: Invoke, keepingSteps: Bool
    ) throws -> CellValue {
        guard arguments.count >= 3, let lambda = arguments.last else { return .error(.value) }
        let values = matrix(of: arguments[1])

        var accumulator = arguments[0]
        var steps: [CellValue] = []
        if keepingSteps { steps.reserveCapacity(values.elements.count) }

        // A Swift loop, not a recursion. Only the lambda's body recurses, and it returns
        // before the next element is reached — which is why 2,000 elements work where a
        // 2,000-deep recursion does not.
        for value in values.elements {
            accumulator = try invoke(lambda, [accumulator, value])
            if case .error = accumulator { return accumulator }
            if keepingSteps { steps.append(accumulator) }
        }
        guard keepingSteps else { return accumulator }
        return shaped(steps, rows: values.rows, columns: values.columns)
    }

    /// `BYROW(array, lambda)` and `BYCOL`, which hand the lambda a whole line at a time.
    private static func by(
        _ arguments: [CellValue], _ invoke: Invoke, rows byRow: Bool
    ) throws -> CellValue {
        guard arguments.count >= 2, let lambda = arguments.last else { return .error(.value) }
        let values = matrix(of: arguments[0])

        let lines = byRow ? values.rows : values.columns
        var results: [CellValue] = []
        results.reserveCapacity(lines)
        for line in 0..<lines {
            // The whole line, not its first cell. `BYROW(A1:C2, LAMBDA(r, SUM(r)))` sums a
            // row; handing the lambda one value would answer 1 and 4 instead of 6 and 15.
            let slice = byRow
                ? (0..<values.columns).map { values[line, $0] }
                : (0..<values.rows).map { values[$0, line] }
            let shape = byRow
                ? CellMatrix(row: slice)
                : CellMatrix(column: slice)
            results.append(try invoke(lambda, [.array(shape)]))
        }
        // One answer per line: a column of them for `BYROW`, a row for `BYCOL`.
        return shaped(results, rows: byRow ? lines : 1, columns: byRow ? 1 : lines)
    }

    /// `MAKEARRAY(rows, columns, lambda)` — built from its own indices.
    private static func makeArray(
        _ arguments: [CellValue], _ invoke: Invoke
    ) throws -> CellValue {
        guard arguments.count >= 3, let lambda = arguments.last,
              let rows = count(arguments[0]), let columns = count(arguments[1]) else {
            return .error(.value)
        }
        var results: [CellValue] = []
        results.reserveCapacity(rows * columns)
        for row in 1...rows {
            for column in 1...columns {
                // One-based, as everything a formula counts is.
                results.append(try invoke(lambda, [.number(Double(row)), .number(Double(column))]))
            }
        }
        return shaped(results, rows: rows, columns: columns)
    }

    // MARK: - Shapes

    /// Any value as a rectangle, so one path walks both a range and a single cell.
    private static func matrix(of value: CellValue) -> CellMatrix {
        if case .array(let matrix) = value { return matrix }
        return CellMatrix(single: value)
    }

    /// A positive whole count, or `nil` if the argument does not name one.
    private static func count(_ value: CellValue) -> Int? {
        guard case .number(let number) = value.resolved,
              let whole = Int(exactly: number.rounded()), whole >= 1 else { return nil }
        return whole
    }

    private static func shaped(_ elements: [CellValue], rows: Int, columns: Int) -> CellValue {
        guard let matrix = CellMatrix(elements: elements, rows: rows, columns: columns) else {
            return .error(.value)
        }
        return .array(matrix)
    }
}
