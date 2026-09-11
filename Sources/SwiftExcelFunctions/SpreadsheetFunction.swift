import Foundation
import SwiftExcelCore

/// Why a spreadsheet could not be read as a function.
public enum SpreadsheetFunctionError: Error, Equatable, Sendable {

    /// A cell nominated as an input holds a formula.
    ///
    /// Excel's Solver refuses the same thing, and for the same reason: writing a value
    /// into a formula cell discards the formula silently, which produces a plausible
    /// wrong answer rather than a failure.
    case inputIsNotAConstant(CellRef)

    /// The argument vector did not match the inputs.
    case wrongInputCount(expected: Int, got: Int)

    /// An output evaluated to something that is not a number.
    ///
    /// Carries the value, because `#DIV/0!` and `#REF!` fail for different reasons and a
    /// caller chasing a bad model needs to know which.
    case outputNotNumeric(CellRef, CellValue)

    /// The sheet's formulas refer to each other in a circle, so no evaluation order exists.
    case circular
}

/// A spreadsheet, read as a function of some of its cells.
///
/// ```swift
/// import SwiftExcelCore
///
/// // Any provider that can enumerate itself will do; this one holds a single constant.
/// struct OneCell: CellValueProvider, PopulatedCellProvider {
///     func value(at ref: CellRef) -> CellValue? { .number(0) }
///     func value(at ref: CellRef, inSheet: String) -> CellValue? { value(at: ref) }
///     func values(in range: CellRange) -> [CellValue] { [] }
///     func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
///     func lastPopulatedCell() -> CellRef? { CellRef("A1") }
///     func lastPopulatedCell(inSheet: String) -> CellRef? { lastPopulatedCell() }
///     func populatedCells() -> [CellRef] { [CellRef("A1")] }
/// }
///
/// do {
///     let f = try SpreadsheetFunction(
///         inputs: [CellRef("A1")], outputs: [CellRef("A1")],
///         cells: OneCell(), names: NamedRangeCollection())
///     print(try f([3]))        // [3.0]
/// } catch {
///     print(error)
/// }
/// ```
///
/// ## The shape optimization and simulation share
///
/// Put values into designated cells, recompute the sheet in dependency order, read
/// designated cells back. ``InterpretedRun`` already did exactly that with random draws as
/// the driver; an optimizer needs it with candidate solutions as the driver instead. Naming
/// the shape once is what stops the two growing separate copies of the same loop.
///
/// It is a *function* in the sense that matters to a caller that will invoke it thousands
/// of times in an order nobody chose: each call computes into a fresh overlay rather than
/// mutating the sheet, so no call can observe another's leftovers.
///
/// ## What it refuses, and when
///
/// Both refusals happen at construction rather than on the thousandth call: an input that
/// holds a formula, and a sheet whose formulas form a cycle. An optimizer that discovers a
/// structural problem halfway through a search has already wasted the search.
public struct SpreadsheetFunction: Sendable {

    /// The cells a caller supplies, in the order its argument vector uses.
    public let inputs: [CellRef]

    /// The cells read back, in the order the result vector uses.
    public let outputs: [CellRef]

    private let cells: any CellValueProvider
    private let names: any NameResolver
    private let evaluationOrder: [CellRef]
    private let registry: FunctionRegistry

    /// Reads a spreadsheet as a function of the given cells.
    ///
    /// - Parameters:
    ///   - inputs: The cells to write, in argument order. Each must hold a constant.
    ///   - outputs: The cells to read, in result order.
    ///   - cells: The sheet. Must be able to enumerate itself, so the dependency order can
    ///     be computed rather than guessed.
    ///   - names: The named-range resolver.
    ///   - sheet: The sheet the addresses belong to.
    ///   - registry: The functions to evaluate with.
    /// - Throws: ``SpreadsheetFunctionError/inputIsNotAConstant(_:)`` or
    ///   ``SpreadsheetFunctionError/circular``.
    public init(
        inputs: [CellRef],
        outputs: [CellRef],
        cells: any CellValueProvider & PopulatedCellProvider,
        names: any NameResolver,
        sheet: String = "",
        registry: FunctionRegistry = .builtin
    ) throws {
        for input in inputs where cells.value(at: input)?.formulaAST != nil {
            throw SpreadsheetFunctionError.inputIsNotAConstant(input)
        }
        // The same construction ``InterpretedRun`` uses, deliberately: two topological
        // sorts that could disagree is precisely what the evaluator relies on not existing.
        let addresses = cells.populatedCells().map { CellAddress(sheet: sheet, cell: $0) }
        let graph = DependencyGraph(cells: addresses, provider: cells)
        guard graph.isAcyclic else { throw SpreadsheetFunctionError.circular }
        let order = graph.evaluationOrder.map(\.cell)
        self.inputs = inputs
        self.outputs = outputs
        self.cells = cells
        self.names = names
        self.evaluationOrder = order
        self.registry = registry
    }

    /// Evaluates the sheet at one point.
    ///
    /// - Parameter x: One value per entry of ``inputs``.
    /// - Returns: One value per entry of ``outputs``.
    /// - Throws: ``SpreadsheetFunctionError/wrongInputCount(expected:got:)``,
    ///   ``SpreadsheetFunctionError/outputNotNumeric(_:_:)``, or whatever evaluating a
    ///   formula throws.
    public func callAsFunction(_ x: [Double]) throws -> [Double] {
        guard x.count == inputs.count else {
            throw SpreadsheetFunctionError.wrongInputCount(expected: inputs.count, got: x.count)
        }

        // A fresh overlay per call. The sheet underneath is never written to, which is what
        // lets an optimizer call this concurrently and out of order.
        var pass = MutableCells(base: cells)
        for (ref, value) in zip(inputs, x) {
            pass.overrides[ref.positionKey] = .number(value)
        }
        for ref in evaluationOrder {
            guard let ast = cells.value(at: ref)?.formulaAST else { continue }
            pass.overrides[ref.positionKey] = try FormulaEvaluator.evaluate(
                ast, cells: pass, names: names, functions: registry,
                at: nil, inSheet: "")
        }

        return try outputs.map { ref in
            let value = pass.overrides[ref.positionKey] ?? cells.value(at: ref) ?? .blank
            guard case .number(let number) = value else {
                // Not silently zero. An objective that reads `#DIV/0!` as 0 is the
                // plausible wrong answer an optimizer will happily march towards.
                throw SpreadsheetFunctionError.outputNotNumeric(ref, value)
            }
            return number
        }
    }
}
