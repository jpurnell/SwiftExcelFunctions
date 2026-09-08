import Foundation
import BusinessMath
import SwiftExcelCore

/// Risk Solver's `*Alt` distributions — the same distributions, parameterised by
/// what the modeller actually knows.
///
/// `PsiNormalAlt(0.05, 1.5, 0.95, 4.5)` says "the 5th percentile is 1.5 and the
/// 95th is 4.5" rather than stating a mean and a deviation. Twenty-eight functions
/// are written this way, and they are **not** twenty-eight distributions: they are
/// one problem — given *k* constraints on a *k*-parameter distribution, solve for
/// the parameters — stated twenty-eight times.
///
/// So there is one binding here, applied to each name. BusinessMath supplies the
/// solve as `PercentileParameterisable.fitting(_:)`; this reads Frontline's
/// argument convention into `ParameterConstraint`s.
///
/// ## Reading the arguments
///
/// Arguments come in **pairs**: a name, then a value.
///
/// ```
/// PsiFatigueLifeAlt(5%, 1.5, 50%, 2.5, 95%, 4.5)     three quantile constraints
/// PsiNormalAlt("mean", 10, 0.95, 15)                 a moment and a quantile
/// ```
///
/// A *numeric* name is a probability; a *textual* one names a moment or a native
/// parameter. That split is what removes the ambiguity a purely numeric convention
/// would have: a bare `(0.05, x)` pair cannot say whether it means "the 5th
/// percentile is x" or "the scale is 0.05", and Excel's `5%` formatting is display
/// rather than value, so it does not survive into the AST.
enum BuiltinRiskSolverAltDistributions {

    /// Every `*Alt` distribution, one per conforming BusinessMath type.
    static let all: [ExcelFunction] = [
        alt("PSINORMALALT", DistributionNormal.self),
        alt("PSILOGNORMALALT", DistributionLogNormal.self),
        alt("PSIUNIFORMALT", DistributionUniform.self),
        alt("PSITRIANGULARALT", DistributionTriangular.self),
        alt("PSIEXPONENTIALALT", DistributionExponential.self),
        alt("PSIWEIBULLALT", DistributionWeibull.self),
        alt("PSIGAMMAALT", DistributionGamma.self),
        alt("PSIBETAGENALT", DistributionBetaGeneralised.self),
        alt("PSICAUCHYALT", DistributionCauchy.self),
        alt("PSILAPLACEALT", DistributionLaplace.self),
        alt("PSILEVYALT", DistributionLevy.self),
        alt("PSILOGISTICALT", DistributionLogistic.self),
        alt("PSILOGLOGISTICALT", DistributionLogLogistic.self),
        alt("PSIPARETOALT", DistributionPareto.self),
        alt("PSIPARETO2ALT", DistributionPareto2.self),
        alt("PSIPEARSON5ALT", DistributionPearson5.self),
        alt("PSIPEARSON6ALT", DistributionPearson6.self),
        alt("PSIRAYLEIGHALT", DistributionRayleigh.self),
        alt("PSIMAXEXTREMEALT", DistributionMaxExtreme.self),
        alt("PSIMINEXTREMEALT", DistributionMinExtreme.self),
        alt("PSIFRECHETALT", DistributionFrechet.self),
        alt("PSIFATIGUELIFEALT", DistributionFatigueLife.self),
        alt("PSIHYPSECANTALT", DistributionHypSecant.self),
        alt("PSIINVNORMALALT", DistributionInverseGaussian.self),
        alt("PSICHISQUAREALT", DistributionChiSquared.self),
        alt("PSISTUDENTALT", DistributionStudentT.self),
        alt("PSIERFALT", DistributionErf.self),
        alt("PSIPERTALT", DistributionPert.self),
    ]

    /// Turns one (name, value) pair into a constraint.
    ///
    /// - Parameters:
    ///   - name: A probability, or the name of a moment or native parameter.
    ///   - value: What that quantity equals.
    /// - Returns: The constraint, or `nil` if the pair cannot be read.
    static func constraint(name: CellValue,
                           value: CellValue) -> ParameterConstraint<Double>? {
        guard let target = BuiltinRiskSolverFunctions.real(value) else { return nil }
        if let probability = BuiltinRiskSolverFunctions.real(name) {
            // A probability, and it must be one: 0 and 1 are the ends of the support,
            // where an unbounded distribution's quantile is infinite.
            guard probability > 0, probability < 1 else { return nil }
            return .quantile(p: probability, value: target)
        }
        guard case .text(let label) = name else { return nil }
        switch label.lowercased() {
        case "mean", "mu", "average": return .mean(target)
        case "var", "variance": return .variance(target)
        case "stdev", "stddev", "sd", "sigma", "standarddeviation":
            return .standardDeviation(target)
        default: return .parameter(name: label, value: target)
        }
    }

    /// Builds the binding for one `*Alt` name.
    ///
    /// - Parameters:
    ///   - name: The Excel-facing name.
    ///   - type: The BusinessMath distribution it parameterises.
    /// - Returns: The registered function.
    private static func alt<D: PercentileParameterisable & Sendable>(
        _ name: String, _ type: D.Type
    ) -> ExcelFunction where D.T == Double {
        ExcelFunction(name: name, minArgs: 2, maxArgs: nil) { context, values in
            if let error = values.first(where: { if case .error = $0 { return true }
                                                 else { return false } }) {
                return error
            }
            let parts = BuiltinRiskSolverFunctions.attached(context, values)
            let parameters = parts.parameters
            // Pairs, so an odd count is a call that cannot be read at all.
            guard parameters.count >= 2, parameters.count % 2 == 0 else { return .error(.value) }
            var constraints: [ParameterConstraint<Double>] = []
            for index in stride(from: 0, to: parameters.count, by: 2) {
                guard let one = constraint(name: parameters[index],
                                           value: parameters[index + 1]) else {
                    return .error(.value)
                }
                constraints.append(one)
            }
            guard let random = context.random else { return parts.baseCase ?? .error(.value) }
            do {
                let fitted = try D.fitting(constraints)
                return .number(fitted.quantile(random.nextUniform()))
            } catch {
                // No parameters satisfy the constraints — too few, too many, mutually
                // impossible, or a solve that would not converge. `#NUM!` is Excel's
                // answer for a computation with no result.
                return .error(.num)
            }
        }
    }
}
