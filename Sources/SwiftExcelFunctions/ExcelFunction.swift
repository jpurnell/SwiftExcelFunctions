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
        self.name = name
        self.minArgs = minArgs
        self.maxArgs = maxArgs
        self.evaluate = evaluate
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
}
