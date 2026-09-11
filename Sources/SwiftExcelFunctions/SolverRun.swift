import Foundation
import BusinessMath
import SwiftExcelCore

/// Why a Solver model could not be run.
public enum SolverRunError: Error, Equatable, Sendable {

    /// The model names no objective cell.
    case noObjective

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

    /// Simplex was nominated on a model that permits negative variables.
    ///
    /// A simplex solver assumes `x >= 0` in its structure rather than as a constraint, so
    /// it cannot answer for a model whose `solver_neg` permits negatives without silently
    /// returning the answer to a different problem.
    case simplexRequiresNonNegative

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
        public let objective: Double

        /// Whether the optimizer reported convergence.
        public let converged: Bool

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
        guard let objectiveCell = model.objective else { throw SolverRunError.noObjective }
        guard !model.variables.isEmpty else { throw SolverRunError.noVariables }

        // Integrality declarations are separated from comparisons here, because Excel
        // writes them in the same list and they are not the same kind of statement:
        // `C1 <= 10` constrains a computed cell, `A1 integer` constrains a variable.
        var integerIndices: Set<Int> = []
        var binaryIndices: Set<Int> = []
        var comparisons: [SolverModel.Constraint] = []
        let position = Dictionary(uniqueKeysWithValues:
            model.variables.enumerated().map { ($1.positionKey, $0) })
        for constraint in model.constraints {
            switch constraint.relation {
            case .lessOrEqual, .equal, .greaterOrEqual:
                comparisons.append(constraint)
            case .allDifferent:
                // Pairwise distinctness, which is stronger than integrality and which
                // `IntegerProgramSpecification` cannot express — it carries integer, binary
                // and SOS sets, none of which say "no two of these are equal".
                throw SolverRunError.unsupportedRelation(.allDifferent)
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
        var outputCells = [objectiveCell]
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

        let sense = model.sense
        let objective: @Sendable (VectorN<Double>) -> Double = { point in
            // Infinity for a point the sheet cannot evaluate: for a minimiser that reads
            // as "not here", which is what an infeasible point means.
            guard let out = sheet.outputs(at: point.toArray()) else { return .infinity }
            return cost(of: out, under: sense)
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
                    guard let out = sheet.outputs(at: point.toArray()) else { return .infinity }
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

        let start = VectorN(model.variables.map { ref in
            if case .number(let value) = cells.value(at: ref) ?? .blank { return value }
            return 0
        })

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
            guard model.assumesNonNegative else {
                throw SolverRunError.simplexRequiresNonNegative
            }
            // Simplex needs coefficients rather than a callable sheet, so the sheet is
            // probed for them — and refused if it is not linear, which is Excel's own
            // answer rather than a silent change of engine.
            let solved = try simplex(objective: objective, constraints: constraints,
                                     comparisons: comparisons, start: start,
                                     dimension: model.variables.count, sense: model.sense)
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

        // Reported in the caller's terms: the objective cell's own value, not the
        // transformed quantity the optimizer was minimising.
        let objectiveValue = sheet.outputs(at: found)?.first
        var variables: [CellRef: Double] = [:]
        for (ref, value) in zip(model.variables, found) {
            variables[ref.positionKey] = value
        }
        return Solution(variables: variables,
                        objective: objectiveValue ?? .nan,
                        converged: converged,
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
        comparisons: [SolverModel.Constraint],
        start: VectorN<Double>,
        dimension: Int,
        sense: SolverModel.Sense
    ) throws -> (solution: [Double], converged: Bool) {
        let objectiveTerms: (coefficients: [Double], constant: Double)
        do {
            objectiveTerms = try validateLinearModel(objective, dimension: dimension, at: start)
        } catch let failure {
            throw SolverRunError.nonlinearModel("objective: \(failure)")
        }

        // One simplex row per constraint closure. Each closure is already in the form
        // `g(x) <= 0` or `h(x) = 0`, so its linear terms give `c·x <= -k` directly.
        var rows: [SimplexConstraint] = []
        var index = 0
        for constraint in comparisons {
            for _ in constraint.lhs {
                guard index < constraints.count else { break }
                let body = constraints[index]
                index += 1
                let terms: (coefficients: [Double], constant: Double)
                do {
                    terms = try validateLinearModel(
                        { point in evaluate(body, at: point) }, dimension: dimension, at: start)
                } catch let failure {
                    throw SolverRunError.nonlinearModel("constraint: \(failure)")
                }
                rows.append(SimplexConstraint(
                    coefficients: terms.coefficients,
                    relation: constraint.relation == .equal ? .equal : .lessOrEqual,
                    rhs: -terms.constant))
            }
        }

        // Simplex assumes `x >= 0` structurally. The caller has already checked that the
        // model agrees, because a model permitting negatives cannot be answered here.
        do {
            let solver = SimplexSolver()
            let result = try solver.minimize(objective: objectiveTerms.coefficients,
                                             subjectTo: rows)
            return (result.solution, result.status == .optimal)
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
        if case .constant(let value) = bound { return value }
        return 0
    }
}
