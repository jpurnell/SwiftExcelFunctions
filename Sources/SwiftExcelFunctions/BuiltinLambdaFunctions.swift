import Foundation
import SwiftExcelCore

/// The forms that introduce names.
///
/// `LET` binds a value to a name so a formula can say it once; `LAMBDA` binds arguments to
/// parameters. Neither can be an ordinary registered function, for the same reason: an
/// ordinary function has its arguments evaluated before it is called, and these forms exist
/// precisely to decide what an argument *means* before it is evaluated. `LET(a, 2, a*3)`
/// evaluated eagerly asks the workbook for a name called `a` and gets `#NAME?`.
///
/// So the evaluator reaches them first, as it does the branching forms. What they share with
/// `LazyBranch` is the position; what they add is scope.
enum BuiltinLambdaFunctions {

    /// `LET` as the registry knows it — for its name, its arity, and nothing else.
    ///
    /// The evaluator intercepts every `LET` before its arguments are evaluated, so this
    /// closure runs only if something calls it directly. By then the argument *trees* are
    /// gone and only their values remain, which is exactly the information `LET` needs and
    /// cannot recover. It refuses rather than guessing: returning the last argument would be
    /// right whenever no binding was actually used and quietly wrong the rest of the time.
    static let letFunc = ExcelFunction(name: "LET", minArgs: 3, maxArgs: nil) { _ in
        .error(.value)
    }

    static let all: [ExcelFunction] = [letFunc]

    /// Evaluates `LET(name, value, …, calculation)`.
    ///
    /// - Parameters:
    ///   - arguments: the **unevaluated** argument trees.
    ///   - env: the environment the whole form is evaluated in.
    ///   - evaluate: evaluates one tree in a given environment.
    /// - Returns: the calculation's value, or `#VALUE!` if the form is malformed.
    static func evaluateLet(
        _ arguments: [FormulaAST],
        in env: EvaluationEnvironment,
        evaluating evaluate: (FormulaAST, EvaluationEnvironment) throws -> CellValue
    ) throws -> CellValue {
        // Pairs, then a calculation, so the count is always odd. Excel refuses an even one and
        // there is nothing sensible to do with a trailing half-pair.
        guard arguments.count >= 3, arguments.count % 2 == 1 else { return .error(.value) }

        var scope = env
        for pair in stride(from: 0, to: arguments.count - 1, by: 2) {
            guard case .namedRange(let name) = arguments[pair] else {
                // The thing being named has to be a name. `LET(1, 2, 3)` is not a typo this
                // package can interpret.
                return .error(.value)
            }
            // Evaluated in the scope *before* this binding, which is what stops a name from
            // seeing itself: `LET(a, a+1, a)` asks for an `a` that does not exist yet and gets
            // `#NAME?`, where the alternative is a loop.
            //
            // Evaluated **once**, here, rather than at each mention. Saying an expensive
            // subexpression one time is most of why an author reaches for `LET`.
            let value = try evaluate(arguments[pair + 1], scope)
            scope = scope.binding([name: value])
        }
        return try evaluate(arguments[arguments.count - 1], scope)
    }
}
