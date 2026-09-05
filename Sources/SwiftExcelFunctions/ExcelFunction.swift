import Foundation
import SwiftExcelCore

/// A registered Excel function with name, arity constraints, and evaluation logic.
///
/// Each ``ExcelFunction`` encapsulates the name, argument bounds, and a
/// pure evaluation closure that maps an array of `CellValue` inputs
/// to a single `CellValue` output.
///
/// ```swift
/// let abs = ExcelFunction(
///     name: "ABS", minArgs: 1, maxArgs: 1
/// ) { args in
///     guard case .number(let n) = args[0] else { return .error(.value) }
///     return .number(Swift.abs(n))
/// }
/// ```
public struct ExcelFunction: Sendable {
    /// The Excel function name (uppercase by convention, e.g. `"ABS"`).
    public let name: String

    /// Minimum number of arguments required.
    public let minArgs: Int

    /// Maximum number of arguments accepted, or `nil` for variadic.
    public let maxArgs: Int?

    /// The evaluation closure that computes the result from input arguments.
    public let evaluate: @Sendable ([CellValue]) throws -> CellValue

    /// An alternative closure for a function that needs more than its arguments.
    ///
    /// `nil` for almost every function, and deliberately so: adding the context to
    /// the one signature would have changed all 75 existing functions to serve
    /// five. The evaluator prefers this closure where a function supplies one.
    ///
    /// See ``EvaluationContext`` for what "more than its arguments" means — the
    /// calling cell, a way to read other cells, and the unevaluated argument trees.
    public let evaluateInContext: (@Sendable (EvaluationContext, [CellValue]) throws -> CellValue)?

    /// Creates an Excel function definition.
    ///
    /// - Parameters:
    ///   - name: The function name (uppercase).
    ///   - minArgs: Minimum required argument count.
    ///   - maxArgs: Maximum argument count, or `nil` for variadic.
    ///   - evaluate: A closure that computes the result from cell value arguments.
    public init(
        name: String,
        minArgs: Int,
        maxArgs: Int?,
        evaluate: @escaping @Sendable ([CellValue]) throws -> CellValue
    ) {
        self.evaluateInContext = nil
        self.name = name
        self.minArgs = minArgs
        self.maxArgs = maxArgs
        self.evaluate = evaluate
    }
    /// `ROW`, `INDIRECT`, `OFFSET`. The plain ``evaluate`` closure is still
    /// supplied, and answers as well as it can without a context: outside a sheet
    /// there is no calling cell and no provider, so it reports that rather than
    /// guessing a position.
    ///
    /// - Parameters:
    ///   - name: The function name (uppercase).
    ///   - minArgs: Minimum required argument count.
    ///   - maxArgs: Maximum argument count, or `nil` for variadic.
    ///   - withoutContext: The result when no context is available.
    ///   - evaluate: A closure taking the context and the evaluated arguments.
    public init(
        name: String,
        minArgs: Int,
        maxArgs: Int?,
        withoutContext: CellValue = .error(.value),
        evaluate: @escaping @Sendable (EvaluationContext, [CellValue]) throws -> CellValue
    ) {
        self.name = name
        self.minArgs = minArgs
        self.maxArgs = maxArgs
        self.evaluate = { _ in withoutContext }
        self.evaluateInContext = evaluate
    }
}

/// Errors thrown during Excel function evaluation.
public enum ExcelFunctionError: Error, Sendable, Equatable {
    /// The argument count is outside the function's accepted range.
    case invalidArgCount(expected: Int, got: Int) // LIVE: public API for consumers

    /// An argument had the wrong type for the operation.
    case invalidArgType(String) // LIVE: public API for consumers

    /// A generic evaluation error with a message.
    case evaluationError(String) // LIVE: public API for consumers

    /// Creates a function that needs its evaluation context.
    ///
    /// For the few that cannot answer from their arguments alone — `COLUMN`,
}
