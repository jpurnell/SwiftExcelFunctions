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

    /// `LAMBDA` as the registry knows it — for its name and its arity.
    ///
    /// Intercepted by the evaluator like ``letFunc``, and for the same reason: the parameters
    /// are names to be *bound*, and evaluating them would ask the workbook for names that
    /// exist only inside this lambda.
    static let lambdaFunc = ExcelFunction(name: "LAMBDA", minArgs: 0, maxArgs: nil) { _ in
        .error(.calc)
    }

    static let all: [ExcelFunction] = [letFunc, lambdaFunc]

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

    // MARK: - LAMBDA

    /// A `LAMBDA` taken apart: the names it declares, and what it computes.
    struct Lambda {
        let parameters: [String]
        let body: FormulaAST

        /// Reads a tree as a `LAMBDA`, or decides it is not one.
        ///
        /// `LAMBDA(p1, …, pn, body)` — every argument but the last is a parameter, and a
        /// parameter is spelled as a name because that is what it is syntactically. A
        /// `LAMBDA` whose parameter list holds something that is not a name is malformed.
        ///
        /// The `_xlfn.` prefix is stripped by ``FunctionRegistry/canonical(_:)``, the same way
        /// it is for any other function newer than the file format. The `_xlpm.` prefix on the
        /// parameters is **not** touched: it is part of the name, it matches itself wherever
        /// the body mentions it, and depending on its presence is the mistake §12 of the
        /// proposal warns about.
        init?(_ ast: FormulaAST) {
            guard case .function(let name, let arguments) = ast,
                  FunctionRegistry.canonical(name) == "LAMBDA",
                  let body = arguments.last else { return nil }

            var declared: [String] = []
            for parameter in arguments.dropLast() {
                guard case .namedRange(let spelling) = parameter else { return nil }
                declared.append(spelling)
            }
            self.parameters = declared
            self.body = body
        }
    }

    /// Turns a `LAMBDA(…)` that nobody called into the value it is.
    ///
    /// A lambda is not a number, and a cell holding one shows `#CALC!`. But it *is* a value:
    /// it can be bound by a `LET`, chosen by an `IF`, or returned by another lambda, and each
    /// of those is legal Excel that no side table of unevaluated trees can express.
    ///
    /// **The environment's bindings travel with it.** That is the closure, and it is the whole
    /// reason the case carries a third payload: `LAMBDA(x, LAMBDA(y, x+y))` returns a function
    /// that outlives the scope which gave `x` its value. Capturing the bindings at the point
    /// the lambda is *made* is what makes the scope lexical.
    ///
    /// - Parameters:
    ///   - arguments: the `LAMBDA` call's unevaluated arguments — parameters, then a body.
    ///   - env: the environment the lambda is written in, whose names it closes over.
    /// - Returns: the lambda as a value, or `#CALC!` if the form is malformed.
    static func lambdaValue(
        _ arguments: [FormulaAST], in env: EvaluationEnvironment
    ) -> CellValue {
        guard let lambda = Lambda(.function("LAMBDA", arguments)) else { return .error(.calc) }
        return .lambda(parameters: lambda.parameters, body: lambda.body,
                       captured: env.bindings)
    }

    /// Calls a lambda held as a value.
    ///
    /// - Parameters:
    ///   - parameters: the names it declares.
    ///   - body: what it computes.
    ///   - captured: the scope it closed over, which the body sees *instead of* the caller's.
    ///   - arguments: the evaluated arguments.
    ///   - env: the caller's environment, for its counters and its collaborators.
    ///   - evaluate: evaluates the body.
    static func callValue(
        parameters: [String], body: FormulaAST, captured: [String: CellValue],
        arguments: [CellValue],
        in env: EvaluationEnvironment,
        evaluating evaluate: (FormulaAST, EvaluationEnvironment) throws -> CellValue
    ) throws -> CellValue {
        guard arguments.count == parameters.count else { return .error(.value) }

        var budgets = try env.depth.recursing()
        budgets.calls = 0

        // The captured frame *replaces* the caller's bindings rather than adding to them. A
        // lambda sees where it was written, not where it was called — which is what makes
        // `LET(x, 100, LET(f, LET(x, 1, LAMBDA(y, x+y)), f(0)))` answer 1 and not 100.
        let scope = env.withDepth(budgets).withBindings(captured).binding(
            Dictionary(zip(parameters, arguments), uniquingKeysWith: { _, last in last }))
        return try evaluate(body, scope)
    }

    /// Calls a lambda with arguments already evaluated in the caller's scope.
    ///
    /// The arguments are values, not trees, because a lambda is not a branching form: Excel
    /// evaluates what is passed, once, at the call. Laziness lives in `IF`, which is where the
    /// recursion actually terminates.
    ///
    /// - Parameters:
    ///   - lambda: the parameters and body.
    ///   - arguments: the evaluated arguments, in order.
    ///   - env: the environment at the call site.
    ///   - evaluate: evaluates the body in a given environment.
    /// - Returns: the body's value, or `#VALUE!` if the arity does not match.
    /// - Throws: ``FormulaEvaluator/EvaluationError/recursionDepthExceeded`` past 4,096.
    static func call(
        _ lambda: Lambda,
        arguments: [CellValue],
        in env: EvaluationEnvironment,
        evaluating evaluate: (FormulaAST, EvaluationEnvironment) throws -> CellValue
    ) throws -> CellValue {
        // Excel refuses a call whose argument count does not match the declaration. There is
        // no defaulting and no dropping — `ISOMITTED` is how an author says "may be absent",
        // and it is not implemented yet.
        guard arguments.count == lambda.parameters.count else { return .error(.value) }

        // **The body starts its nesting budget over, and the recursion budget carries.**
        //
        // Excel's 65 is a fact about one expression's *text* — it is enforced at file load, by
        // looking at the formula, before anything is evaluated. A lambda's body is its own
        // expression and is checked on its own; a call to a lambda is not nesting inside the
        // caller any more than `=myName` is.
        //
        // Counting them together is not a nicety: a recursion 4,090 deep would exhaust a
        // 65-call budget at the 33rd level. The conformance round that put 4,090 levels of
        // recursion inside 60 nested `IF`s and found the answer unmoved is exactly the
        // measurement that says these are two budgets, and this is where that becomes code.
        var budgets = try env.depth.recursing()
        budgets.calls = 0

        let scope = env.withDepth(budgets).binding(Dictionary(
            zip(lambda.parameters, arguments), uniquingKeysWith: { _, last in last }))
        return try evaluate(lambda.body, scope)
    }
}
