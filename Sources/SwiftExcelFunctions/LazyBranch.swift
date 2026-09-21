import Foundation
import SwiftExcelCore

/// The functions that must not have all their arguments evaluated.
///
/// The evaluator evaluated every argument before dispatching — `EvaluationContext` said so in
/// as many words — which is right for `SUM` and wrong for `IF`. Excel evaluates only the
/// branch it takes.
///
/// For most formulas the difference is invisible, and `CHOOSE`'s own documentation used to
/// say why: an unchosen `1/0` becomes `#DIV/0!` and is discarded, so the answer is the same
/// either way. That reasoning holds for errors and for nothing else. An unchosen branch that
/// **recurses** does not become an error value; it runs.
///
/// Which makes this a prerequisite rather than a refinement. The way a spreadsheet author
/// writes a loop is
///
/// ```
/// LAMBDA(f, n, IF(n<=0, 0, 1 + f(f, n-1)))
/// ```
///
/// and under eager arguments the recursive arm is evaluated on the base case too, for ever.
/// No `LAMBDA` can work until this does, and the `LAMBDA` proposal did not have it.
///
/// ## What is here and what is not
///
/// `IF`, `IFERROR`, `IFNA`, `CHOOSE`, `IFS` and `SWITCH`. `AND`, `OR` and `XOR` are
/// deliberately absent: Excel does **not** short-circuit them — `XOR` cannot, since parity
/// needs every argument — and adding a rule Excel does not have is the same class of error as
/// missing one it does.
///
/// ## Where the semantics live
///
/// Not here. This file decides *what to evaluate*; the builtins decide *what the answer
/// means*, and they are asked rather than copied. `IF` and `CHOOSE` are handed sentinel
/// arguments and report back which one they would have returned; `IFERROR` and `IFNA` expose
/// the one predicate each that says whether the fallback is reached.
///
/// The alternative was to restate truthiness here — what a blank means, what text means, how
/// an error propagates — beside the version that already exists. Two copies of a rule are two
/// rules, and these have enough corners to drift.
enum LazyBranch {

    /// Evaluates a branching call, touching only the arguments it needs.
    ///
    /// - Parameters:
    ///   - canonicalName: the name as the registry knows it.
    ///   - arguments: the **unevaluated** argument trees.
    ///   - evaluate: evaluates one argument, in the caller's environment.
    /// - Returns: the result, or `nil` if this is not a branching call after all.
    /// - Throws: whatever evaluating a needed argument throws.
    static func evaluate(
        _ canonicalName: String,
        arguments: [FormulaAST],
        evaluating evaluate: (FormulaAST) throws -> CellValue
    ) throws -> CellValue? {
        switch canonicalName {
        case "IF":
            return try evaluateIf(arguments, evaluate)
        case "IFERROR":
            return try fallback(arguments, evaluate, when: BuiltinLogicFunctions.iferrorFallsBack)
        case "IFNA":
            return try fallback(arguments, evaluate, when: BuiltinLogicFunctions.ifnaFallsBack)
        case "CHOOSE":
            return try evaluateChoose(arguments, evaluate)
        case "IFS":
            return try evaluateIfs(arguments, evaluate)
        case "SWITCH":
            return try evaluateSwitch(arguments, evaluate)
        default:
            return nil
        }
    }

    // MARK: - One at a time

    /// Asks `IF` which branch it would take, then evaluates only that one.
    ///
    /// The decision is made by the builtin rather than restated here, and it is asked with
    /// **sentinel branches**: `IF(condition, 1, 0)`. The answer is `1`, `0`, or an Excel
    /// error, and each says exactly what to do next. Nothing else can come back, because the
    /// branches are values this function chose.
    ///
    /// The alternative was to reimplement truthiness — what a blank means, what text means,
    /// how an error propagates — beside the version that already exists. Two copies of a rule
    /// are two rules, and this one has enough corners to drift.
    private static func evaluateIf(
        _ arguments: [FormulaAST], _ evaluate: (FormulaAST) throws -> CellValue
    ) throws -> CellValue {
        let condition = try evaluate(arguments[0])

        // **An array condition asks the question once per element**, and both branches are
        // needed — there is no single branch to take. See `acrossTheCondition`.
        if case .array(let matrix) = condition {
            return try acrossTheCondition(matrix, arguments, evaluate)
        }

        let decision = try BuiltinLogicFunctions.ifFunc.evaluate(
            [condition, .number(1), .number(0)])

        guard case .number(let taken) = decision else {
            // Not a condition at all — text, an array, an error. `IF` has already turned that
            // into the Excel error it becomes, and neither branch is evaluated.
            return decision
        }
        guard taken == 1 else {
            // Excel's omitted third argument is FALSE, and evaluating nothing is the point.
            return arguments.count > 2 ? try evaluate(arguments[2]) : .bool(false)
        }
        return try evaluate(arguments[1])
    }

    /// `IF` over an array condition: one answer per element, both branches evaluated.
    ///
    /// ## Why this is not the lazy path
    ///
    /// The whole point of the scalar path is that `IF(A1=0, "", 1/A1)` never divides by zero.
    /// With an array condition there is no single branch to skip — some rows take one and some
    /// the other — so Excel evaluates both and picks element by element, and so does this. The
    /// scalar path above is untouched and stays lazy.
    ///
    /// ## The shape
    ///
    /// The condition's. Each branch is read at the same position, and a branch that **runs
    /// out** contributes `#N/A` rather than a blank or a repeat — Excel's answer for an array
    /// too short for the one beside it, and the honest one: there is no value there.
    ///
    /// A branch that is not an array is a single value used for every element, which is how
    /// the `0` in `IF(years = wanted, quarters, 0)` reaches every row that fails the test.
    ///
    /// Each element's answer comes from the builtin, asked with the element's own branches, so
    /// truthiness is decided in exactly one place — text, blanks and errors included.
    ///
    /// - Parameters:
    ///   - condition: The evaluated condition, whose shape the answer takes.
    ///   - arguments: The call's unevaluated arguments.
    ///   - evaluate: Evaluates one argument in the caller's environment.
    /// - Returns: An array of the condition's shape.
    private static func acrossTheCondition(
        _ condition: CellMatrix, _ arguments: [FormulaAST],
        _ evaluate: (FormulaAST) throws -> CellValue
    ) throws -> CellValue {
        let whenTrue = try evaluate(arguments[1])
        let whenFalse = arguments.count > 2 ? try evaluate(arguments[2]) : CellValue.bool(false)

        var answers: [CellValue] = []
        answers.reserveCapacity(condition.elements.count)
        for (index, test) in condition.elements.enumerated() {
            let taken = element(of: whenTrue, at: index)
            let untaken = element(of: whenFalse, at: index)
            answers.append(try BuiltinLogicFunctions.ifFunc.evaluate([test, taken, untaken]))
        }
        guard let shaped = CellMatrix(elements: answers, rows: condition.rows,
                                      columns: condition.columns) else {
            return .error(.value)
        }
        return .array(shaped)
    }

    /// One element of a branch, or the whole branch when it is a single value.
    ///
    /// `#N/A` past the end of a shorter array: Excel's answer where one side of an
    /// element-wise operation runs out, and not a blank, which would read as a real empty cell.
    private static func element(of branch: CellValue, at index: Int) -> CellValue {
        guard case .array(let matrix) = branch else { return branch }
        guard index < matrix.elements.count else { return .error(.na) }
        return matrix.elements[index]
    }

    /// `IFS(condition, result, …)` — the first true condition's result.
    ///
    /// Stops at the first match: a later condition is not examined and its result is not
    /// evaluated, which is most of why an author writes `IFS` instead of nested `IF`s.
    ///
    /// No match is `#N/A`, which is Excel's answer and not `#VALUE!` — "none of these applied"
    /// is a different statement from "this was malformed", and `IFS` can say both.
    private static func evaluateIfs(
        _ arguments: [FormulaAST], _ evaluate: (FormulaAST) throws -> CellValue
    ) throws -> CellValue {
        guard arguments.count % 2 == 0 else { return .error(.value) }

        for pair in stride(from: 0, to: arguments.count, by: 2) {
            let decision = try BuiltinLogicFunctions.ifFunc.evaluate(
                [try evaluate(arguments[pair]), .number(1), .number(0)])
            guard case .number(let taken) = decision else { return decision }
            if taken == 1 { return try evaluate(arguments[pair + 1]) }
        }
        return .error(.na)
    }

    /// `SWITCH(expression, case, result, …, [default])` — the result whose case matches.
    ///
    /// A trailing odd argument is the default. With no default and no match the answer is
    /// `#N/A`, for the same reason as `IFS`.
    private static func evaluateSwitch(
        _ arguments: [FormulaAST], _ evaluate: (FormulaAST) throws -> CellValue
    ) throws -> CellValue {
        let subject = try evaluate(arguments[0])
        if case .error = subject { return subject }

        let pairs = arguments.dropFirst()
        var index = pairs.startIndex
        while pairs.index(after: index) < pairs.endIndex {
            let candidate = try evaluate(pairs[index])
            if case .error = candidate { return candidate }
            // Compared through the evaluator's own equality, so text matches without regard to
            // case exactly as `=` does everywhere else in a formula.
            if FormulaEvaluator.compareValues(subject, candidate) == .orderedSame {
                return try evaluate(pairs[pairs.index(after: index)])
            }
            index = pairs.index(index, offsetBy: 2)
        }
        // One argument left over is the default; none left is no match at all.
        guard index < pairs.endIndex else { return .error(.na) }
        return try evaluate(pairs[index])
    }

    private static func fallback(
        _ arguments: [FormulaAST],
        _ evaluate: (FormulaAST) throws -> CellValue,
        when reachesForIt: (CellValue) -> Bool
    ) throws -> CellValue {
        let value = try evaluate(arguments[0])
        guard reachesForIt(value) else { return value }
        return try evaluate(arguments[1])
    }

    /// Asks `CHOOSE` which argument it would pick, then evaluates only that one.
    ///
    /// The same sentinel trick as ``evaluateIf(_:_:)``: `CHOOSE` is offered the positions
    /// themselves as its values, so what comes back is either the position to evaluate or the
    /// error the index deserves.
    private static func evaluateChoose(
        _ arguments: [FormulaAST], _ evaluate: (FormulaAST) throws -> CellValue
    ) throws -> CellValue {
        let positions = (1..<arguments.count).map { CellValue.number(Double($0)) }
        let decision = try BuiltinNavigationFunctions.choose.evaluate(
            [try evaluate(arguments[0])] + positions)

        guard case .number(let chosen) = decision else { return decision }
        return try evaluate(arguments[Int(chosen)])
    }
}
