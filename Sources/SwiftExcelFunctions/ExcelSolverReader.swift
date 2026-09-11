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

        /// A word rather than a value — `"integer"`, `"binary"`, `"alldifferent"`.
        ///
        /// Excel writes these in `solver_rhsN` for the integrality declarations, where a
        /// bound would otherwise go. They carry no numeric meaning: the relation already
        /// says everything, and this is the label Excel shows in its own dialog. Read as
        /// what it is rather than falling through to an empty cell list, which is where it
        /// landed before anyone looked at a real file.
        case label(String)
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
    ///
    /// **Meaningless when ``objective`` is `nil`.** Excel writes `solver_typ` even for a
    /// model that has no objective at all, so this reads as `.maximise` for something that
    /// maximises nothing. Measured, on a workbook saved with Set Objective left blank.
    public let sense: Sense

    /// The decision variables, in the order `solver_adj` lists them.
    public let variables: [CellRef]

    /// The constraints, in declaration order.
    public let constraints: [Constraint]

    /// The engine the workbook nominates. **Advisory** — see ``ExcelSolverReader``.
    public let engine: Engine

    /// Excel's `solver_ver`, the model format's own version number.
    ///
    /// Measured as `2` in Excel for Mac, 2026. It is recorded because it is the one thing
    /// that would make every other encoding here wrong at once: a future Solver writing
    /// version 3 could renumber the relations, and nothing else in the file would say so.
    /// A caller comparing this against what was verified can refuse rather than misread.
    public let formatVersion: Int?

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
    ///   - formatVersion: Excel's `solver_ver`, if the workbook carried one.
    public init(
        objective: CellRef?,
        sense: Sense,
        variables: [CellRef],
        constraints: [Constraint],
        engine: Engine,
        assumesNonNegative: Bool = true,
        formatVersion: Int? = nil
    ) {
        self.objective = objective
        self.sense = sense
        self.variables = variables
        self.constraints = constraints
        self.engine = engine
        self.assumesNonNegative = assumesNonNegative
        self.formatVersion = formatVersion
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
/// ## The encodings are measured
///
/// Every numeric code here was read out of three workbooks built in Excel for Mac on
/// 2026-09-11 and saved without solving — `solver_ver` 2. All six relation codes, all three
/// engines, both settings of `solver_neg`, and `solver_typ` for Max and Value Of matched
/// Frontline's published layout exactly. Only `solver_typ = 2` for Min is inferred, as the
/// remaining value of three.
///
/// Five things the files taught that reading could not:
///
/// - **`solver_num` really is authoritative.** A workbook edited down from six constraints
///   to one kept `solver_lhs2…6` and `solver_rel2…6` in the file, including an
///   `alldifferent`. Reading every `solver_lhs*` present would have resurrected five
///   constraints the model no longer has.
/// - **An integrality declaration's right-hand side is a *word***, not a number:
///   `"integer"`, `"binary"`, `"alldifferent"`. See ``SolverModel/Bound/label(_:)``.
/// - **Excel reorders the constraints**, writing the integrality declarations before the
///   comparisons whatever order they were entered in. Nothing may depend on their order.
/// - **A model with no objective omits `solver_opt` entirely** rather than writing it
///   empty, so the absence is unambiguous — but it still writes `solver_typ`, which
///   therefore means nothing on its own. ``SolverModel/sense`` is only meaningful where
///   ``SolverModel/objective`` is non-`nil`.
/// - **`solver_adj` really is written as a multi-area reference** —
///   `Sheet1!$A$1:$A$3,Sheet1!$C$3` — confirming by observation what the format implied.
///
/// The codes are gathered in `relation(for:)`, `sense(for:value:)` and `engine(for:)` —
/// internal, so plain code spans rather than symbol links — which keeps every encoding in
/// one place. ``SolverModel/formatVersion`` records `solver_ver` because a future version
/// could renumber all of them with nothing else in the file to say so.
public enum ExcelSolverReader {

    /// Reads every Solver model the workbook declares, one per worksheet.
    ///
    /// **Solver models are sheet-scoped**, which the file says plainly: Excel writes every
    /// `solver_` name with a `localSheetId`. A workbook may therefore hold several, one per
    /// worksheet, and reading them into a single namespace merges two models into one made
    /// of neither's parts — the last `solver_opt` seen wins and the constraint count comes
    /// from somewhere else entirely.
    ///
    /// - Parameter names: The workbook's defined names.
    /// - Returns: One model per sheet that declares one, keyed by sheet name. Empty when no
    ///   `solver_` names are present at all — which is a different thing from a model whose
    ///   objective is missing, and the distinction a caller needs in order to say "this
    ///   workbook has no Solver model" honestly.
    public static func models(from names: NamedRangeCollection) -> [String: SolverModel] {
        var bySheet: [String: [String: NamedRangeTarget]] = [:]
        for range in names.all where range.name.lowercased().hasPrefix("solver_") {
            // Workbook-scoped Solver names are not a thing Excel writes, but a file that
            // has been through another tool might carry them; they get their own bucket
            // rather than being attributed to an arbitrary sheet.
            let sheet: String
            if case .sheet(let name) = range.scope { sheet = name } else { sheet = "" }
            bySheet[sheet, default: [:]][range.name.lowercased()] = range.reference
        }
        return bySheet.compactMapValues { model(fromNames: $0) }
    }

    /// Reads one model, for callers with a single-sheet workbook.
    ///
    /// - Parameter names: The workbook's defined names.
    /// - Returns: The model, or `nil`. When several sheets declare one, the sheet that
    ///   sorts first is returned — use ``models(from:)`` where that matters.
    public static func model(from names: NamedRangeCollection) -> SolverModel? {
        let all = models(from: names)
        guard let key = all.keys.sorted().first else { return nil }
        return all[key]
    }

    /// Reads one sheet's model from its own `solver_` names.
    ///
    /// - Parameter byName: The sheet's `solver_` names, lowercased.
    /// - Returns: The model, or `nil` when the sheet declares none.
    private static func model(fromNames byName: [String: NamedRangeTarget]) -> SolverModel? {
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
            let rhs: SolverModel.Bound
            if let value = number(rhsTarget) {
                rhs = .constant(value)
            } else if let word = label(rhsTarget) {
                rhs = .label(word)
            } else {
                rhs = .cells(cells(rhsTarget))
            }
            constraints.append(.init(lhs: lhs, relation: relation, rhs: rhs))
        }

        return SolverModel(
            objective: objective,
            sense: sense,
            variables: variables,
            constraints: constraints,
            engine: engine(for: number(byName["solver_eng"]),
                           linear: number(byName["solver_lin"])),
            // Excel's default is to assume non-negative, so an absent name means `true`.
            // `isEqual(to:)` rather than `!=`: this is an exact comparison against a code,
            // chosen deliberately, and naming it says so.
            assumesNonNegative: !(number(byName["solver_neg"])?.isEqual(to: 2) ?? false),
            formatVersion: number(byName["solver_ver"]).map { Int($0) })
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
    /// Falls back to `solver_lin`, the "Assume Linear Model" checkbox that Solver used
    /// before 2010 and still writes — measured as `1` beside Simplex and `2` beside
    /// Evolutionary. A workbook old enough to carry `solver_lin` and *no* `solver_eng`
    /// declares a linear model, and reading it as GRG would quietly solve a linear program
    /// with a nonlinear method.
    ///
    /// - Parameters:
    ///   - code: The `solver_eng` value.
    ///   - linear: The `solver_lin` value, for a file that has no `solver_eng`.
    /// - Returns: The engine. Absent from both means GRG, which is Excel's own default.
    static func engine(for code: Double?, linear: Double? = nil) -> SolverModel.Engine {
        switch code {
        case 2: return .simplexLP
        case 3: return .evolutionary
        case 1: return .grgNonlinear
        default:
            return linear?.isEqual(to: 1) == true ? .simplexLP : .grgNonlinear
        }
    }

    // MARK: - Reading targets

    /// The number a name holds, if it holds one rather than a reference.
    ///
    /// **A bare number arrives as text.** `solver_eng` refers to `2`, which is not a cell
    /// reference, so `DefinedNameResolver` cannot resolve it and hands back
    /// `.formula(.text("2"))`. Reading only `.number` therefore found nothing in a real
    /// file: every engine read as GRG and every model as having no constraints, because
    /// `solver_num` was unreadable too.
    ///
    /// The tests did not catch it because they built these targets by hand — encoding an
    /// assumption about the parse rather than exercising it. `ExcelSolverReaderRealFileTests`
    /// goes through the resolver for exactly that reason.
    private static func number(_ target: NamedRangeTarget?) -> Double? {
        guard case .formula(let ast) = target else { return nil }
        switch ast {
        case .number(let value): return value
        case .text(let text): return Double(text.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// The word a name holds, if it holds text rather than a number or a reference.
    private static func label(_ target: NamedRangeTarget?) -> String? {
        guard case .formula(let ast) = target, case .text(let word) = ast else { return nil }
        // A bare number also arrives as text, and `"10"` is a bound rather than a label.
        // Callers try `number(_:)` first; this guard makes the order unnecessary to know.
        guard Double(word.trimmingCharacters(in: .whitespaces)) == nil else { return nil }
        return word
    }

    /// Every cell a name covers, in reading order.
    ///
    /// **A multi-area reference is one name covering several blocks** — Excel lets the
    /// changing cells be `$A$1:$A$3,$C$5`, and writes exactly that. It resolves to no
    /// single cell or range, so it arrives as a formula, and returning nothing for it reads
    /// as "a model with nothing to adjust" rather than as a model this could not parse.
    /// Each comma-separated part is therefore read on its own.
    private static func cells(_ target: NamedRangeTarget) -> [CellRef] {
        switch target {
        case .cell(let ref): return [ref]
        case .range(let range): return range.cells
        // A `SheetReference` always carries a `CellRange`; the single-cell initialiser
        // just makes a degenerate one. So both cases read the same way.
        case .sheetCell(let reference), .sheetRange(let reference): return reference.range.cells
        case .formula(let ast):
            guard case .text(let reference) = ast else { return [] }
            return areas(in: reference)
        }
    }

    /// The cells of a possibly multi-area reference string.
    ///
    /// - Parameter reference: Something like `Sheet1!$A$1:$A$3,Sheet1!$C$5`.
    /// - Returns: Every cell it covers, in the order the areas are written.
    private static func areas(in reference: String) -> [CellRef] {
        reference.split(separator: ",").flatMap { part -> [CellRef] in
            // The sheet qualifier is dropped: a Solver model's cells are on the sheet that
            // owns the model, and the parts of one name cannot disagree about that.
            let body = part.split(separator: "!").last.map(String.init) ?? String(part)
            guard !body.isEmpty else { return [] }
            // Normalised to relative, because `CellRange.cells` yields relative refs and a
            // list mixing `A1` with `$C$5` invites a caller to compare two of its own
            // entries and find them unequal. Position is what a model means here; the `$`
            // is notation from the file.
            let parsed = body.contains(":") ? CellRange(body).cells : [CellRef(body)]
            return parsed.map { CellRef(column: $0.column, row: $0.row) }
        }
    }

    /// The single cell a name points at, if it points at one.
    private static func firstCell(_ target: NamedRangeTarget) -> CellRef? {
        cells(target).first
    }
}
