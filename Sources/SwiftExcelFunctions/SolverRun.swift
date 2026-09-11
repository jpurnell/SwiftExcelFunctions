import Foundation
import BusinessMath
import SwiftExcelCore

/// Why a Solver model could not be run.
public enum SolverRunError: Error, Equatable, Sendable {

    /// The model names no objective cell.
    case noObjective

    /// The model names no cells to adjust.
    case noVariables

    /// A constraint this runner cannot honour.
    ///
    /// **Refused rather than dropped.** Ignoring an integrality constraint answers a
    /// different question than the one asked and returns a fractional solution to a problem
    /// that required whole numbers.
    case unsupportedRelation(SolverModel.Relation)

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
            /// Nelder-Mead, with constraints handled by the optimizer's penalty path.
            case nelderMead
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

        for constraint in model.constraints {
            switch constraint.relation {
            case .lessOrEqual, .equal, .greaterOrEqual:
                continue
            case .integer, .binary, .allDifferent:
                throw SolverRunError.unsupportedRelation(constraint.relation)
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
        for constraint in model.constraints {
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
        for (index, constraint) in model.constraints.enumerated() {
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

        let optimizer = NelderMead<VectorN<Double>>()
        let result: MultivariateOptimizationResult<VectorN<Double>>
        do {
            result = try optimizer.minimize(objective, from: start, constraints: constraints)
        } catch {
            // Carried rather than discarded: the optimizer's own account of why is the
            // only diagnosis a caller will get.
            throw SolverRunError.optimizerFailed(String(describing: error))
        }

        let found = result.solution.toArray()
        // Reported in the caller's terms: the objective cell's own value, not the
        // transformed quantity the optimizer was minimising.
        let objectiveValue = sheet.outputs(at: found)?.first
        var variables: [CellRef: Double] = [:]
        for (ref, value) in zip(model.variables, found) {
            variables[ref.positionKey] = value
        }
        return Solution(variables: variables,
                        objective: objectiveValue ?? .nan,
                        converged: result.converged,
                        engineUsed: .nelderMead)
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
