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
/// ## Depth limits
///
/// Three bounds, because Excel keeps two and the stack needs a third. See
/// ``maxCallDepth``, ``maxRecursionDepth`` and ``maxNodeDepth``, and
/// `project/docs/technical/ExcelEvaluationLimits.md` for how the first two were measured.
public enum FormulaEvaluator {

    /// How deep an expression may nest: **65 function calls**.
    ///
    /// Measured against Excel 16.114, and the bracket has no slack in it — Excel kept the
    /// cells asking for 2, 8, 32, 60, 62, 63, 64 and 65, and deleted exactly those asking for
    /// 66, 70, 100 and 128. Microsoft documents "nested levels of functions: 64", which is
    /// consistent with 65 if the outermost call is not counted as nesting; both are right
    /// under their own reading and an implementation should key off the measured one.
    ///
    /// **A violation is a fact about the file, not about the formula.** Excel does not
    /// evaluate an over-nested formula and return an error — it refuses the *file*, deleting
    /// the cell and reporting the workbook as damaged. An evaluator has nothing to delete, so
    /// the honest analogue is to refuse and let the caller decide. A file arriving with
    /// 66-deep nesting was written by something that is not Excel.
    ///
    /// Counted in **function calls**. Operators are not calls and Excel does not count them:
    /// `A1+A2+…` a few hundred terms long is one expression, bounded by the 8,192-character
    /// formula length rather than by this.
    public static let maxCallDepth = 65

    /// How deep a `LAMBDA` may recurse: **4,096 invocations**.
    ///
    /// `f(f, 4094)` answers 4094 and `f(f, 4095)` is `#NUM!`, so the limit is 4,096 counting
    /// the base case. That it is a power of two reads like a fixed frame table rather than a
    /// heuristic, which makes it the kind of number that stays put across versions.
    ///
    /// **A separate budget from ``maxCallDepth``**, established by running a 4,090-deep
    /// recursion inside 0, 2, 4, 8, 32 and 60 nested `IF`s: every one answered 4090, and
    /// 4,090 + 60 is well past 4,095, so a shared counter had to refuse and did not.
    ///
    /// The refusal is **not catchable**. `IFERROR` sits on the same stack that ran out, so it
    /// never gets the chance to handle anything — and an evaluator that produced `#NUM!`
    /// through its own error-handling path would be *more forgiving than Excel*.
    public static let maxRecursionDepth = 4096

    /// How deep the tree itself may go before this evaluator stops descending.
    ///
    /// **This one is ours, not Excel's**, and it is here for the stack rather than for
    /// fidelity. Excel caps formula *text* at 8,192 characters and every nesting level costs
    /// at least one character, so no formula Excel can hold reaches this depth; what it rules
    /// out is a hand-built AST exhausting the stack.
    ///
    /// It replaces a `maxDepth = 256` that was incremented once per AST node and presented as
    /// though it were a rule about spreadsheets. It was not, and at 256 it refused ordinary
    /// things — a 300-term sum is nothing unusual in a real sheet and Excel computes it
    /// without complaint.
    ///
    /// **The number is measured, not reasoned to.** The first attempt was 8,192, on the
    /// argument that Excel caps formula text at 8,192 characters so nothing legal can be
    /// deeper. That is true about Excel and irrelevant here: the binding constraint is this
    /// evaluator's own recursion, not the format. `evaluateNode` takes nine arguments and
    /// 8,192 frames of it is `SIGSEGV` — reached before the guard that was supposed to
    /// prevent it. **A bound whose enforcement crashes is not a bound.**
    ///
    /// So it was measured by bisection, evaluating a stack of `negate` nodes at increasing
    /// depths until the process died: a debug build under XCTest survives ~1,100 frames and
    /// dies by 1,200. Release frames are smaller and would go further; the bound has to hold
    /// in the worse case. 512 leaves better than 2× margin under the measured ceiling, and is
    /// still 8× Excel's own call limit — a 300-term sum, which is an ordinary thing to find,
    /// sits comfortably inside it.
    ///
    /// Raising it is not a matter of choosing a larger number. It needs an explicit stack or
    /// a trampoline in `evaluateNode`, and until then this is the honest ceiling.
    public static let maxNodeDepth = 512

    /// The three budgets, threaded as one value.
    ///
    /// One parameter rather than three, because `evaluateNode` already passes nine and the
    /// count is the problem the `LAMBDA` work will fix properly with an evaluation
    /// environment. Until then this at least keeps the counters from being conflated, which
    /// is the mistake that made a single `depth` wrong.
    struct Depth {
        /// Tree levels descended, against ``FormulaEvaluator/maxNodeDepth``.
        var nodes = 0
        /// Function calls entered, against ``FormulaEvaluator/maxCallDepth``.
        var calls = 0

        // The third counter, for `LAMBDA` recursion against
        // ``FormulaEvaluator/maxRecursionDepth``, belongs here and is not here yet: nothing
        // would increment it, and a field no code touches is a claim the compiler cannot
        // check. It arrives with `LAMBDA`. The bound itself is stated now because it is
        // measured now.

        /// One level further into the tree, which is not a call.
        var descended: Depth {
            var next = self
            next.nodes += 1
            return next
        }

        /// One level further into the tree *and* one call deeper.
        ///
        /// - Throws: ``EvaluationError/callDepthExceeded`` past Excel's measured 65.
        func calling() throws -> Depth {
            var next = descended
            next.calls += 1
            guard next.calls <= FormulaEvaluator.maxCallDepth else {
                throw EvaluationError.callDepthExceeded
            }
            return next
        }
    }

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
        /// The expression nested past ``FormulaEvaluator/maxCallDepth``, which Excel refuses
        /// at file load by deleting the cell. Reaching this means the file was not written
        /// by Excel.
        case callDepthExceeded
        /// The tree went deeper than ``FormulaEvaluator/maxNodeDepth``. A stack guard rather
        /// than a rule about spreadsheets — no formula Excel can hold reaches it.
        case nodeDepthExceeded
    }

    /// Evaluates one formula and distributes its result across a span.
    ///
    /// An array formula is entered over a range, evaluates **once**, and its result
    /// fills the whole rectangle. That is the piece ``evaluate(_:cells:names:functions:at:inSheet:random:simulation:)``
    /// leaves undone: it answers with a value, which for an array formula is a
    /// whole `CellMatrix`, and something still has to say which
    /// cell gets which element.
    ///
    /// The result is an *assignment* rather than a mutation. This package has no
    /// workbook to write into and takes no dependency on one, so it returns the
    /// mapping and lets the caller apply it — `Worksheet.spill(_:over:)` in
    /// SwiftXLSX does exactly that. Neither package needs to know about the other.
    ///
    /// Shapes are reconciled by `CellMatrix.spilled(toRows:columns:)`: a vector
    /// broadcasts, cells the result cannot reach become `#N/A`, and anything past
    /// the span is dropped. A scalar result fills every cell, which is why a lone
    /// value entered as an array formula appears everywhere at once.
    ///
    /// - Parameters:
    ///   - ast: The formula to evaluate.
    ///   - range: The span it fills. The result is placed from this range's origin.
    ///   - cells: The cell values available to the formula.
    ///   - names: The named ranges available to the formula.
    ///   - functions: The function registry to dispatch through.
    ///   - callingCell: The cell the formula belongs to, for functions that ask.
    ///   - currentSheet: The sheet unqualified references resolve against.
    ///   - random: The source for `RAND` and `RANDBETWEEN`, if the formula needs one.
    ///   - simulation: A completed run for the `Psi*` statistics, if there is one.
    /// - Returns: One entry per cell of `range`.
    /// - Throws: Whatever evaluating the formula throws.
    public static func spill(
        _ ast: FormulaAST,
        over range: CellRange,
        cells: CellValueProvider,
        names: NameResolver,
        functions: FunctionRegistry = .builtin,
        at callingCell: CellAddress? = nil,
        inSheet currentSheet: String = "",
        random: (any RandomSource)? = nil,
        simulation: (any SimulationResultProvider)? = nil
    ) throws -> [CellRef: CellValue] {
        let result = try evaluate(
            ast, cells: cells, names: names, functions: functions,
            at: callingCell, inSheet: currentSheet, random: random, simulation: simulation)

        // A scalar result is a 1×1 rectangle, so broadcasting handles it without a
        // special case — including an error, which Excel shows in every cell of a
        // failed array formula rather than only the first.
        let matrix: CellMatrix
        if case .array(let evaluated) = result {
            matrix = evaluated
        } else {
            matrix = CellMatrix(single: result)
        }

        let filled = matrix.spilled(toRows: range.rowCount, columns: range.columnCount)
        var assignment: [CellRef: CellValue] = [:]
        assignment.reserveCapacity(filled.count)
        for row in 0..<filled.rows {
            for column in 0..<filled.columns {
                assignment[CellRef(column: range.start.column + column,
                                   row: range.start.row + row)] = filled[row, column]
            }
        }
        return assignment
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
    ///   - simulation: A completed run for the `Psi*` statistics to read. `nil` — the
    ///     default — means every statistic answers `#N/A`, which is what Risk Solver
    ///     shows before a simulation has been run. See ``SimulationResultProvider``.
    /// - Returns: The resulting `CellValue`.
    /// - Throws: ``EvaluationError`` if evaluation fails.
    public static func evaluate(
        _ ast: FormulaAST,
        cells: CellValueProvider,
        names: NameResolver,
        functions: FunctionRegistry = .builtin,
        at callingCell: CellAddress? = nil,
        inSheet currentSheet: String = "",
        random: (any RandomSource)? = nil,
        simulation: (any SimulationResultProvider)? = nil
    ) throws -> CellValue {
        try evaluateNode(ast, in: EvaluationEnvironment(
            cells: cells, names: names, functions: functions, callingCell: callingCell,
            currentSheet: currentSheet, random: random, simulation: simulation))
    }

    // MARK: - Private Recursive Evaluator

    private static func evaluateNode(
        _ ast: FormulaAST,
        in env: EvaluationEnvironment
    ) throws -> CellValue {
        guard env.depth.nodes < maxNodeDepth else {
            throw EvaluationError.nodeDepthExceeded
        }

        // Unpacked once, here, rather than threaded through thirty recursive calls. The
        // environment exists to stop the *threading*; naming its parts locally is what makes
        // the body below read the same as it always has.
        let cells = env.cells, names = env.names, functions = env.functions
        let callingCell = env.callingCell, currentSheet = env.currentSheet
        let random = env.random, simulation = env.simulation
        let depth = env.depth

        let nextDepth = env.descended

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
            // **The sheet is passed, because a name means different things on different
            // sheets.** Excel scopes a defined name either to the workbook or to one sheet,
            // and a workbook may hold all three: `MarketGrapeCost` scoped to two sheets and
            // again to the workbook, each pointing somewhere else.
            //
            // Resolving with `nil` here asked for the workbook-scoped one every time, so a
            // formula on a sheet with its own definition silently read another sheet's
            // number — 31 cells in one workbook, answering 0.3 where Excel answers 0.812.
            // The resolver was always right; it was never told where the question came from.
            guard let target = names.resolve(name, inSheet: currentSheet.isEmpty ? nil : currentSheet)
            else {
                return .error(.name)
            }
            return try evaluateNamedTarget(
                target, in: nextDepth
            )

        // MARK: Arithmetic
        case .add(let lhs, let rhs):
            let left = try evaluateNode(lhs, in: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, in: nextDepth)
            if case .error = right { return right }
            return correctedIfFinal(
                try ArrayBroadcast.combine(left, right) { try addValues($0, $1) },
                left: left, right: right, depth: depth)

        case .subtract(let lhs, let rhs):
            let left = try evaluateNode(lhs, in: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, in: nextDepth)
            if case .error = right { return right }
            return correctedIfFinal(
                try ArrayBroadcast.combine(left, right) { try subtractValues($0, $1) },
                left: left, right: right, depth: depth)

        case .multiply(let lhs, let rhs):
            let left = try evaluateNode(lhs, in: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, in: nextDepth)
            if case .error = right { return right }
            return try ArrayBroadcast.combine(left, right) { try multiplyValues($0, $1) }

        case .divide(let lhs, let rhs):
            let left = try evaluateNode(lhs, in: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, in: nextDepth)
            if case .error = right { return right }
            return try ArrayBroadcast.combine(left, right) { try divideValues($0, $1) }

        case .power(let lhs, let rhs):
            let left = try evaluateNode(lhs, in: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, in: nextDepth)
            if case .error = right { return right }
            return try ArrayBroadcast.combine(left, right) { try powerValues($0, $1) }

        case .negate(let expr):
            let value = try evaluateNode(expr, in: nextDepth)
            if case .error = value { return value }
            // A rectangle negates element by element, which is what makes the `--(…)`
            // idiom work: `--(range=x)` is a column of ones and zeros, and it is the
            // commonest way a spreadsheet writes a conditional count.
            return try ArrayBroadcast.mapped(value) { try negateValue($0) }

        case .concatenate(let lhs, let rhs):
            let left = try evaluateNode(lhs, in: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, in: nextDepth)
            if case .error = right { return right }
            return ArrayBroadcast.combine(left, right) {
                .text(coerceToString($0) + coerceToString($1))
            }

        // MARK: Comparison
        case .equal(let lhs, let rhs):
            let left = try evaluateNode(lhs, in: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, in: nextDepth)
            if case .error = right { return right }
            return ArrayBroadcast.combine(left, right) {
                .bool(compareValues($0, $1) == .orderedSame)
            }

        case .notEqual(let lhs, let rhs):
            let left = try evaluateNode(lhs, in: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, in: nextDepth)
            if case .error = right { return right }
            return ArrayBroadcast.combine(left, right) {
                .bool(compareValues($0, $1) != .orderedSame)
            }

        case .greaterThan(let lhs, let rhs):
            let left = try evaluateNode(lhs, in: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, in: nextDepth)
            if case .error = right { return right }
            return ArrayBroadcast.combine(left, right) {
                .bool(compareValues($0, $1) == .orderedDescending)
            }

        case .lessThan(let lhs, let rhs):
            let left = try evaluateNode(lhs, in: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, in: nextDepth)
            if case .error = right { return right }
            return ArrayBroadcast.combine(left, right) {
                .bool(compareValues($0, $1) == .orderedAscending)
            }

        case .greaterOrEqual(let lhs, let rhs):
            let left = try evaluateNode(lhs, in: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, in: nextDepth)
            if case .error = right { return right }
            return ArrayBroadcast.combine(left, right) {
                let order = compareValues($0, $1)
                return .bool(order == .orderedDescending || order == .orderedSame)
            }

        case .lessOrEqual(let lhs, let rhs):
            let left = try evaluateNode(lhs, in: nextDepth)
            if case .error = left { return left }
            let right = try evaluateNode(rhs, in: nextDepth)
            if case .error = right { return right }
            return ArrayBroadcast.combine(left, right) {
                let order = compareValues($0, $1)
                return .bool(order == .orderedAscending || order == .orderedSame)
            }

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
            // This is a call, and Excel counts calls. The arguments descend one level of
            // tree *and* one level of nesting; a sibling argument is not deeper than its
            // neighbour, so `SUM(1, 2, …, 200)` is one level however wide it gets.
            let inCall = try env.calling()

            // A branching call chooses among its arguments instead of consuming them, so it
            // has to be reached before any of them are evaluated. See `LazyBranch`, and note
            // that the arity check above has already run — a malformed `IF` is still an
            // argument-count error rather than an index out of range.
            if let branched = try LazyBranch.evaluate(
                fn.name, arguments: args, evaluating: { try evaluateNode($0, in: inCall) }) {
                return branched
            }

            var evaluatedArgs: [CellValue] = []
            evaluatedArgs.reserveCapacity(args.count)
            for arg in args {
                let val = try evaluateNode(
                    arg, in: inCall
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
                    random: random, simulation: simulation)
                return try inContext(context, evaluatedArgs)
            }
            return try fn.evaluate(evaluatedArgs)
        }
    }

    // MARK: - Named Range Resolution

    private static func evaluateNamedTarget(
        _ target: NamedRangeTarget,
        in env: EvaluationEnvironment
    ) throws -> CellValue {
        // Only `cells` — a name resolves to a place, and reading the place is all this does.
        // The rest of the environment travels on to `evaluateNode` for the one case that
        // needs it, which is the point of passing an environment rather than a parameter list.
        let cells = env.cells

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
                ast, in: env)

        case .unparsed:
            // **`#NAME?`, and it is the honest answer.** The name exists in the file and this
            // package does not know what it points at, which is exactly what `#NAME?` says.
            //
            // The alternative was worse and was what this replaced: the reader used to hand
            // back `.formula(.text(raw))`, so a name it had failed to read *evaluated to its
            // own text*. `SUMIFS(amounts, …)` summed a caption and answered zero — across
            // 1,058 cells in one corpus workbook — with no error anywhere to say why.
            //
            // A refusal is visible. A plausible zero is not.
            return .error(.name)
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
            // **Fifteen significant digits, which is what Excel writes.** `"x" & 1052.95`
            // is "x1052.95" in Excel and was "x1052.949999999999" here, because a `Double`
            // carries seventeen digits and Excel shows fifteen.
            //
            // This is Excel *displaying* a number, not Excel *storing* one — ADR-003
            // declines to reproduce the storage limit, which makes arithmetic less
            // accurate, and this is the opposite: text that does not match Excel's is a
            // difference a caller sees directly, in a label they read.
            return fifteenSignificantDigits(n)
        case .bool(let b):
            return b ? "TRUE" : "FALSE"
        case .blank:
            return ""
        case .error(let e):
            return e.rawValue
        case .date(let date):
            // A date *is* a number in Excel — the serial — and `&` sees the number. An ISO
            // string here made `">=" & I4` a criterion no date could match, so
            // `SUMIFS(amounts, dates, ">="&I$4, …)` summed nothing while looking right.
            return coerceToString(.number(BuiltinDateTimeFunctions.dateToSerial(date)))
        case .formula(_, let cached):
            return coerceToString(cached ?? .blank)
        case .array:
            return ""
        }
    }

    /// A number written as Excel writes it: fifteen significant digits.
    ///
    /// `FloatingPointFormatStyle` rather than `String(format:)`, which the safety auditor
    /// rejects — a C format string carries its own type expectations and nothing checks
    /// them. The locale is fixed to POSIX for the same reason the complex functions fix
    /// theirs: this is a number to be parsed by whatever reads the cell, and a decimal comma
    /// would make it unparseable in about half the world.
    ///
    /// - Parameter value: The number.
    /// - Returns: Its text.
    private static func fifteenSignificantDigits(_ value: Double) -> String {
        guard value.isFinite else { return String(value) }
        return value.formatted(
            .number.precision(.significantDigits(1...15))
                .grouping(.never)
                .locale(Locale(identifier: "en_US_POSIX")))
    }

    // MARK: - Arithmetic Operations

    private static func addValues(_ left: CellValue, _ right: CellValue) throws -> CellValue {
        do {
            let l = try coerceToNumber(left)
            let r = try coerceToNumber(right)
            return overflowChecked(l + r)
        } catch {
            return .error(.value)
        }
    }

    private static func subtractValues(_ left: CellValue, _ right: CellValue) throws -> CellValue {
        do {
            let l = try coerceToNumber(left)
            let r = try coerceToNumber(right)
            return overflowChecked(l - r)
        } catch {
            return .error(.value)
        }
    }

    private static func multiplyValues(_ left: CellValue, _ right: CellValue) throws -> CellValue {
        do {
            let l = try coerceToNumber(left)
            let r = try coerceToNumber(right)
            return overflowChecked(l * r)
        } catch {
            return .error(.value)
        }
    }

    private static func divideValues(_ left: CellValue, _ right: CellValue) throws -> CellValue {
        do {
            let l = try coerceToNumber(left)
            let r = try coerceToNumber(right)
            guard r != 0 else { return .error(.div0) }
            return overflowChecked(l / r)
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

    /// An arithmetic result, or `#NUM!` where it left the reals.
    ///
    /// **Excel answers `#NUM!` for an overflow, not infinity.** `B11*EXP(B12*B13)` in a
    /// corpus workbook caches `#NUM!` where this answered `inf`, and a spreadsheet has no
    /// way to show an infinity — every function downstream would have had to invent an
    /// answer for it.
    ///
    /// - Parameter value: What the arithmetic produced.
    /// - Returns: The value, or the error Excel gives.
    private static func overflowChecked(_ value: Double) -> CellValue {
        value.isFinite ? .number(value) : .error(.num)
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
    /// Applies Excel's final-operation correction, but only at the root of the formula.
    ///
    /// **Depth is the whole of it.** Excel corrects the last operation and no earlier one:
    /// `(0.1+0.2-0.3)*1` keeps the residue that `0.1+0.2-0.3` discards, so correcting every
    /// addition as it happens would be measurably wrong. Depth zero is the node whose value
    /// becomes the cell's, which is the one Excel corrects.
    ///
    /// - Parameters:
    ///   - result: What the operation produced.
    ///   - left: Its left operand, for the scale to judge against.
    ///   - right: Its right operand.
    ///   - depth: How deep the operation sits; zero is the root.
    /// - Returns: The corrected value at the root, the original anywhere else.
    private static func correctedIfFinal(_ result: CellValue, left: CellValue,
                                         right: CellValue, depth: Depth) -> CellValue {
        // `nodes == 0` is what "this is the outermost operation" means: the final operation
        // is the one nothing encloses, and Excel's display rounding applies to it alone.
        guard depth.nodes == 0,
              case .number(let value) = result,
              case .number(let lhs) = normalizeForComparison(left, against: right),
              case .number(let rhs) = normalizeForComparison(right, against: left) else {
            return result
        }
        return .number(ExcelFinalRounding.corrected(value, lhs: lhs, rhs: rhs))
    }

    private static func compareValues(_ left: CellValue, _ right: CellValue) -> ComparisonResult {
        let lNorm = normalizeForComparison(left, against: right)
        let rNorm = normalizeForComparison(right, against: left)

        switch (lNorm, rNorm) {
        case (.number(let a), .number(let b)):
            // Excel compares by subtracting, and corrects that subtraction the way it
            // corrects any other — so two numbers whose difference is negligible against
            // them are equal. This is the whole of why `0.1+0.2=0.3` is TRUE in Excel while
            // `(0.1+0.2-0.3)=0` is FALSE: in the second, the difference *is* the operand.
            let difference = ExcelFinalRounding.corrected(a - b, lhs: a, rhs: b)
            if difference < 0 { return .orderedAscending }
            if difference > 0 { return .orderedDescending }
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
    /// A value as the comparison should see it.
    ///
    /// **An empty cell is both `0` and `""`**, and which one depends on what it is being
    /// compared against. Excel answers TRUE to `A1=0` and to `A1=""` for the same empty
    /// `A1`, which no single normalisation can do: mapping blank to `0` made `A1=""` a
    /// number against a text and therefore FALSE.
    ///
    /// `IF(AND(E20="",G20="No"),1,2)` is how a spreadsheet asks "has this been filled in
    /// yet", and it answered 2 where Excel cached 1 — found by the workbook checker in a
    /// real file.
    ///
    /// - Parameters:
    ///   - value: The operand to normalise.
    ///   - other: What it is being compared against, which decides how a blank reads.
    /// - Returns: The value to compare.
    private static func normalizeForComparison(
        _ value: CellValue, against other: CellValue
    ) -> CellValue {
        switch value {
        case .blank:
            if case .text = resolvedForComparison(other) { return .text("") }
            return .number(0)
        case .formula(_, let cached):
            return normalizeForComparison(cached ?? .blank, against: other)
        default:
            return value
        }
    }

    /// The other operand, far enough resolved to say what type it is.
    private static func resolvedForComparison(_ value: CellValue) -> CellValue {
        if case .formula(_, let cached) = value { return resolvedForComparison(cached ?? .blank) }
        return value
    }
}
