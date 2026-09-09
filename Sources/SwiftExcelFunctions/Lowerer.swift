import Foundation
import SwiftExcelCore
import BusinessMath

/// Why a formula cannot be compiled to bytecode.
///
/// **A refusal is not a failure.** The interpreted path runs every one of these correctly;
/// a refusal only means this output does not get the fast path. `PROPOSAL_model_graph_simulation.md`
/// §3.1 — lowering is an optimization, not a requirement.
///
/// Every case names a cell, because a caller who cannot compile a model wants to know
/// which formula to look at, not that "something" was unrepresentable.
public enum LoweringFailure: Error, Sendable, Equatable {

    /// A function with no opcode in the target instruction set.
    case unrepresentableFunction(name: String, at: CellRef)

    /// A text literal or concatenation on the trial path.
    ///
    /// `Expression` is `Double` in, `Double` out. There is no NaN that means "a string",
    /// and inventing one would put a number into a mean that no reader could question.
    case textValued(at: CellRef)

    /// A literal Excel error on the trial path — `#N/A` written into a formula.
    case errorValued(ExcelError, at: CellRef)

    /// A function that computes its own *address*: `OFFSET`, `INDIRECT`.
    ///
    /// These can never lower. The shape of the expression would vary per trial, and
    /// bytecode is compiled once.
    case computedAddress(function: String, at: CellRef)

    /// A node kind with no representation — a named range, a sheet-qualified reference.
    case unsupportedNode(String, at: CellRef)

    /// A reference to a cell the provider does not hold.
    case unresolvedReference(CellRef, at: CellRef)

    /// The tree grew past the limit while inlining. See ``Lowerer/Limits``.
    case instructionLimitExceeded(count: Int, limit: Int)
}

/// One output's model, compiled.
public struct LoweredModel: Sendable {

    /// The cell this computes.
    public let output: CellRef

    /// The compiled model. `evaluate(inputs:)` takes one `Double` per uncertain cell, in
    /// the survey's input-index order.
    public let model: MonteCarloExpressionModel

    /// How many uniforms one trial consumes.
    public let inputCount: Int

    /// Bytecode instructions after optimisation — the number to watch for §5.3's blow-up.
    public let instructionCount: Int

    /// Creates a lowered model.
    ///
    /// - Parameters:
    ///   - output: the cell it computes.
    ///   - model: the compiled expression model.
    ///   - inputCount: uniforms consumed per trial.
    ///   - instructionCount: instructions after optimisation.
    public init(
        output: CellRef, model: MonteCarloExpressionModel,
        inputCount: Int, instructionCount: Int
    ) {
        self.output = output
        self.model = model
        self.inputCount = inputCount
        self.instructionCount = instructionCount
    }
}

/// Compiles a model's propagation into BusinessMath bytecode.
///
/// ## What is lowered, and what is not
///
/// **The distributions are never lowered.** `PsiNormal` and friends are quantile functions
/// of a uniform, and no opcode expresses an inverse CDF. Each uncertain cell becomes one
/// `.input(i)` that the sampler fills from outside — §5.4. What compiles is the
/// *propagation*: the arithmetic the workbook performs on those draws, which is where the
/// measured 118× lives.
///
/// ## Inlining
///
/// `Expression` is one scalar tree; a workbook is a graph. Lowering inlines each referenced
/// formula cell's subtree into its referent, so a cell read *k* times is inlined *k* times.
/// `BytecodeOptimizer` does constant folding and algebraic simplification but **not** common
/// subexpression elimination, so deep fan-out can grow the tree quickly. ``Limits`` bounds
/// it rather than discovering it at runtime.
public struct Lowerer: Sendable {

    /// Bounds on what will be attempted.
    public struct Limits: Sendable {
        /// Refuse past this many instructions rather than compile something pathological.
        public var maxInstructions: Int

        /// Creates limits.
        /// - Parameter maxInstructions: the instruction ceiling.
        public init(maxInstructions: Int = 1_000_000) {
            self.maxInstructions = maxInstructions
        }
    }

    private let limits: Limits

    /// - Parameter limits: bounds on the compiled tree.
    public init(limits: Limits = Limits()) { self.limits = limits }

    /// Functions whose *address* is computed, and so can never lower.
    private static let addressComputing: Set<String> = ["OFFSET", "INDIRECT"]

    // MARK: - Audit

    /// What would stop this output compiling, without compiling it.
    ///
    /// A pure function of the model, which is what makes a corpus-wide survey cheap: run
    /// this across every output of every workbook and the histogram of failures *is* the
    /// work list, ordered by how often each rule would pay.
    ///
    /// Empty is the precondition for ``lower(output:survey:cells:)`` succeeding.
    ///
    /// - Parameters:
    ///   - output: the cell to compile.
    ///   - survey: the recognised model, for its input indices.
    ///   - cells: the model's cells.
    /// - Returns: every reason it would refuse, in traversal order.
    public func audit(
        output: CellRef, survey: ModelSurvey, cells: any CellValueProvider
    ) -> [LoweringFailure] {
        var failures: [LoweringFailure] = []
        var visiting: Set<CellRef> = []
        var audited: Set<CellRef> = []
        audit(cell: output, survey: survey, cells: cells,
              failures: &failures, visiting: &visiting, audited: &audited)
        return failures
    }

    private func audit(
        cell: CellRef, survey: ModelSurvey, cells: any CellValueProvider,
        failures: inout [LoweringFailure], visiting: inout Set<CellRef>,
        audited: inout Set<CellRef>
    ) {
        let key = cell.positionKey
        // Audited once, however many times it is referenced. Without this a diamond
        // dependency reports the same formula's failure once per path — measured at 5,400
        // findings for a handful of cells, which makes the histogram that orders the work
        // read as noise rather than a work list.
        guard !audited.contains(key) else { return }
        audited.insert(key)
        // A cycle is the interpreted path's problem to report, not this one's; stopping
        // here keeps the audit total rather than hanging on a model that will be refused
        // for a better reason anyway.
        guard !visiting.contains(key) else { return }
        guard let ast = cells.value(at: cell)?.formulaAST else { return }

        visiting.insert(key)
        defer { visiting.remove(key) }
        audit(ast, in: cell, survey: survey, cells: cells,
              failures: &failures, visiting: &visiting, audited: &audited)
    }

    private func audit(
        _ ast: FormulaAST, in cell: CellRef, survey: ModelSurvey,
        cells: any CellValueProvider,
        failures: inout [LoweringFailure], visiting: inout Set<CellRef>,
        audited: inout Set<CellRef>
    ) {
        // What this node itself rules out. Recursion is `FormulaAST.children`, so the node
        // list lives in one place and adding a kind cannot silently skip this pass.
        switch ast {
        case .text, .concatenate:
            failures.append(.textValued(at: cell)); return
        case .error(let e):
            failures.append(.errorValued(e, at: cell)); return
        case .sheetRef:
            failures.append(.unsupportedNode("sheet reference", at: cell)); return
        case .namedRange(let name):
            failures.append(.unsupportedNode("named range \(name)", at: cell)); return

        case .cellRef(let ref):
            // An uncertain cell is an input and stops the walk; anything else is inlined,
            // so its own formula has to lower too.
            guard !isUncertain(ref, in: survey) else { return }
            if cells.value(at: ref)?.formulaAST != nil {
                audit(cell: ref, survey: survey, cells: cells,
                      failures: &failures, visiting: &visiting, audited: &audited)
            } else if cells.value(at: ref) == nil {
                failures.append(.unresolvedReference(ref, at: cell))
            }
            return

        case .cellRange(let range):
            for member in range.clipped(to: cells.lastPopulatedCell())?.cells ?? [] {
                guard !isUncertain(member, in: survey),
                      cells.value(at: member)?.formulaAST != nil else { continue }
                audit(cell: member, survey: survey, cells: cells,
                      failures: &failures, visiting: &visiting, audited: &audited)
            }
            return

        case .function(let rawName, _):
            let name = FunctionRegistry.canonical(rawName)
            if Self.addressComputing.contains(name) {
                failures.append(.computedAddress(function: name, at: cell)); return
            }
            // A distribution or a statistic here needs nothing audited — the sampler
            // supplies one and a completed run supplies the other.
            if name == "PSIOUTPUT" || PsiRecognizer.statistics.contains(name) { return }
            if !Self.representable.contains(name) {
                failures.append(.unrepresentableFunction(name: name, at: cell)); return
            }

        case .number, .bool, .missing:
            return

        // Structural: nothing about the node itself refuses, and the recursion below
        // reaches its operands. Listed rather than defaulted so that a node kind added to
        // `FormulaAST` fails to compile here and gets a decision, instead of being walked
        // into silently by a pass whose job is to refuse what it cannot represent.
        case .add, .subtract, .multiply, .divide, .power,
             .equal, .notEqual, .greaterThan, .lessThan, .greaterOrEqual, .lessOrEqual,
             .negate:
            break
        }

        for child in ast.children {
            audit(child, in: cell, survey: survey, cells: cells,
                  failures: &failures, visiting: &visiting, audited: &audited)
        }
    }

    /// Functions with an opcode or a fold. The set this pass supports, and the thing that
    /// grows as the corpus histogram says which rule pays next.
    static let representable: Set<String> = [
        "SUM", "SUMPRODUCT", "PRODUCT", "AVERAGE", "MIN", "MAX",
        "ABS", "SQRT", "LN", "EXP", "IF", "NPV", "AND", "OR", "NOT"
    ]

    private func isUncertain(_ ref: CellRef, in survey: ModelSurvey) -> Bool {
        survey.uncertain.contains { $0.address.positionKey == ref.positionKey }
    }
}

// MARK: - Lowering

extension Lowerer {

    /// A lowered subtree: either a value known at compile time, or an expression.
    ///
    /// The split is what removes the need for a constant leaf. `ExpressionBuilder` has no
    /// public way to make a bare `.constant` — every constant reaches the tree as the
    /// operand of an operator that has a `Double` overload. Carrying constants as `Double`
    /// until they meet an expression matches that exactly, and folds constant arithmetic
    /// at lowering time for free: `2*3` never becomes bytecode at all.
    enum Node {
        case value(Double)
        case expression(ExpressionProxy)

        /// The expression form, given a builder to make a constant with if needed.
        ///
        /// Only reached when a constant must become an expression — an output that is
        /// entirely constant. `b.array([v]).sum()` is the one public route to a constant
        /// leaf, and the optimiser folds the fold away.
        func proxy(_ b: ExpressionBuilder) -> ExpressionProxy {
            switch self {
            case .expression(let e): return e
            case .value(let v): return b.array([v]).sum()
            }
        }
    }

    /// Compiles one output.
    ///
    /// - Parameters:
    ///   - output: the cell to compile.
    ///   - survey: the recognised model, whose input indices this honours exactly.
    ///   - cells: the model's cells.
    /// - Returns: the compiled model.
    /// - Throws: the first ``LoweringFailure`` — call ``audit(output:survey:cells:)`` for all of them.
    public func lower(
        output: CellRef, survey: ModelSurvey, cells: any CellValueProvider
    ) throws -> LoweredModel {
        if let first = audit(output: output, survey: survey, cells: cells).first { throw first }

        // The builder closure cannot throw, so a failure it discovers is carried out.
        // `audit` has already proved there is none; this catches the case where the two
        // disagree, which is a defect in this file rather than in the model.
        var escaped: LoweringFailure?

        let model = try MonteCarloExpressionModel { builder in
            guard let node = self.build(
                cell: output, survey: survey, cells: cells,
                builder: builder, failure: &escaped, depth: 0)
            else { return builder[0] }
            return node.proxy(builder)
        }

        if let escaped { throw escaped }

        let count = model.instructionCount()
        guard count <= limits.maxInstructions else {
            throw LoweringFailure.instructionLimitExceeded(count: count, limit: limits.maxInstructions)
        }

        return LoweredModel(
            output: output, model: model,
            inputCount: survey.uncertain.count, instructionCount: count)
    }

    // MARK: - The rules

    private func build(
        cell: CellRef, survey: ModelSurvey, cells: any CellValueProvider,
        builder: ExpressionBuilder, failure: inout LoweringFailure?, depth: Int
    ) -> Node? {
        guard let ast = cells.value(at: cell)?.formulaAST else {
            if case .number(let v)? = cells.value(at: cell) { return .value(v) }
            return .value(0)   // a blank cell reads as zero, as it does in the evaluator
        }
        return build(ast, in: cell, survey: survey, cells: cells,
                     builder: builder, failure: &failure, depth: depth)
    }

    private func build(
        _ ast: FormulaAST, in cell: CellRef, survey: ModelSurvey,
        cells: any CellValueProvider, builder: ExpressionBuilder,
        failure: inout LoweringFailure?, depth: Int
    ) -> Node? {
        guard depth < FormulaEvaluator.maxDepth else {
            failure = .unsupportedNode("nesting past the evaluator's depth", at: cell)
            return nil
        }
        let next = depth + 1

        func sub(_ node: FormulaAST) -> Node? {
            build(node, in: cell, survey: survey, cells: cells,
                  builder: builder, failure: &failure, depth: next)
        }

        // Twelve binary operators, one path. `FormulaAST` gives each its own case, which
        // is right for exact matching and wrong here: they differ only in the function
        // applied to the operands, and writing them out was forty lines that had to be
        // read to discover they were all the same.
        if let (kind, lhs, rhs) = ast.binary {
            guard let a = sub(lhs), let b = sub(rhs) else { return nil }
            return apply(kind, a, b, in: cell, builder: builder, failure: &failure)
        }

        switch ast {
        case .number(let v): return .value(v)
        case .bool(let b): return .value(b ? 1 : 0)
        case .missing: return .value(0)

        case .cellRef(let ref):
            // An uncertain cell is an input: the sampler fills it, the bytecode reads it.
            if let index = survey.uncertain.first(
                where: { $0.address.positionKey == ref.positionKey })?.inputIndex {
                return .expression(builder[index])
            }
            return build(cell: ref, survey: survey, cells: cells,
                         builder: builder, failure: &failure, depth: next)

        case .negate(let operand):
            guard let a = sub(operand) else { return nil }
            if case .value(let v) = a { return .value(-v) }
            return .expression(-a.proxy(builder))

        case .cellRange:
            // A range is not a value; only an aggregate consumes one, and an aggregate
            // flattens its arguments before reaching here.
            failure = .unsupportedNode("a range outside an aggregate", at: cell)
            return nil

        case .function(let rawName, let arguments):
            return buildFunction(
                FunctionRegistry.canonical(rawName), arguments, in: cell, survey: survey,
                cells: cells, builder: builder, failure: &failure, depth: next)

        case .text, .concatenate:
            failure = .textValued(at: cell); return nil
        case .error(let e):
            failure = .errorValued(e, at: cell); return nil
        case .sheetRef:
            failure = .unsupportedNode("sheet reference", at: cell); return nil
        case .namedRange(let name):
            failure = .unsupportedNode("named range \(name)", at: cell); return nil

        case .add, .subtract, .multiply, .divide, .power,
             .equal, .notEqual, .greaterThan, .lessThan, .greaterOrEqual, .lessOrEqual:
            // Taken by `ast.binary` above. Present so the switch stays exhaustive, which
            // is what makes a node kind added upstream a compile error here rather than a
            // silent `nil`. `.concatenate` is absent because `.text, .concatenate` catches
            // it first — it is a refusal, not a structural pass-through.
            return nil
        }
    }

    /// Applies one binary operator to two lowered operands.
    ///
    /// Constants fold here, so `2*3` never becomes bytecode. Comparisons return 1 or 0,
    /// which is both Excel's convention and what `Expression`'s comparison opcodes emit —
    /// the two agreeing is why `AND` can be a product.
    private func apply(
        _ kind: BinaryKind, _ a: Node, _ b: Node, in cell: CellRef,
        builder: ExpressionBuilder, failure: inout LoweringFailure?
    ) -> Node? {
        if kind == .concatenate { failure = .textValued(at: cell); return nil }

        if kind.isComparison {
            if case .value(let x) = a, case .value(let y) = b {
                return .value(Self.compareValues(kind, x, y) ? 1 : 0)
            }
            let l = a.proxy(builder), r = b.proxy(builder)
            switch kind {
            case .equal: return .expression(l.equal(r))
            case .notEqual: return .expression(l.notEqual(r))
            case .greaterThan: return .expression(l.greaterThan(r))
            case .lessThan: return .expression(l.lessThan(r))
            case .greaterOrEqual: return .expression(l.greaterOrEqual(r))
            case .lessOrEqual: return .expression(l.lessOrEqual(r))
            default: return nil
            }
        }

        switch (kind, a, b) {
        case (_, .value(let x), .value(let y)):
            return .value(Self.foldValues(kind, x, y))

        case (.power, .expression(let e), .value(let y)):
            return .expression(e.power(y))
        case (.power, _, _):
            return .expression(a.proxy(builder).power(b.proxy(builder)))

        case (.add, .expression(let e), .value(let y)): return .expression(e + y)
        case (.add, .value(let x), .expression(let e)): return .expression(x + e)
        case (.add, .expression(let e), .expression(let f)): return .expression(e + f)

        case (.subtract, .expression(let e), .value(let y)): return .expression(e - y)
        case (.subtract, .value(let x), .expression(let e)): return .expression(x - e)
        case (.subtract, .expression(let e), .expression(let f)): return .expression(e - f)

        case (.multiply, .expression(let e), .value(let y)): return .expression(e * y)
        case (.multiply, .value(let x), .expression(let e)): return .expression(x * e)
        case (.multiply, .expression(let e), .expression(let f)): return .expression(e * f)

        case (.divide, .expression(let e), .value(let y)): return .expression(e / y)
        case (.divide, .value(let x), .expression(let e)): return .expression(x / e)
        case (.divide, .expression(let e), .expression(let f)): return .expression(e / f)

        default:
            return nil
        }
    }

    /// The value-level fold for a non-comparison operator.
    private static func foldValues(_ kind: BinaryKind, _ x: Double, _ y: Double) -> Double {
        switch kind {
        case .add: return x + y
        case .subtract: return x - y
        case .multiply: return x * y
        case .divide: return x / y
        case .power: return pow(x, y)
        default: return 0
        }
    }

    /// The value-level comparison.
    private static func compareValues(_ kind: BinaryKind, _ x: Double, _ y: Double) -> Bool {
        switch kind {
        case .equal: return x == y
        case .notEqual: return x != y
        case .greaterThan: return x > y
        case .lessThan: return x < y
        case .greaterOrEqual: return x >= y
        case .lessOrEqual: return x <= y
        default: return false
        }
    }

}

// MARK: - Function rules

extension Lowerer {

    /// Lowers a function call.
    ///
    /// Aggregates fold over their arguments as ``Node``s rather than going through
    /// `ExpressionArray`, which keeps constant-only arguments constant and needs no
    /// constant leaf. `SUMPRODUCT` is the pairwise products summed, which is its
    /// definition and avoids requiring both sides to be expressions.
    private func buildFunction(
        _ name: String, _ arguments: [FormulaAST], in cell: CellRef,
        survey: ModelSurvey, cells: any CellValueProvider, builder: ExpressionBuilder,
        failure: inout LoweringFailure?, depth: Int
    ) -> Node? {

        /// Every scalar an argument stands for — a range contributes each of its cells.
        func flatten(_ argument: FormulaAST) -> [Node]? {
            if case .cellRange(let range) = argument {
                let members = range.clipped(to: cells.lastPopulatedCell())?.cells ?? []
                var out: [Node] = []
                for member in members {
                    guard let node = build(
                        .cellRef(member), in: cell, survey: survey, cells: cells,
                        builder: builder, failure: &failure, depth: depth) else { return nil }
                    out.append(node)
                }
                return out
            }
            guard let node = build(argument, in: cell, survey: survey, cells: cells,
                                   builder: builder, failure: &failure, depth: depth) else { return nil }
            return [node]
        }

        func all() -> [Node]? {
            var out: [Node] = []
            for argument in arguments {
                guard let part = flatten(argument) else { return nil }
                out.append(contentsOf: part)
            }
            return out
        }

        /// Folds a list, keeping the constant part constant for as long as possible.
        func fold(
            _ nodes: [Node], identity: Double,
            _ values: (Double, Double) -> Double,
            _ exprValue: (ExpressionProxy, Double) -> ExpressionProxy,
            _ exprExpr: (ExpressionProxy, ExpressionProxy) -> ExpressionProxy
        ) -> Node {
            var constant = identity
            var expression: ExpressionProxy?
            for node in nodes {
                switch node {
                case .value(let v): constant = values(constant, v)
                case .expression(let e): expression = expression.map { exprExpr($0, e) } ?? e
                }
            }
            guard let expression else { return .value(constant) }
            return .expression(exprValue(expression, constant))
        }

        switch name {
        case "SUM":
            guard let nodes = all() else { return nil }
            return fold(nodes, identity: 0, (+), { $0 + $1 }, { $0 + $1 })

        case "PRODUCT":
            guard let nodes = all() else { return nil }
            return fold(nodes, identity: 1, (*), { $0 * $1 }, { $0 * $1 })

        case "MIN":
            guard let nodes = all(), !nodes.isEmpty else { return .value(0) }
            return fold(nodes, identity: .infinity, Swift.min, { $0.min($1) }, { $0.min($1) })

        case "MAX":
            guard let nodes = all(), !nodes.isEmpty else { return .value(0) }
            return fold(nodes, identity: -.infinity, Swift.max, { $0.max($1) }, { $0.max($1) })

        case "AVERAGE":
            guard let nodes = all(), !nodes.isEmpty else { return .value(0) }
            let total = fold(nodes, identity: 0, (+), { $0 + $1 }, { $0 + $1 })
            let count = Double(nodes.count)
            if case .value(let v) = total { return .value(v / count) }
            return .expression(total.proxy(builder) / count)

        case "SUMPRODUCT":
            // Σ aᵢ·bᵢ, pairwise. Its definition, and it never needs both sides to be
            // expressions the way `ExpressionArray.dot(_:)` would.
            guard arguments.count >= 2 else { return .value(0) }
            var columns: [[Node]] = []
            for argument in arguments {
                guard let part = flatten(argument) else { return nil }
                columns.append(part)
            }
            guard let width = columns.map(\.count).min(), width > 0 else { return .value(0) }
            var terms: [Node] = []
            for i in 0..<width {
                var term = columns[0][i]
                for column in columns.dropFirst() {
                    guard let product = apply(
                        .multiply, term, column[i], in: cell,
                        builder: builder, failure: &failure)
                    else { return nil }
                    term = product
                }
                terms.append(term)
            }
            return fold(terms, identity: 0, (+), { $0 + $1 }, { $0 + $1 })

        case "ABS", "SQRT", "LN", "EXP":
            guard arguments.count == 1,
                  let node = build(arguments[0], in: cell, survey: survey, cells: cells,
                                   builder: builder, failure: &failure, depth: depth)
            else { return nil }
            switch (name, node) {
            case ("ABS", .value(let v)): return .value(Swift.abs(v))
            case ("SQRT", .value(let v)): return .value(v.squareRoot())
            case ("LN", .value(let v)): return .value(Foundation.log(v))
            case ("EXP", .value(let v)): return .value(Foundation.exp(v))
            case ("ABS", .expression(let e)): return .expression(e.abs())
            case ("SQRT", .expression(let e)): return .expression(e.sqrt())
            case ("LN", .expression(let e)): return .expression(e.log())
            case ("EXP", .expression(let e)): return .expression(e.exp())
            default: return nil
            }

        case "IF":
            guard arguments.count >= 2 else { return nil }
            guard let condition = build(arguments[0], in: cell, survey: survey, cells: cells,
                                        builder: builder, failure: &failure, depth: depth),
                  let whenTrue = build(arguments[1], in: cell, survey: survey, cells: cells,
                                       builder: builder, failure: &failure, depth: depth)
            else { return nil }
            let whenFalse: Node
            if arguments.count >= 3 {
                guard let f = build(arguments[2], in: cell, survey: survey, cells: cells,
                                    builder: builder, failure: &failure, depth: depth)
                else { return nil }
                whenFalse = f
            } else {
                whenFalse = .value(0)
            }

            // A condition known at compile time picks its branch and the other never
            // becomes bytecode.
            if case .value(let c) = condition { return c != 0 ? whenTrue : whenFalse }

            let test = condition.proxy(builder)
            switch (whenTrue, whenFalse) {
            case (.value(let t), .value(let f)): return .expression(test.ifElse(then: t, else: f))
            case (.expression(let t), .value(let f)): return .expression(test.ifElse(then: t, else: f))
            case (.value(let t), .expression(let f)): return .expression(test.ifElse(then: t, else: f))
            case (.expression(let t), .expression(let f)): return .expression(test.ifElse(then: t, else: f))
            }

        case "NPV":
            // Σ vᵢ / (1+r)^i, discounting from period 1 — Excel's convention, and the
            // reason `NPV(rate, cashflows)` is not the same as adding an undiscounted
            // period nought. Named by the corpus histogram: NPV alone was 10 of 13
            // refusals across the real models, which is what made it the next rule.
            guard arguments.count >= 2,
                  let rateNode = build(arguments[0], in: cell, survey: survey, cells: cells,
                                       builder: builder, failure: &failure, depth: depth)
            else { return nil }

            var flows: [Node] = []
            for argument in arguments.dropFirst() {
                guard let part = flatten(argument) else { return nil }
                flows.append(contentsOf: part)
            }
            guard !flows.isEmpty else { return .value(0) }

            var terms: [Node] = []
            for (offset, flow) in flows.enumerated() {
                let period = Double(offset + 1)
                // (1 + r)^period
                guard let onePlusRate = apply(
                        .add, .value(1), rateNode, in: cell,
                        builder: builder, failure: &failure)
                else { return nil }
                let discount: Node
                switch onePlusRate {
                case .value(let v): discount = .value(pow(v, period))
                case .expression(let e): discount = .expression(e.power(period))
                }
                guard let term = apply(
                        .divide, flow, discount, in: cell,
                        builder: builder, failure: &failure)
                else { return nil }
                terms.append(term)
            }
            return fold(terms, identity: 0, (+), { $0 + $1 }, { $0 + $1 })

        case "AND", "OR":
            // Excel's booleans are 1 and 0, and `Expression`'s comparisons already return
            // exactly that — so AND is a product and OR is "not all zero". No opcode is
            // needed beyond the arithmetic already here.
            guard let nodes = all(), !nodes.isEmpty else { return .value(name == "AND" ? 1 : 0) }
            let truths = nodes.map { node -> Node in
                if case .value(let v) = node { return .value(v != 0 ? 1 : 0) }
                return node
            }
            if name == "AND" {
                return fold(truths, identity: 1, { ($0 != 0 && $1 != 0) ? 1 : 0 },
                            { $0 * $1 }, { $0 * $1 })
            }
            // OR: sum the truths and test against zero, which avoids needing a negation
            // opcode and keeps a constant-only argument list constant.
            let anyTrue = fold(truths, identity: 0, { (($0 != 0) || ($1 != 0)) ? 1 : 0 },
                               { $0 + $1 }, { $0 + $1 })
            if case .value(let v) = anyTrue { return .value(v != 0 ? 1 : 0) }
            return .expression(anyTrue.proxy(builder).greaterThan(0.0))

        case "NOT":
            guard arguments.count == 1,
                  let node = build(arguments[0], in: cell, survey: survey, cells: cells,
                                   builder: builder, failure: &failure, depth: depth)
            else { return nil }
            if case .value(let v) = node { return .value(v != 0 ? 0 : 1) }
            return .expression(node.proxy(builder).equal(0.0))

        case "PSIOUTPUT":
            // Contributes nothing to the arithmetic; it is written onto a real formula.
            return .value(0)

        default:
            failure = .unrepresentableFunction(name: name, at: cell)
            return nil
        }
    }
}
