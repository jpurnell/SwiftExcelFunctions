import Foundation
import SwiftExcelCore

/// What a formula declares about its role in a simulation.
///
/// A workbook that used Risk Solver carries two kinds of marking. Some cells *draw* —
/// they call a `Psi*` distribution and take a different value on every trial. Some cells
/// *report* — they carry `PsiOutput()` and the run collects statistics about them. A cell
/// can do both, and most cells do neither.
///
/// Nothing here evaluates anything. The recognizer reads structure, which is why it works
/// on a workbook with no add-in present, no seed, and no simulation engine attached.
public struct RecognizedFormula: Sendable, Equatable {

    /// How many `PsiOutput()` markers this formula carries.
    ///
    /// A count rather than a flag because more than one is a modelling mistake worth
    /// being able to report, not something to silently collapse.
    public let outputMarkers: Int

    /// Every distribution call in the formula, in the order they appear.
    public let distributions: [DistributionCall]

    /// Whether the run should collect statistics for this cell.
    public var isOutput: Bool { outputMarkers > 0 }

    /// Whether this formula's value changes from trial to trial.
    public var isUncertain: Bool { !distributions.isEmpty }

    /// Creates a recognition result.
    ///
    /// - Parameters:
    ///   - outputMarkers: how many `PsiOutput()` calls the formula carries.
    ///   - distributions: every distribution call found, in the order they appear.
    public init(outputMarkers: Int, distributions: [DistributionCall]) {
        self.outputMarkers = outputMarkers
        self.distributions = distributions
    }
}

/// One `Psi*` distribution call, with its property functions separated from its parameters.
///
/// ## Why a call and not a cell
///
/// `=PsiNormal(0, 1) + PsiNormal(0, 1)` is **two independent draws**, and a simulation has
/// to hand them two different uniforms. Treating the cell as the unit of uncertainty would
/// collapse them into one and silently correlate two variables the workbook declared
/// independent — a wrong answer that looks entirely reasonable. So the call site is the
/// unit, and a cell may contain several.
public struct DistributionCall: Sendable, Equatable {

    /// The distribution's canonical name, prefix stripped and upper-cased — `PSINORMAL`.
    public let function: String

    /// The positional parameters, in the order written, with property functions removed.
    ///
    /// Order is preserved exactly and never normalised. `PsiTriangular` and `PsiPert` are
    /// published as `(a, c, b)` — deliberately not alphabetical, and positionally that
    /// *is* `(min, likely, max)`. Reordering to make the letters ascend would produce a
    /// plausible, wrong distribution.
    public let parameters: [FormulaAST]

    /// The `PsiBaseCase(v)` argument, if present — what the cell shows when nothing is
    /// simulating.
    public let baseCase: FormulaAST?

    /// The `PsiName("…")` argument, if present. A label for reports and charts.
    public let label: String?

    /// Property functions that were present and are not modelled here.
    ///
    /// Named rather than dropped, and never left among ``parameters``. A `PsiTruncate`
    /// counted as a parameter would shift every parameter after it, and the distribution
    /// would still compute — returning a number that is wrong in a way nothing reports.
    /// Listing them lets a caller refuse a model it cannot faithfully simulate instead of
    /// simulating it incorrectly.
    public let unhandledProperties: [String]

    /// Creates a distribution call.
    ///
    /// - Parameters:
    ///   - function: the canonical distribution name, prefix stripped and upper-cased.
    ///   - parameters: the positional parameters, in the order written.
    ///   - baseCase: the `PsiBaseCase(v)` argument, if one was supplied.
    ///   - label: the `PsiName("…")` argument, if one was supplied.
    ///   - unhandledProperties: property functions present but not modelled.
    public init(
        function: String,
        parameters: [FormulaAST],
        baseCase: FormulaAST?,
        label: String?,
        unhandledProperties: [String]
    ) {
        self.function = function
        self.parameters = parameters
        self.baseCase = baseCase
        self.label = label
        self.unhandledProperties = unhandledProperties
    }
}

/// Reads a formula and reports what role it plays in a simulation.
///
/// The distribution names are taken from the registry rather than listed here, so a
/// distribution added to ``BuiltinRiskSolverFunctions`` is recognised without anyone
/// remembering to update a second list.
///
/// ```swift
/// import SwiftExcelCore
///
/// // The tree a parser hands over for `=SUM(J2:J11)+_xll.PsiOutput()`.
/// let ast = FormulaAST.add(
///     .function("SUM", [.cellRange(CellRange(from: "J2", to: "J11"))]),
///     .function("_xll.PsiOutput", [])
/// )
///
/// let found = PsiRecognizer().recognize(ast)
/// found.isOutput      // true  — the run collects statistics for this cell
/// found.isUncertain   // false — it reports a result, it does not draw one
/// ```
///
/// The example builds the tree directly because parsing a formula *string* lives in
/// SwiftXLSX, which this module does not depend on. The recognizer takes a
/// `FormulaAST` and never a string, which is what lets it run against a
/// tree from any source — a file, a test, or a formula built in code.
public struct PsiRecognizer: Sendable {

    /// Canonical names of every registered `Psi*` distribution.
    private let distributionNames: Set<String>

    /// The marker that makes a cell a simulation output.
    private static let outputMarker = "PSIOUTPUT"

    /// Names that mark or annotate rather than draw, and so are never distributions.
    private static let markers: Set<String> = ["PSIOUTPUT", "PSIBASECASE", "PSINAME"]

    /// - Parameter functions: the Risk Solver functions to read. Defaults to
    ///   ``BuiltinRiskSolverFunctions/all``, with the three markers removed.
    ///
    ///   Taking the whole group rather than naming its constituent lists is deliberate.
    ///   The distributions arrive in batches — `distributions`, `furtherDistributions`,
    ///   `completingDistributions` — and a recognizer that named them individually would
    ///   silently stop recognising each new batch until someone remembered this file.
    ///   Subtracting the markers by name is the one thing that must stay in step, and it
    ///   is three names rather than a hundred.
    public init(functions: [ExcelFunction] = BuiltinRiskSolverFunctions.all) {
        self.distributionNames = Set(functions.map { FunctionRegistry.canonical($0.name) })
            .subtracting(Self.markers)
    }

    /// Reads a formula's simulation role.
    ///
    /// - Parameter ast: the parsed formula.
    /// - Returns: the markers and distribution calls found anywhere in the tree.
    public func recognize(_ ast: FormulaAST) -> RecognizedFormula {
        var markers = 0
        var calls: [DistributionCall] = []
        walk(ast, markers: &markers, calls: &calls)
        return RecognizedFormula(outputMarkers: markers, distributions: calls)
    }

    // MARK: - Traversal

    /// Walks the whole tree, because both markings are subexpressions.
    ///
    /// The corpus writes `PsiOutput` onto a real formula — `=SUM(J2:J11)+_xll.PsiOutput()`,
    /// 167 times across 41 workbooks — so inspecting the root would find almost none of
    /// them. A distribution nests just as freely: `IF(A1>0, PsiNormal(0,1), 0)`.
    private func walk(_ ast: FormulaAST, markers: inout Int, calls: inout [DistributionCall]) {
        switch ast {
        case .function(let rawName, let arguments):
            let name = FunctionRegistry.canonical(rawName)

            if name == Self.outputMarker {
                markers += 1
            } else if distributionNames.contains(name) {
                calls.append(Self.call(named: name, arguments: arguments))
            }

            // Descend regardless. A distribution's own arguments can contain another
            // distribution — `PsiNormal(PsiUniform(0, 1), 10)` is legal and is two draws.
            for argument in arguments {
                walk(argument, markers: &markers, calls: &calls)
            }

        case .add(let lhs, let rhs), .subtract(let lhs, let rhs),
             .multiply(let lhs, let rhs), .divide(let lhs, let rhs),
             .power(let lhs, let rhs), .concatenate(let lhs, let rhs),
             .equal(let lhs, let rhs), .notEqual(let lhs, let rhs),
             .greaterThan(let lhs, let rhs), .lessThan(let lhs, let rhs),
             .greaterOrEqual(let lhs, let rhs), .lessOrEqual(let lhs, let rhs):
            walk(lhs, markers: &markers, calls: &calls)
            walk(rhs, markers: &markers, calls: &calls)

        case .negate(let operand):
            walk(operand, markers: &markers, calls: &calls)

        case .cellRef, .cellRange, .sheetRef, .namedRange,
             .number, .text, .bool, .error, .missing:
            break
        }
    }

    // MARK: - Argument partitioning

    /// Splits a distribution's arguments into parameters and property functions.
    ///
    /// Property functions are arguments rather than syntax, so they sit in the same list
    /// as the parameters and are told apart only by being `Psi*` calls themselves. That is
    /// the rule applied here: **any nested `Psi*` call in the argument list is a property,
    /// never a parameter.** Anything else is positional.
    private static func call(named name: String, arguments: [FormulaAST]) -> DistributionCall {
        var parameters: [FormulaAST] = []
        var baseCase: FormulaAST?
        var label: String?
        var unhandled: [String] = []

        for argument in arguments {
            guard case .function(let rawInner, let innerArguments) = argument else {
                parameters.append(argument)
                continue
            }

            let inner = FunctionRegistry.canonical(rawInner)
            guard inner.hasPrefix("PSI") else {
                // An ordinary function computing a parameter — `PsiNormal(AVERAGE(A1:A9), 10)`.
                parameters.append(argument)
                continue
            }

            switch inner {
            case "PSIBASECASE":
                baseCase = innerArguments.first
            case "PSINAME":
                if case .text(let text) = innerArguments.first {
                    label = text
                }
            default:
                unhandled.append(inner)
            }
        }

        return DistributionCall(
            function: name,
            parameters: parameters,
            baseCase: baseCase,
            label: label,
            unhandledProperties: unhandled
        )
    }
}
