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

    static let all: [ExcelFunction] = [letFunc, lambdaFunc, isOmittedFunc]

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

    /// The scope a lambda body runs in.
    ///
    /// - Parameters:
    ///   - parameters: the names it declares.
    ///   - arguments: the evaluated arguments, which may be fewer than the parameters.
    ///   - omittedAt: positions the caller wrote as skipped — `f(1,,3)`.
    ///   - closing: the bindings the body sees, which for a lambda *value* is what it captured
    ///     and for a named lambda is the caller's scope.
    ///   - env: the caller's environment.
    /// - Returns: the scope, or `nil` if there are more arguments than parameters.
    private static func scope(
        parameters: [String], arguments: [CellValue], omittedAt: Set<Int>,
        closing: [String: CellValue], in env: EvaluationEnvironment
    ) throws -> EvaluationEnvironment? {
        // **Exact, and the count is of argument *positions*.**
        //
        // Round 6 asked Excel and the answer reversed an assumption made here. A two-parameter
        // lambda called with one argument is `#VALUE!` — not an omission — and one called with
        // three is `#VALUE!` too. The control in between answered 2, so those readings mean
        // what they say.
        //
        // The assumption had been that a trailing argument may be left out, reasoned from
        // Microsoft's own `ISOMITTED` pattern being unusable otherwise. That is documentation,
        // and it was wrong, which is the sixth time in this project's life.
        //
        // Counting positions rather than values is what keeps `ISOMITTED` meaningful, and
        // round 7 confirmed it: `f(7,)` answers 1 where `f(7)` is `#VALUE!`. Two positions with
        // one left blank is a different thing from one position. The same held for a *named*
        // lambda, so there is no second rule — arity is arity however the lambda is reached.
        guard arguments.count == parameters.count else { return nil }

        var values: [String: CellValue] = [:]
        var absent: Set<String> = []
        for (position, name) in parameters.enumerated() {
            let supplied = position < arguments.count && !omittedAt.contains(position)
            // An omitted parameter reads as blank where it is *used* — Excel's omitted
            // argument behaves as empty — and is recorded as absent separately, because a
            // blank is also an ordinary thing to pass. See `EvaluationEnvironment.omitted`.
            values[name] = supplied ? arguments[position] : .blank
            if !supplied { absent.insert(name) }
        }

        // The body starts its nesting budget over and carries the recursion budget. Excel's 65
        // is a fact about one expression's text, and a lambda's body is its own expression.
        var budgets = try env.depth.recursing()
        budgets.calls = 0

        return env.withDepth(budgets).withBindings(closing)
            .binding(values).omitting(absent)
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
        arguments: [CellValue], omittedAt: Set<Int>,
        in env: EvaluationEnvironment,
        evaluating evaluate: (FormulaAST, EvaluationEnvironment) throws -> CellValue
    ) throws -> CellValue {
        // The captured frame *replaces* the caller's bindings rather than adding to them. A
        // lambda sees where it was written, not where it was called — which is what makes
        // `LET(x, 100, LET(f, LET(x, 1, LAMBDA(y, x+y)), f(0)))` answer 1 and not 100.
        guard let scope = try scope(
            parameters: parameters, arguments: arguments, omittedAt: omittedAt,
            closing: captured, in: env) else { return .error(.value) }
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
        arguments: [CellValue], omittedAt: Set<Int>,
        in env: EvaluationEnvironment,
        evaluating evaluate: (FormulaAST, EvaluationEnvironment) throws -> CellValue
    ) throws -> CellValue {
        // A named lambda closes over the workbook, which is what the caller's environment
        // already reaches. Its own bindings are not inherited — a `LET` around the call site
        // must not leak into a body that never saw it.
        guard let scope = try scope(
            parameters: lambda.parameters, arguments: arguments, omittedAt: omittedAt,
            closing: [:], in: env) else { return .error(.value) }
        return try evaluate(lambda.body, scope)
    }

    // MARK: - ISOMITTED

    /// `ISOMITTED(parameter)` — whether the current call left that argument out.
    ///
    /// A special form, because the answer is about the *name* rather than about the value it
    /// stands for. Evaluated first, an omitted parameter is a blank and indistinguishable from
    /// a blank somebody passed.
    ///
    /// Anything that is not a name is `FALSE`: it is a value, so it was supplied. Excel has no
    /// syntax for an optional parameter — the `[y]` in Microsoft's documentation is a
    /// convention for readers — so this is the only way an author writes one.
    ///
    /// - Parameters:
    ///   - arguments: the unevaluated arguments; `ISOMITTED` takes exactly one.
    ///   - env: the environment, which knows what the current call left out.
    static func isOmitted(_ arguments: [FormulaAST], in env: EvaluationEnvironment) -> CellValue {
        guard let first = arguments.first else { return .error(.value) }
        guard case .namedRange(let name) = first else { return .bool(false) }
        return .bool(env.wasOmitted(name))
    }

    /// `ISOMITTED` as the registry knows it — for its name and its arity.
    static let isOmittedFunc = ExcelFunction(name: "ISOMITTED", minArgs: 1, maxArgs: 1) { _ in
        // Reached only if something calls it with a value in hand, by which point the name is
        // gone and the question cannot be answered. A value was supplied; that is all it knows.
        .bool(false)
    }
}
