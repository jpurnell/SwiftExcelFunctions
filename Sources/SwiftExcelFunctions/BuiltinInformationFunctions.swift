import Foundation
import SwiftExcelCore

/// What a value *is*, rather than what it computes to.
///
/// The predicates in ``BuiltinLogicFunctions`` — `ISERROR`, `ISBLANK`, `ISNUMBER` — arrived
/// with `IF`, because a formula that guards a division needs both halves. These are the rest
/// of the family, and they answer about a value's **kind**:
///
/// | Function | Answers |
/// |---|---|
/// | `ISEVEN`, `ISODD` | the parity of a number, truncated toward zero |
/// | `ISLOGICAL`, `ISNONTEXT` | which case the value is |
/// | `N` | the value as a number, by Excel's coercion table rather than by parsing |
/// | `TYPE` | the kind, as a number a formula can branch on |
/// | `ERROR.TYPE` | which error, as a number |
/// | `ISFORMULA` | whether a *cell* holds a formula — the only one here that reads the sheet |
///
/// ## What is deliberately absent
///
/// `INFO`, `SHEET`, `SHEETS`, `STOCKHISTORY` and `ISOMITTED` are not here, and each for its
/// own reason rather than for want of time. `INFO` reports the machine it runs on;
/// `STOCKHISTORY` calls a web service; `SHEET` and `SHEETS` need the workbook's sheet list,
/// which an evaluator handed a `CellValueProvider` does not have; `ISOMITTED` asks whether a
/// `LAMBDA` argument was supplied, and there is no `LAMBDA` yet. The coverage matrix records
/// all five as out of scope with those reasons.
public enum BuiltinInformationFunctions {

    /// All information functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        isEven, isOdd, isLogical, isNonText, nValue, typeOf, errorType, isFormula,
    ]

    // MARK: - Parity

    /// `ISEVEN(number)` — whether a number is even, ignoring any fraction.
    ///
    /// **Truncated toward zero, not rounded.** `ISEVEN(2.9)` is TRUE because the 2 is what
    /// counts. Rounding instead would make it FALSE, which is the sort of difference that
    /// only shows up on the rows where it matters.
    public static let isEven = ExcelFunction(name: "ISEVEN", minArgs: 1, maxArgs: 1) { args in
        parity(args) { $0 % 2 == 0 }
    }

    /// `ISODD(number)` — whether a number is odd, ignoring any fraction.
    public static let isOdd = ExcelFunction(name: "ISODD", minArgs: 1, maxArgs: 1) { args in
        parity(args) { $0 % 2 != 0 }
    }

    /// The shared body of the two parity tests.
    ///
    /// - Parameters:
    ///   - args: The call's arguments.
    ///   - test: What counts as a yes.
    /// - Returns: The answer, or `#VALUE!` for something that is not a number.
    private static func parity(
        _ args: [CellValue], _ test: (Int) -> Bool
    ) -> CellValue {
        if let error = firstError(args) { return error }
        // Text is `#VALUE!` even when it looks like a number: these ask about a *number*,
        // and Excel does not coerce for them as it does for arithmetic.
        guard case .number(let value) = args[0].resolved else {
            if case .blank = args[0].resolved { return .bool(test(0)) }
            return .error(.value)
        }
        guard value.isFinite, value.magnitude < 9.007e15 else { return .error(.num) }
        return .bool(test(Int(value.rounded(.towardZero))))
    }

    // MARK: - Which case is it

    /// `ISLOGICAL(value)` — true only for `TRUE` and `FALSE`.
    public static let isLogical = ExcelFunction(name: "ISLOGICAL", minArgs: 1, maxArgs: 1) { args in
        if case .bool = args[0].resolved { return .bool(true) }
        return .bool(false)
    }

    /// `ISNONTEXT(value)` — true for everything that is not text.
    ///
    /// **An empty cell is non-text**, which is the case that makes this more than
    /// `NOT(ISTEXT(…))` in a reader's head: both answer TRUE for a blank, and people expect
    /// one of them not to.
    public static let isNonText = ExcelFunction(name: "ISNONTEXT", minArgs: 1, maxArgs: 1) { args in
        if case .text = args[0].resolved { return .bool(false) }
        return .bool(true)
    }

    // MARK: - As a number

    /// `N(value)` — the value as a number, by Excel's own table.
    ///
    /// | Given | Answers |
    /// |---|---|
    /// | a number | itself |
    /// | a date | its serial |
    /// | `TRUE` / `FALSE` | 1 / 0 |
    /// | text | **0**, whatever the text says |
    /// | an error | the error |
    ///
    /// Text is 0 even when it reads as a number: `N("7")` is 0, not 7. That is not a
    /// coercion failure, it is the documented answer, and it is what separates `N` from
    /// `VALUE`.
    public static let nValue = ExcelFunction(name: "N", minArgs: 1, maxArgs: 1) { args in
        switch args[0].resolved {
        case .number(let number): return .number(number)
        case .bool(let flag): return .number(flag ? 1 : 0)
        case .date(let date): return .number(BuiltinDateTimeFunctions.dateToSerial(date))
        case .error(let error): return .error(error)
        default: return .number(0)
        }
    }

    /// `TYPE(value)` — the kind of a value, as a number to branch on.
    ///
    /// | Answer | Kind |
    /// |---|---|
    /// | 1 | number, including a date and an empty cell |
    /// | 2 | text |
    /// | 4 | logical |
    /// | 16 | error |
    /// | 64 | array |
    ///
    /// The gaps in the numbering are Excel's, and 8 — which would be "formula" — is
    /// documented as unused here: `TYPE` sees a value, and by then the formula has run.
    public static let typeOf = ExcelFunction(name: "TYPE", minArgs: 1, maxArgs: 1) { args in
        switch args[0].resolved {
        case .text: return .number(2)
        case .bool: return .number(4)
        case .error: return .number(16)
        case .array: return .number(64)
        default: return .number(1)
        }
    }

    /// `ERROR.TYPE(error_val)` — which error, as a number.
    ///
    /// | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
    /// |---|---|---|---|---|---|---|
    /// | `#NULL!` | `#DIV/0!` | `#VALUE!` | `#REF!` | `#NAME?` | `#NUM!` | `#N/A` |
    ///
    /// **Anything that is not an error is `#N/A`** — including a perfectly good number,
    /// which is the answer that surprises people. `IFERROR` wraps it for a reason.
    public static let errorType = ExcelFunction(
        name: "ERROR.TYPE", minArgs: 1, maxArgs: 1
    ) { args in
        guard case .error(let error) = args[0].resolved else { return .error(.na) }
        switch error {
        case .null: return .number(1)
        case .div0: return .number(2)
        case .value: return .number(3)
        case .ref: return .number(4)
        case .name: return .number(5)
        case .num: return .number(6)
        case .na: return .number(7)
        // **14 is from Microsoft's table, not from a conformance round**, which makes it the
        // one number in this function that has not been checked against Excel itself. The
        // published order continues 8 `#GETTING_DATA`, 9 `#SPILL!`, 10 `#CONNECT!`,
        // 11 `#BLOCKED!`, 12 `#UNKNOWN!`, 13 `#FIELD!`, 14 `#CALC!`; only the last is
        // representable here, and documentation has been wrong five times in this project's
        // life. Worth a row in the conformance workbook.
        case .calc: return .number(14)
        }
    }

    // MARK: - Reading the sheet

    /// `ISFORMULA(reference)` — whether a cell holds a formula.
    ///
    /// **The only function here that asks about a cell rather than a value.** Everything
    /// else is handed what the cell evaluated to; this needs the cell itself, because a
    /// formula returning 7 and a typed 7 are the same value and different cells.
    ///
    /// So it reads the argument tree the way `ISREF` and `COLUMN(B5)` do, and answers
    /// `#REF!` for an argument that is not a reference at all — Excel's answer, and the
    /// honest one, since the question does not apply.
    public static let isFormula = ExcelFunction(
        name: "ISFORMULA", minArgs: 1, maxArgs: 1, withoutContext: .error(.ref)
    ) { context, _ in
        guard let reference = context.referencedCell(at: 0) else { return .error(.ref) }
        guard let value = context.cells.value(at: reference) else { return .bool(false) }
        return .bool(value.isFormula)
    }

    // MARK: - Shared

    /// The first argument that is an error, propagated rather than absorbed.
    private static func firstError(_ args: [CellValue]) -> CellValue? {
        for argument in args {
            if case .error = argument { return argument }
        }
        return nil
    }
}
