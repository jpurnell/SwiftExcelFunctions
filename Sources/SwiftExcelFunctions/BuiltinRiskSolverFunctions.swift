import Foundation
import SwiftExcelCore

/// Risk Solver: the parts of it a spreadsheet carries that are not simulation.
///
/// Frontline's Risk Solver adds a `Psi*` family to Excel, and a workbook that used
/// it carries those calls whether or not the add-in is present. Most of them are
/// Monte Carlo — `PsiTriangular(min, likely, max)` draws a sample, `PsiMean(cell)`
/// reports a statistic of a completed run — and none of that can be reproduced
/// from a saved file, because no seed is published and the cached value is one
/// draw from one run. Measured across the corpus: of 90 cells carrying an explicit
/// `PsiBaseCase(X)`, 71 cache the value at X and 19 cache a draw, and nothing in
/// the file says which. Those belong to BusinessMath's distribution work, judged
/// against the published specification rather than against a cached number.
///
/// This group is the remainder: calls that are *markers* rather than mathematics.
/// They can be answered exactly, they need no simulation, and answering them is
/// what lets a workbook that used Risk Solver be read without it.
///
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinRiskSolverFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinRiskSolverFunctions {

    /// All Risk Solver functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [psiOutput, psiBaseCase, psiName] + distributions

    /// `PsiOutput()` — marks a cell as a simulation result.
    ///
    /// It takes no arguments and contributes nothing to the arithmetic, which is
    /// why it is written *onto* a real formula rather than instead of one. The
    /// corpus writes it exactly that way, 167 times across 41 workbooks — more
    /// workbooks than any other member of the family:
    ///
    /// ```
    /// =SUM(J2:J11)+_xll.PsiOutput()
    /// =SUMPRODUCT(D22:D26,E22:E26)+_xll.PsiOutput()
    /// ```
    ///
    /// So it answers `0`, and the cell evaluates to the formula it was attached to.
    /// The marking itself is information — this cell is one the model reports on —
    /// and recovering *that* is a job for the recognizer, which can see the call in
    /// the AST. Evaluation only has to stop it getting in the way.
    public static let psiOutput = ExcelFunction(name: "PSIOUTPUT", minArgs: 0, maxArgs: 0) { _ in
        .number(0)
    }

    // MARK: - Property functions

    // A Psi distribution takes its parameters and then, optionally, *property*
    // functions describing it: `PsiTriangular(min, likely, max, PsiBaseCase(v))`,
    // `PsiDiscrete(values, probs, PsiName("Aggressive Launch"))`. They are arguments
    // rather than syntax, so the evaluator evaluates them whatever the enclosing
    // distribution does with them — and an unregistered one is `#NAME?`, which error
    // propagation then carries outward and fails the whole distribution.
    //
    // So they are implemented ahead of the distributions, and they are structural
    // rather than stochastic: neither draws anything.
    //
    // A distribution cannot recognise one by its *value* — `PsiBaseCase(5)` and a
    // literal `5` both arrive as `.number(5)` — so it has to read
    // `EvaluationContext.arguments` and look at the unevaluated form. That is why
    // every Psi distribution will be a context function, and it is the decision
    // worth knowing before twenty-seven of them are written.

    /// `PsiBaseCase(value)` — what a distribution shows when nothing is simulating.
    ///
    /// Evaluates to the value it was given. Risk Solver displays it in place of a
    /// draw while a simulation is idle, which the corpus bears out: of 90 cells
    /// carrying one, 71 cache the value at that reference and 19 cache a sample, the
    /// difference being whether the workbook was saved mid-run.
    public static let psiBaseCase = ExcelFunction(
        name: "PSIBASECASE", minArgs: 1, maxArgs: 1
    ) { args in
        args[0].resolved
    }

    /// `PsiName(text)` — a label for a distribution, for reports and charts.
    ///
    /// Carries no numeric meaning, and evaluates to the label so that a formula
    /// mentioning it is not poisoned by an error. What the label is *for* is a
    /// reporting concern; recovering it belongs to the recognizer, which can see the
    /// call in the AST.
    public static let psiName = ExcelFunction(name: "PSINAME", minArgs: 1, maxArgs: 1) { args in
        args[0].resolved
    }
}
