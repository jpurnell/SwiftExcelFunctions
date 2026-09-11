import Foundation
import SwiftExcelCore

/// A classic Excel Solver model, as declared in a workbook.
///
/// Not a solved model — a *statement* of one. What to optimise, what may move, what must
/// hold. Handing it to an optimizer is a separate step, and deliberately so: the engine a
/// workbook nominates and the engine you want to solve it with need not be the same one.
public struct SolverModel: Equatable, Sendable {

    /// What the objective is for.
    public enum Sense: Equatable, Sendable {
        case maximise
        case minimise
        /// Excel's "value of": drive the objective to a particular number.
        case target(Double)
    }

    /// How a constraint's two sides relate.
    ///
    /// The last three are not relations at all but *declarations about the variables* —
    /// Excel writes "integer", "binary" and "all different" in the same list as `<=`, so
    /// they arrive here together and a solver has to separate them again.
    public enum Relation: Equatable, Sendable {
        case lessOrEqual
        case equal
        case greaterOrEqual
        case integer
        case binary
        case allDifferent
    }

    /// What a constraint is measured against.
    public enum Bound: Equatable, Sendable {
        case constant(Double)
        case cells([CellRef])
    }

    /// One constraint.
    public struct Constraint: Equatable, Sendable {

        /// The cells being constrained, in reading order.
        ///
        /// A range rather than a cell, because Excel lets one constraint cover a block:
        /// `C1:C5 <= 10` is a single row of the dialog and five conditions.
        public let lhs: [CellRef]

        /// How the two sides relate — or, for the last three cases, what kind of value the
        /// left-hand cells must hold.
        public let relation: Relation

        /// What the left-hand side is measured against. Unused by ``Relation/integer``,
        /// ``Relation/binary`` and ``Relation/allDifferent``, which constrain the variables
        /// themselves rather than comparing them to anything.
        public let rhs: Bound

        /// Creates a constraint.
        ///
        /// - Parameters:
        ///   - lhs: The cells being constrained.
        ///   - relation: How they relate to `rhs`, or what they must be.
        ///   - rhs: What they are measured against.
        public init(lhs: [CellRef], relation: Relation, rhs: Bound) {
            self.lhs = lhs
            self.relation = relation
            self.rhs = rhs
        }
    }

    /// The engine the workbook nominates.
    public enum Engine: Equatable, Sendable {
        case grgNonlinear
        case simplexLP
        case evolutionary
    }

    /// The objective cell, or `nil` for a model that only satisfies constraints.
    public let objective: CellRef?

    /// What to do with the objective.
    public let sense: Sense

    /// The decision variables, in the order `solver_adj` lists them.
    public let variables: [CellRef]

    /// The constraints, in declaration order.
    public let constraints: [Constraint]

    /// The engine the workbook nominates. **Advisory** — see ``ExcelSolverReader``.
    public let engine: Engine

    /// Whether unconstrained variables are assumed non-negative.
    ///
    /// Excel's "Make Unconstrained Variables Non-Negative" checkbox, stored as
    /// `solver_neg`: `1` assumes it, `2` permits negatives. It defaults to `true`, which is
    /// Excel's own default, and it matters more than a checkbox sounds — a simplex solver
    /// assumes `x >= 0` structurally, so a model that permits negatives cannot be handed to
    /// one without changing the answer.
    public let assumesNonNegative: Bool

    /// Creates a model.
    ///
    /// - Parameters:
    ///   - objective: The objective cell, or `nil`.
    ///   - sense: What to do with it.
    ///   - variables: The decision variables, in order.
    ///   - constraints: The constraints, in declaration order.
    ///   - engine: The nominated engine.
    ///   - assumesNonNegative: Excel's non-negativity assumption, which defaults to `true`
    ///     because that is Excel's own default.
    public init(
        objective: CellRef?,
        sense: Sense,
        variables: [CellRef],
        constraints: [Constraint],
        engine: Engine,
        assumesNonNegative: Bool = true
    ) {
        self.objective = objective
        self.sense = sense
        self.variables = variables
        self.constraints = constraints
        self.engine = engine
        self.assumesNonNegative = assumesNonNegative
    }
}

/// Reads a classic Excel Solver model out of a workbook's defined names.
///
/// **Solver stores its model in defined names, not in cells or functions.** `solver_opt`
/// names the objective, `solver_adj` the cells that may move, and `solver_lhs1` /
/// `solver_rel1` / `solver_rhs1` the first constraint. That is why no amount of function
/// coverage ever revealed whether a workbook carried a model, and why a function-level
/// coverage matrix is structurally blind to it: there is nothing to call.
///
/// ## The engine is advisory
///
/// ``SolverModel/engine`` records what the workbook asked for and nothing more. A model
/// declared for Excel's Simplex can be handed to branch-and-cut, or to a robust optimizer,
/// because the model and the method that solves it are independent — and keeping them
/// independent here is what makes "read a plain Excel model, solve it with a better engine"
/// possible at all.
///
/// ## What is not verified
///
/// The numeric encodings — `solver_typ` 1/2/3, the relation codes, the engine codes — come
/// from Frontline's published layout and have **not been measured against a real workbook**.
/// They are gathered in `relation(for:)`, `sense(for:value:)` and `engine(for:)` — internal,
/// so plain code spans rather than symbol links — which puts every encoding in one place and
/// makes correcting one a single edit. The tests pin them, so a disagreement with a real
/// workbook fails loudly rather than misreading quietly.
public enum ExcelSolverReader {

    /// Reads the model, if the workbook declares one.
    ///
    /// - Parameter names: The workbook's defined names.
    /// - Returns: The model, or `nil` when no `solver_` names are present at all — which is
    ///   a different thing from a model whose objective is missing, and the distinction a
    ///   caller needs in order to say "this workbook has no Solver model" honestly.
    public static func model(from names: NamedRangeCollection) -> SolverModel? {
        // Case-insensitively: Excel writes `solver_opt`, but a workbook round-tripped
        // through another tool need not have preserved that.
        var byName: [String: NamedRangeTarget] = [:]
        for range in names.all where range.name.lowercased().hasPrefix("solver_") {
            byName[range.name.lowercased()] = range.reference
        }
        guard !byName.isEmpty else { return nil }

        let objective = byName["solver_opt"].flatMap(firstCell)
        let sense = sense(for: number(byName["solver_typ"]),
                          value: number(byName["solver_val"]))
        let variables = byName["solver_adj"].map(cells) ?? []

        // `solver_num` is authoritative rather than a hint. An edited workbook can leave
        // `solver_lhs4` behind after the model dropped to three constraints, and reading
        // every `solver_lhs*` present would silently resurrect it.
        var constraints: [SolverModel.Constraint] = []
        let declared = Int(number(byName["solver_num"]) ?? 0)
        for index in 1...max(declared, 1) where index <= declared {
            guard let lhs = byName["solver_lhs\(index)"].map(cells),
                  let relation = relation(for: number(byName["solver_rel\(index)"])),
                  let rhsTarget = byName["solver_rhs\(index)"] else { continue }
            let rhs: SolverModel.Bound = number(rhsTarget).map { .constant($0) }
                ?? .cells(cells(rhsTarget))
            constraints.append(.init(lhs: lhs, relation: relation, rhs: rhs))
        }

        return SolverModel(
            objective: objective,
            sense: sense,
            variables: variables,
            constraints: constraints,
            engine: engine(for: number(byName["solver_eng"])),
            // Excel's default is to assume non-negative, so an absent name means `true`.
            // `isEqual(to:)` rather than `!=`: this is an exact comparison against a code,
            // chosen deliberately, and naming it says so.
            assumesNonNegative: !(number(byName["solver_neg"])?.isEqual(to: 2) ?? false))
    }

    // MARK: - Encodings

    /// `solver_typ`: 1 maximise, 2 minimise, 3 value of `solver_val`.
    ///
    /// - Parameters:
    ///   - code: The `solver_typ` value.
    ///   - value: The `solver_val` value, for "value of".
    /// - Returns: The sense. Defaults to minimising, which is what a model missing its type
    ///   most likely meant and what costs least if wrong.
    static func sense(for code: Double?, value: Double?) -> SolverModel.Sense {
        switch code {
        case 1: return .maximise
        case 3: return .target(value ?? 0)
        default: return .minimise
        }
    }

    /// `solver_relN`: 1 `<=`, 2 `=`, 3 `>=`, 4 int, 5 bin, 6 all-different.
    ///
    /// - Parameter code: The relation code.
    /// - Returns: The relation, or `nil` for a code with no meaning — which drops the
    ///   constraint rather than guessing at one.
    static func relation(for code: Double?) -> SolverModel.Relation? {
        switch code {
        case 1: return .lessOrEqual
        case 2: return .equal
        case 3: return .greaterOrEqual
        case 4: return .integer
        case 5: return .binary
        case 6: return .allDifferent
        default: return nil
        }
    }

    /// `solver_eng`: 1 GRG Nonlinear, 2 Simplex LP, 3 Evolutionary.
    ///
    /// - Parameter code: The engine code.
    /// - Returns: The engine. Absent means GRG, which is Excel's own default.
    static func engine(for code: Double?) -> SolverModel.Engine {
        switch code {
        case 2: return .simplexLP
        case 3: return .evolutionary
        default: return .grgNonlinear
        }
    }

    // MARK: - Reading targets

    /// The number a name holds, if it holds one rather than a reference.
    private static func number(_ target: NamedRangeTarget?) -> Double? {
        guard case .formula(let ast) = target, case .number(let value) = ast else { return nil }
        return value
    }

    /// Every cell a name covers, in reading order.
    private static func cells(_ target: NamedRangeTarget) -> [CellRef] {
        switch target {
        case .cell(let ref): return [ref]
        case .range(let range): return range.cells
        // A `SheetReference` always carries a `CellRange`; the single-cell initialiser
        // just makes a degenerate one. So both cases read the same way.
        case .sheetCell(let reference), .sheetRange(let reference): return reference.range.cells
        case .formula: return []
        }
    }

    /// The single cell a name points at, if it points at one.
    private static func firstCell(_ target: NamedRangeTarget) -> CellRef? {
        cells(target).first
    }
}
