import Foundation
import SwiftExcelCore

/// `AGGREGATE(function_num, options, …)` — nineteen aggregates behind one name.
///
/// `SUBTOTAL`'s larger sibling. Where `SUBTOTAL` offers eleven aggregates and one behaviour,
/// `AGGREGATE` offers nineteen and eight, and the eight are the reason it exists: it can be
/// told to ignore error values, which is how an author sums a column that contains `#N/A`
/// without wrapping every cell in `IFERROR`.
///
/// ## What it dispatches to, and why by name
///
/// Codes 1–11 are `SUBTOTAL`'s aggregates; 12–19 are `MEDIAN`, `MODE.SNGL`, `LARGE`, `SMALL`,
/// `PERCENTILE.INC`, `QUARTILE.INC`, `PERCENTILE.EXC` and `QUARTILE.EXC`. All eight already
/// exist and are tested, so this looks them up **in the registry** rather than referring to
/// them directly — which also means it inherits the registry's aliasing, and `PERCENTILE.INC`
/// finds `PERCENTILE` without this file knowing they are the same function.
///
/// ## What it cannot honour, stated rather than faked
///
/// Options 1, 3, 5 and 7 ask it to ignore **hidden rows**. Whether a row is hidden is a
/// property of the sheet, and this evaluator is handed a `CellValueProvider` that has no
/// opinion on visibility — the same limitation `SUBTOTAL` records for its 101–111 block.
/// Those options are accepted and the hidden-row part is not applied, because the alternative
/// is refusing a formula Excel computes. The error-ignoring half **is** applied, and it is
/// the half people actually write.
public enum BuiltinAggregate {

    /// `AGGREGATE` as the registry knows it — for its name and its arity.
    ///
    /// Intercepted by the evaluator, which has the registry this needs to dispatch through.
    public static let aggregate = ExcelFunction(
        name: "AGGREGATE", minArgs: 3, maxArgs: nil
    ) { _ in .error(.value) }

    /// Every function here, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [aggregate]

    /// The aggregate each code names, as the registry spells it.
    ///
    /// 1–11 are shared with `SUBTOTAL` and go through the same names; 12–19 are the ones
    /// `AGGREGATE` adds.
    static func functionName(for code: Int) -> String? {
        switch code {
        case 1: return "AVERAGE"
        case 2: return "COUNT"
        case 3: return "COUNTA"
        case 4: return "MAX"
        case 5: return "MIN"
        case 6: return "PRODUCT"
        case 7: return "STDEV.S"
        case 8: return "STDEV.P"
        case 9: return "SUM"
        case 10: return "VAR.S"
        case 11: return "VAR.P"
        case 12: return "MEDIAN"
        case 13: return "MODE.SNGL"
        case 14: return "LARGE"
        case 15: return "SMALL"
        case 16: return "PERCENTILE.INC"
        case 17: return "QUARTILE.INC"
        case 18: return "PERCENTILE.EXC"
        case 19: return "QUARTILE.EXC"
        default: return nil
        }
    }

    /// Whether a code's aggregate takes a `k` — the last argument, not part of the data.
    ///
    /// `LARGE`, `SMALL`, the percentiles and the quartiles all do. Reading it as data instead
    /// is the mistake that makes `AGGREGATE(14, 6, A1:A10, 2)` answer the second largest of
    /// eleven values rather than of ten.
    static func takesRank(_ code: Int) -> Bool { (14...19).contains(code) }

    /// Whether these options say to ignore error values.
    ///
    /// Excel's eight options are a pair of independent flags. 2, 3, 6 and 7 ignore errors;
    /// 1, 3, 5 and 7 ignore hidden rows, which this cannot see.
    static func ignoresErrors(_ options: Int) -> Bool {
        [2, 3, 6, 7].contains(options)
    }

    /// Evaluates a call.
    ///
    /// - Parameters:
    ///   - arguments: the evaluated arguments — code, options, then data and perhaps a rank.
    ///   - functions: the registry to dispatch through.
    /// - Returns: the aggregate's answer.
    static func evaluate(
        _ arguments: [CellValue], functions: FunctionRegistry
    ) -> CellValue {
        guard let codeValue = BuiltinMathPrimitives.real(arguments[0]),
              let optionsValue = BuiltinMathPrimitives.real(arguments[1]) else {
            return .error(.value)
        }
        // Truncated rather than rounded, which is Excel's rule for a function number.
        let code = Int(codeValue.rounded(.towardZero))
        let options = Int(optionsValue.rounded(.towardZero))
        guard let name = functionName(for: code), (0...7).contains(options),
              let function = functions.function(named: name) else {
            return .error(.value)
        }

        var data = Array(arguments.dropFirst(2))
        // The rank travels separately: it is an argument to the aggregate, not a value to
        // aggregate over, and flattening it into the data changes the answer.
        var rank: CellValue?
        if takesRank(code) {
            guard data.count >= 2 else { return .error(.value) }
            rank = data.removeLast()
        }

        if ignoresErrors(options) {
            data = data.map(withoutErrors)
            // An error in the data that survived the filter is the answer; one that did not
            // is gone. This is the whole point of the options.
        } else if let error = data.first(where: isError) {
            return error
        }

        do {
            return try function.evaluate(data + (rank.map { [$0] } ?? []))
        } catch {
            // A registry function throws only on an argument count it cannot serve, which
            // here means the code and the data disagree — `AGGREGATE(14, 6, A1:A10)` with no
            // rank, say. `#VALUE!` is what Excel answers for that.
            return .error(.value)
        }
    }

    // MARK: - Plumbing

    private static func isError(_ value: CellValue) -> Bool {
        if case .error = value { return true }
        return false
    }

    /// A value with error cells removed, reaching inside an array to do it.
    ///
    /// A range is one argument holding many cells, so dropping "the erroring arguments" is
    /// not enough — the errors are usually *inside* a range, which is exactly the shape
    /// `AGGREGATE(9, 6, A1:A100)` is written for.
    private static func withoutErrors(_ value: CellValue) -> CellValue {
        guard case .array(let matrix) = value else {
            return isError(value) ? .blank : value
        }
        let kept = matrix.elements.filter { !isError($0) }
        // Shape is not preserved, and does not need to be: every aggregate here flattens its
        // arguments, and a rectangle with holes in it has no shape to keep.
        guard let flattened = CellMatrix(elements: kept, rows: 1, columns: kept.count) else {
            return .array(matrix)
        }
        return .array(flattened)
    }
}
