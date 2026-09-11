import Foundation
import BusinessMath
import SwiftExcelCore

/// Why a Solver model could not be run.
public enum SolverRunError: Error, Equatable, Sendable {

    /// The model names no cells to adjust.
    case noVariables

    /// An integrality constraint names a cell that is not a decision variable.
    ///
    /// Excel only lets one be declared on an adjustable cell, and a constraint that says a
    /// *computed* cell must be whole is not a statement this runner can act on.
    case integralityOnNonVariable(CellRef)

    /// The evolutionary engine was nominated but a variable has no bounds.
    ///
    /// Excel refuses the same way. A population-based search samples *within* a box, so
    /// without one there is nothing to sample from — and inventing a range would make the
    /// answer depend on a number nobody chose.
    case evolutionaryNeedsBounds(CellRef)

    /// A constraint this runner cannot express.
    ///
    /// **Refused rather than approximated.** Excel's "all different" requires the variables
    /// to be pairwise distinct, which is strictly stronger than requiring them to be whole.
    /// Treating it as integrality — which an earlier draft did — answers a different
    /// question and returns a solution with repeats in it, confidently.
    case unsupportedRelation(SolverModel.Relation)

    /// Simplex was nominated but the model is not linear.
    ///
    /// **Refused rather than quietly re-solved**, which is also Excel's own answer: "the
    /// linearity conditions required by this LP Solver are not satisfied". Switching engines
    /// silently would hand back a number the caller believes came from an LP.
    case nonlinearModel(String)

    /// The optimizer refused or failed.
    case optimizerFailed(String)
}

/// Runs a workbook's Solver model.
///
/// The join between three pieces that already existed: ``ExcelSolverReader`` says what the
/// model is, ``SpreadsheetFunction`` makes the sheet callable as a function of its variable
/// cells, and BusinessMath does the searching.
///
/// Read a model with `ExcelSolverReader.model(from:)`, then hand it here with the sheet it
/// refers to and a name resolver.
///
/// ## The nominated engine is not obeyed
///
/// ``SolverModel/engine`` records what the workbook asked for. This runs Nelder-Mead
/// regardless and reports that in ``Solution/engineUsed``, because the alternative is worse
/// than the limitation: Excel's Simplex needs a *linear* model — coefficients, not a
/// callable sheet — and extracting one means proving the objective and constraints are
/// linear in the variables first. BusinessMath has `LinearityValidation` for exactly that,
/// and wiring it is separate work.
///
/// Claiming to have run Simplex while running something else would be the plausible wrong
/// answer in reporting rather than in arithmetic, which is no better.
public enum SolverRun {

    /// A solved model.
    public struct Solution: Sendable {

        /// The values found, keyed by the cell each belongs to.
        ///
        /// Keyed rather than ordered because an optimizer returns a vector and a caller
        /// needs to know which cell each slot was.
        public let variables: [CellRef: Double]

        /// The objective cell's value at the solution, in the caller's terms — not the
        /// optimizer's, which may have been minimising a negation or a distance.
        ///
        /// `nil` for a model with no objective. Excel allows one: leave Set Objective blank
        /// and Solver looks for any point satisfying the constraints. Measured — such a
        /// workbook omits `solver_opt` entirely rather than writing it empty.
        public let objective: Double?

        /// Whether the optimizer reported convergence.
        public let converged: Bool

        /// The worst constraint violation at the reported point, in the constraint's own
        /// units. Zero or negative means every constraint holds.
        ///
        /// **Reported rather than hidden.** Where constraints are handled by penalty the
        /// optimizer satisfies them approximately, and an earlier draft of this file
        /// projected the answer onto its bounds to tidy that away — which does not fix
        /// infeasibility, it moves it: clamping a variable that an equality ties to another
        /// simply breaks the equality instead. Excel reports the same thing, as "Solver
        /// could not find a feasible solution".
        public let worstViolation: Double

        /// Whether every constraint holds at the reported point, within `precision`.
        ///
        /// - Parameter precision: How much violation to tolerate. Excel's own default for
        ///   its Constraint Precision setting is `1e-6`.
        /// - Returns: Whether the solution is feasible.
        public func isFeasible(within precision: Double = 1e-6) -> Bool {
            worstViolation <= precision
        }

        /// What actually ran. See the note on ``SolverRun``.
        public let engineUsed: Engine

        /// The optimizers this runner can dispatch to.
        public enum Engine: Equatable, Sendable {
            /// Nelder-Mead. Stands in for Excel's GRG Nonlinear.
            case nelderMead
            /// True simplex, on coefficients extracted from the sheet.
            case simplex
            /// Differential evolution. Stands in for Excel's Evolutionary.
            case differentialEvolution
            /// Branch-and-bound, whenever any variable must be whole.
            case branchAndBound
        }
    }

    /// Reads a sheet's Solver model and solves it.
    ///
    /// The two halves in one call, for a caller who should not have to know they are
    /// separate types.
    ///
    /// **It takes a provider and a name collection rather than a workbook.** This package
    /// promises to take no dependency on a file format, and `Workbook` belongs to
    /// SwiftXLSX — a library that evaluates a sheet which never came from a file cannot
    /// name one. `WorkbookAudit` is where the file-reading half lives, and a caller holding
    /// a real workbook passes its provider and its `namedRanges` here.
    ///
    /// - Parameters:
    ///   - cells: The sheet the model refers to.
    ///   - names: The workbook's defined names.
    ///   - sheet: Which sheet's model to solve. Solver models are sheet-scoped, so a
    ///     workbook may hold several; `nil` takes the first by name, which is the right
    ///     answer only when there is one.
    /// - Returns: The solution, or `nil` when the sheet declares no model — an ordinary
    ///   answer about an ordinary workbook rather than a failure.
    /// - Throws: ``SolverRunError``.
    public static func solve(
        cells: any CellValueProvider & PopulatedCellProvider,
        names: NamedRangeCollection,
        inSheet sheet: String? = nil
    ) throws -> Solution? {
        let models = ExcelSolverReader.models(from: names)
        let model: SolverModel?
        if let sheet {
            model = models[sheet]
        } else {
            model = models.keys.sorted().first.flatMap { models[$0] }
        }
        guard let model else { return nil }
        return try solve(model, cells: cells, names: names)
    }

    /// Solves a model against a sheet.
    ///
    /// - Parameters:
    ///   - model: The model, as read from the workbook's defined names.
    ///   - cells: The sheet the model refers to.
    ///   - names: The named-range resolver.
    /// - Returns: The solution, with the objective reported in the caller's terms.
    /// - Throws: ``SolverRunError``.
    public static func solve(
        _ model: SolverModel,
        cells: any CellValueProvider & PopulatedCellProvider,
        names: any NameResolver
    ) throws -> Solution {
        guard !model.variables.isEmpty else { throw SolverRunError.noVariables }

        // Integrality declarations are separated from comparisons here, because Excel
        // writes them in the same list and they are not the same kind of statement:
        // `C1 <= 10` constrains a computed cell, `A1 integer` constrains a variable.
        var integerIndices: Set<Int> = []
        var binaryIndices: Set<Int> = []
        var distinctGroups: [[Int]] = []
        var comparisons: [SolverModel.Constraint] = []
        let position = Dictionary(uniqueKeysWithValues:
            model.variables.enumerated().map { ($1.positionKey, $0) })
        for constraint in model.constraints {
            switch constraint.relation {
            case .lessOrEqual, .equal, .greaterOrEqual:
                comparisons.append(constraint)
            case .allDifferent:
                // Excel's `dif`: the group takes the integers 1…N, each once, where N is
                // the group's size. So it is integrality *plus* a box *plus* pairwise
                // distinctness — three statements in one checkbox.
                var group: [Int] = []
                for ref in constraint.lhs {
                    guard let index = position[ref.positionKey] else {
                        throw SolverRunError.integralityOnNonVariable(ref)
                    }
                    group.append(index)
                }
                distinctGroups.append(group)
            case .integer, .binary:
                for ref in constraint.lhs {
                    guard let index = position[ref.positionKey] else {
                        throw SolverRunError.integralityOnNonVariable(ref)
                    }
                    if constraint.relation == .binary {
                        binaryIndices.insert(index)
                    } else {
                        integerIndices.insert(index)
                    }
                }
            }
        }

        // Every cell the search needs to see, read in one pass per candidate: the
        // objective, then each constraint's left-hand side. Reading them separately would
        // recompute the sheet once per cell.
        // Every cell the search must see goes into one output vector, so a candidate
        // recomputes the sheet once rather than once per cell.
        // **A model may have no objective.** Excel allows it — leave Set Objective blank
        // and Solver looks for any feasible point — so the objective is one output when
        // there is one and none when there is not. Everything downstream indexes from
        // `outputCells.count` rather than from a fixed 1, which is what makes that work.
        var outputCells: [CellRef] = model.objective.map { [$0] } ?? []
        var lhsOffsets: [Int] = []
        var rhsOffsets: [Int?] = []
        for constraint in comparisons {
            lhsOffsets.append(outputCells.count)
            outputCells.append(contentsOf: constraint.lhs)
            // A bound that names cells is read from the sheet like anything else. Comparing
            // against zero instead — which an earlier draft did — is wrong rather than
            // unsupported, and silently so.
            if case .cells(let refs) = constraint.rhs {
                rhsOffsets.append(outputCells.count)
                outputCells.append(contentsOf: refs)
            } else {
                rhsOffsets.append(nil)
            }
        }
        let sheet = try SpreadsheetFunction(
            inputs: model.variables,
            outputs: outputCells,
            cells: cells, names: names)

        // **All-different is satisfied by construction rather than constrained.**
        //
        // Excel's `dif` says the group takes the integers 1…N, each once — a permutation.
        // Expressed as constraints that is disjunctive (`xᵢ ≠ xⱼ` is two inequalities with
        // an or between them), which no penalty can enforce and which an earlier draft got
        // wrong: starting at (0, 0, 0) the search stayed there, the penalty never
        // outweighing the objective.
        //
        // Decoding removes the problem instead of policing it. The optimizer's values are
        // read as *sort keys*, and the permutation is their rank order, so every point in
        // the whole search space maps to a valid permutation and no infeasible point
        // exists to be found. This is the random-key encoding, and it is why these
        // variables need no integrality, no bounds and no distinctness constraints.
        // The simple bounds this runner generated. Applied the same way the permutation
        // decode is — by construction rather than by penalty.
        //
        // **A penalty makes a hard bound soft.** NelderMead penalises every constraint it
        // is given, `.linearInequality` included: only branch-and-bound's relaxation and
        // simplex enforce those exactly. So a bound handed to the general path is a
        // *preference*, and the search trades it against the objective and settles outside
        // — non-negativity came back as -0.005.
        //
        // Clamping inside the objective removes the trade. Every evaluation happens at a
        // point inside the bounds, so the function being minimised *is* the bounded one,
        // and the point reported is the point that was evaluated. That is the difference
        // from clamping the final answer, which an earlier draft did: that left the
        // reported point inconsistent with the objective the optimizer had seen, and moved
        // violations onto whatever other constraint tied the variable down.
        //
        // Not on the simplex path. There the bounds are real constraints the solver
        // enforces exactly, and clamping would make the objective nonlinear — `max(x, 0)`
        // is not a linear function — so the linearity probe would reject a model that is
        // perfectly linear.
        var lowerBound = [Double?](repeating: nil, count: model.variables.count)
        if model.assumesNonNegative, model.engine != .simplexLP {
            for index in model.variables.indices { lowerBound[index] = 0 }
        }
        let floors = lowerBound
        let groups = distinctGroups
        let decode: @Sendable ([Double]) -> [Double] = { raw in
            var decoded = raw
            for index in decoded.indices {
                if let low = floors[index] { decoded[index] = max(decoded[index], low) }
            }
            guard !groups.isEmpty else { return decoded }
            for group in groups {
                let ranked = group.enumerated()
                    .sorted { decoded[$0.element] < decoded[$1.element] }
                    .map(\.offset)
                for (rank, offset) in ranked.enumerated() {
                    decoded[group[offset]] = Double(rank + 1)
                }
            }
            return decoded
        }

        let sense = model.sense
        let hasObjective = model.objective != nil
        let objective: @Sendable (VectorN<Double>) -> Double = { point in
            // Infinity for a point the sheet cannot evaluate: for a minimiser that reads
            // as "not here", which is what an infeasible point means.
            guard let out = sheet.outputs(at: decode(point.toArray())) else { return .infinity }
            // With no objective the search is a feasibility search: every evaluable point
            // is equally good, and the constraints do all the work.
            return hasObjective ? cost(of: out, under: sense) : 0
        }

        var constraints: [MultivariateConstraint<VectorN<Double>>] = []
        for (index, constraint) in comparisons.enumerated() {
            let start = lhsOffsets[index]
            let boundStart = rhsOffsets[index]
            let count = constraint.lhs.count
            let relation = constraint.relation
            let bound = constraint.rhs
            // One closure per *cell* of the left-hand side: `C1:C5 <= 10` is one row of
            // Excel's dialog and five separate conditions.
            for offset in 0..<count {
                let slot = start + offset
                let body: @Sendable (VectorN<Double>) -> Double = { point in
                    guard let out = sheet.outputs(at: decode(point.toArray())) else {
                        return .infinity
                    }
                    let lhs = out[slot]
                    let rhs = boundStart.map { out[$0 + min(offset, count - 1)] }
                        ?? constantValue(of: bound)
                    switch relation {
                    case .lessOrEqual: return lhs - rhs        // g(x) ≤ 0
                    case .greaterOrEqual: return rhs - lhs
                    default: return lhs - rhs                  // h(x) = 0
                    }
                }
                constraints.append(relation == .equal
                    ? .equality(function: body, gradient: nil)
                    : .inequality(function: body, gradient: nil))
            }
        }

        // Excel's non-negativity checkbox, which is a *constraint generator* rather than a
        // flag: it adds `x >= 0` to every variable, and that is why turning it off changes
        // the answer rather than merely permitting a different one.
        // **Structured, not closures.** `.linearInequality` is what branch-and-bound
        // enforces through its relaxation — it is the form B&B itself emits when it
        // branches. An opaque `.inequality(function:)` can only be *penalised*, which makes
        // a hard bound soft: the search trades violation against objective and settles
        // slightly outside. That is how non-negativity came back as -0.005.
        func bound(_ index: Int, _ sense: ConstraintSense, _ rhs: Double)
            -> MultivariateConstraint<VectorN<Double>> {
            var coefficients = [Double](repeating: 0, count: model.variables.count)
            coefficients[index] = 1
            return .linearInequality(coefficients: coefficients, rhs: rhs, sense: sense)
        }
        // Only for the paths that enforce them exactly. The general path gets the same
        // bounds structurally, above, so adding them here as well would penalise a
        // constraint that can no longer be violated.
        if model.assumesNonNegative, model.engine == .simplexLP {
            for index in model.variables.indices {
                constraints.append(bound(index, .greaterOrEqual, 0))
            }
        }


        let startValues = model.variables.map { ref -> Double in
            if case .number(let value) = cells.value(at: ref) ?? .blank { return value }
            return 0
        }
        let start = VectorN(startValues)

        let integral = !integerIndices.isEmpty || !binaryIndices.isEmpty
        let found: [Double]
        let converged: Bool
        let used: Solution.Engine

        if integral {
            // **Integrality outranks the nominated engine**, as it does in Excel: whichever
            // engine a workbook asks for, whole-number variables mean branch-and-bound.
            let specification = IntegerProgramSpecification(
                integerVariables: integerIndices, binaryVariables: binaryIndices)
            let solver = BranchAndBoundSolver<VectorN<Double>>()
            do {
                let result = try solver.solve(
                    objective: objective, from: start,
                    subjectTo: constraints, integerSpec: specification)
                found = result.solution.toArray()
                converged = true
                used = .branchAndBound
            } catch let failure {
                throw SolverRunError.optimizerFailed(String(describing: failure))
            }
        } else if model.engine == .simplexLP {
            // Simplex needs coefficients rather than a callable sheet, so the sheet is
            // probed for them — and refused if it is not linear, which is Excel's own
            // answer rather than a silent change of engine.
            let solved = try simplex(objective: objective, constraints: constraints,
                                     start: start, dimension: model.variables.count,
                                     free: !model.assumesNonNegative)
            found = solved.solution
            converged = solved.converged
            used = .simplex
        } else {
            // Outside the `do`: a missing bound is the model's problem, not the
            // optimizer's, and wrapping it as `optimizerFailed` would misattribute it.
            let searchSpace = model.engine == .evolutionary
                ? try box(for: model, comparisons: comparisons)
                : []
            let result: MultivariateOptimizationResult<VectorN<Double>>
            do {
                if model.engine == .evolutionary {
                    result = try DifferentialEvolution<VectorN<Double>>(searchSpace: searchSpace)
                        .minimize(objective, from: start, constraints: constraints)
                    used = .differentialEvolution
                } else {
                    result = try NelderMead<VectorN<Double>>()
                        .minimize(objective, from: start, constraints: constraints)
                    used = .nelderMead
                }
            } catch let failure {
                // Carried rather than discarded: the optimizer's own account of why is the
                // only diagnosis a caller will get.
                throw SolverRunError.optimizerFailed(String(describing: failure))
            }
            found = result.solution.toArray()
            converged = result.converged
        }

        // Decoded, so the reported variables are the permutation the objective was
        // actually evaluated at rather than the sort keys that produced it.
        let held = decode(found)
        // Reported in the caller's terms: the objective cell's own value at the reported
        // point, not the transformed quantity the optimizer was minimising.
        let objectiveValue = hasObjective ? sheet.outputs(at: held)?.first : nil
        // Measured at the point being reported, so the number describes the answer the
        // caller is given rather than some intermediate the optimizer passed through.
        let point = VectorN(found)
        var worst = 0.0
        for constraint in constraints {
            switch constraint {
            case .inequality(let function, _):
                worst = max(worst, function(point))
            case .equality(let function, _):
                worst = max(worst, abs(function(point)))
            case .linearInequality(let coefficients, let rhs, let sense):
                let lhs = zip(coefficients, held).reduce(0) { $0 + $1.0 * $1.1 }
                switch sense {
                case .lessOrEqual: worst = max(worst, lhs - rhs)
                case .greaterOrEqual: worst = max(worst, rhs - lhs)
                case .equal: worst = max(worst, abs(lhs - rhs))
                }
            default:
                continue
            }
        }

        var variables: [CellRef: Double] = [:]
        for (ref, value) in zip(model.variables, held) {
            variables[ref.positionKey] = value
        }
        return Solution(variables: variables,
                        objective: hasObjective ? (objectiveValue ?? .nan) : nil,
                        converged: converged,
                        worstViolation: worst,
                        engineUsed: used)
    }

    /// The box a population-based search samples within.
    ///
    /// Read from the constraints that are plain bounds on a single variable — `A1 >= 0`,
    /// `A1 <= 10`. A variable with no bound is refused rather than given an invented range,
    /// because the answer would then depend on a number nobody in the workbook chose.
    ///
    /// - Parameters:
    ///   - model: The model, for its variables.
    ///   - comparisons: The comparison constraints.
    /// - Returns: One `(lower, upper)` pair per variable, in variable order.
    /// - Throws: ``SolverRunError/evolutionaryNeedsBounds(_:)``.
    private static func box(
        for model: SolverModel, comparisons: [SolverModel.Constraint]
    ) throws -> [(lower: Double, upper: Double)] {
        var lower = [Double?](repeating: nil, count: model.variables.count)
        var upper = [Double?](repeating: nil, count: model.variables.count)
        let position = Dictionary(uniqueKeysWithValues:
            model.variables.enumerated().map { ($1.positionKey, $0) })

        for constraint in comparisons {
            // Only a constraint naming one variable directly, against a number, is a bound.
            // `C1 <= 10` constrains a computed cell and says nothing about the box.
            guard constraint.lhs.count == 1,
                  let index = position[constraint.lhs[0].positionKey],
                  case .constant(let value) = constraint.rhs else { continue }
            switch constraint.relation {
            case .greaterOrEqual: lower[index] = max(lower[index] ?? value, value)
            case .lessOrEqual: upper[index] = min(upper[index] ?? value, value)
            case .equal:
                lower[index] = value
                upper[index] = value
            default: continue
            }
        }

        return try model.variables.indices.map { index in
            guard let low = lower[index], let high = upper[index] else {
                throw SolverRunError.evolutionaryNeedsBounds(model.variables[index])
            }
            return (lower: low, upper: high)
        }
    }

    /// Solves a linear model with simplex, on coefficients probed out of the sheet.
    ///
    /// `validateLinearModel` samples the function and refuses if the samples do not lie on
    /// a plane, which is what makes this honest: a nonlinear sheet cannot be made to look
    /// linear by asking politely.
    ///
    /// - Parameters:
    ///   - objective: The quantity being minimised.
    ///   - constraints: The constraint closures, in the same order as `comparisons`.
    ///   - comparisons: The declared comparisons, for their relations.
    ///   - start: Where to probe from.
    ///   - dimension: How many variables.
    ///   - sense: What the model wants, for reporting.
    /// - Returns: The solution and whether it was optimal.
    /// - Throws: ``SolverRunError/nonlinearModel(_:)`` or ``SolverRunError/optimizerFailed(_:)``.
    private static func simplex(
        objective: @escaping @Sendable (VectorN<Double>) -> Double,
        constraints: [MultivariateConstraint<VectorN<Double>>],
        start: VectorN<Double>,
        dimension: Int,
        free: Bool
    ) throws -> (solution: [Double], converged: Bool) {
        let objectiveTerms: (coefficients: [Double], constant: Double)
        do {
            objectiveTerms = try validateLinearModel(objective, dimension: dimension, at: start)
        } catch let failure {
            throw SolverRunError.nonlinearModel("objective: \(failure)")
        }

        // Every constraint closure is already `g(x) <= 0` or `h(x) = 0`, so its linear
        // terms give `c·x <= -k` directly. Which relation it was is recovered from the
        // case rather than from the declaration, so the derived constraints — the
        // non-negativity and all-different rows added above — come through too.
        var rows: [(coefficients: [Double], relation: ConstraintRelation, rhs: Double)] = []
        for constraint in constraints {
            let isEquality: Bool
            switch constraint {
            case .equality: isEquality = true
            case .inequality: isEquality = false
            default: continue
            }
            let terms: (coefficients: [Double], constant: Double)
            do {
                terms = try validateLinearModel(
                    { point in evaluate(constraint, at: point) }, dimension: dimension, at: start)
            } catch let failure {
                throw SolverRunError.nonlinearModel("constraint: \(failure)")
            }
            rows.append((terms.coefficients,
                         isEquality ? .equal : .lessOrEqual,
                         -terms.constant))
        }

        // **Free variables are split rather than refused.** Simplex assumes `x >= 0` in its
        // structure, so a variable Excel permits to go negative becomes `x⁺ - x⁻` with both
        // halves non-negative. The dimension doubles and the answer is recombined; nothing
        // about the model changes.
        let width = free ? dimension * 2 : dimension
        func widen(_ coefficients: [Double]) -> [Double] {
            free ? coefficients + coefficients.map { -$0 } : coefficients
        }

        let simplexRows = rows.map {
            SimplexConstraint(coefficients: widen($0.coefficients),
                              relation: $0.relation, rhs: $0.rhs)
        }

        do {
            let result = try SimplexSolver().minimize(
                objective: widen(objectiveTerms.coefficients), subjectTo: simplexRows)
            guard result.solution.count >= width else {
                throw SolverRunError.optimizerFailed(
                    "simplex returned \(result.solution.count) values for \(width) columns")
            }
            let recombined = free
                ? (0..<dimension).map { result.solution[$0] - result.solution[$0 + dimension] }
                : Array(result.solution.prefix(dimension))
            return (recombined, result.status == .optimal)
        } catch let failure as SolverRunError {
            throw failure
        } catch let failure {
            throw SolverRunError.optimizerFailed(String(describing: failure))
        }
    }

    /// A constraint closure's value at a point, whichever case it is.
    ///
    /// - Parameters:
    ///   - constraint: The constraint.
    ///   - point: Where to evaluate it.
    /// - Returns: The constraint function's value.
    private static func evaluate(
        _ constraint: MultivariateConstraint<VectorN<Double>>, at point: VectorN<Double>
    ) -> Double {
        switch constraint {
        case .equality(let function, _), .inequality(let function, _):
            return function(point)
        default:
            return 0
        }
    }

    /// What the optimizer minimises, given what the model asked for.
    ///
    /// - Parameters:
    ///   - value: The objective cell's value.
    ///   - sense: What the model wants done with it.
    /// - Returns: A quantity whose minimum is the model's optimum.
    private static func cost(of outputs: [Double], under sense: SolverModel.Sense) -> Double {
        let value = outputs.first ?? .infinity
        switch sense {
        case .minimise: return value
        case .maximise: return -value
        // "Value of" is a third problem rather than an extreme: minimise the distance.
        case .target(let target): return abs(value - target)
        }
    }

    /// A constant bound's value.
    ///
    /// - Parameter bound: The declared bound.
    /// - Returns: The number, or zero for a bound that names cells — which never reaches
    ///   here, since those are read from the sheet.
    private static func constantValue(of bound: SolverModel.Bound) -> Double {
        switch bound {
        case .constant(let value): return value
        // A label is Excel's word for an integrality declaration — "integer", "binary",
        // "alldifferent" — and those constrain the variable rather than compare it, so
        // there is nothing to measure against.
        case .label, .cells: return 0
        }
    }
}
