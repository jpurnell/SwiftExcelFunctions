import Foundation
import SwiftExcelCore

/// What one cell's evaluation was worth against Excel's own answer.
///
/// Every formula cell in a saved workbook carries the value Excel last computed
/// for it. That value is the strongest oracle this project has: it was produced by
/// the specification itself, on files nobody wrote for us.
enum OracleOutcome: Equatable {

    /// We produced Excel's value, within tolerance.
    case agreed

    /// We produced a different value.
    case differed(ours: CellValue, excel: CellValue)

    /// We answered an error where Excel had a value.
    ///
    /// Kept apart from ``differed`` because it usually means something is missing
    /// rather than wrong — an unimplemented function, a reference that did not
    /// resolve — and those are fixed differently.
    case refused(ExcelError)

    /// Evaluation threw.
    case threw(String)

    /// Excel recorded an error and so did we, and they match.
    ///
    /// This is agreement. A model full of `#DIV/0!` is a model whose author left it
    /// that way, and reproducing that faithfully is the job.
    case agreedOnError(ExcelError)

    /// We could not compare: no cached value, or a formula we do not parse.
    case notComparable(String)
}

/// One cell's verdict, with enough context to act on it.
struct OracleFinding {
    let sheet: String
    let cell: CellRef
    let formula: FormulaAST
    let outcome: OracleOutcome

    /// The function names the formula mentions, at any depth.
    ///
    /// What turns a list of cells into a list of things to fix: twenty failures in
    /// one function is one defect, twenty failures in twenty functions is twenty.
    var functions: [String] { OracleFinding.functionNames(in: formula) }

    /// Every function named anywhere in a formula.
    ///
    /// - Parameter ast: The formula.
    /// - Returns: The names, in no particular order, with duplicates.
    static func functionNames(in ast: FormulaAST) -> [String] {
        var found: [String] = []
        var stack = [ast]
        while let node = stack.popLast() {
            switch node {
            case .function(let name, let arguments):
                found.append(name.uppercased())
                stack.append(contentsOf: arguments)
            case .add(let lhs, let rhs), .subtract(let lhs, let rhs),
                 .multiply(let lhs, let rhs), .divide(let lhs, let rhs),
                 .power(let lhs, let rhs), .concatenate(let lhs, let rhs),
                 .equal(let lhs, let rhs), .notEqual(let lhs, let rhs),
                 .greaterThan(let lhs, let rhs), .lessThan(let lhs, let rhs),
                 .greaterOrEqual(let lhs, let rhs), .lessOrEqual(let lhs, let rhs):
                stack.append(lhs)
                stack.append(rhs)
            case .negate(let operand):
                stack.append(operand)
            case .cellRef, .cellRange, .sheetRef, .namedRange,
                 .number, .text, .bool, .error, .missing:
                break
            }
        }
        return found
    }
}

/// What a run of the oracle found.
struct OracleReport {

    private(set) var findings: [OracleFinding] = []

    mutating func record(_ finding: OracleFinding) {
        findings.append(finding)
    }

    mutating func absorb(_ other: OracleReport) {
        findings.append(contentsOf: other.findings)
    }

    /// Cells where we and Excel both produced a value we could compare.
    var comparable: Int {
        findings.filter {
            switch $0.outcome {
            case .notComparable: return false
            default: return true
            }
        }.count
    }

    var agreed: Int {
        findings.filter {
            switch $0.outcome {
            case .agreed, .agreedOnError: return true
            default: return false
            }
        }.count
    }

    /// Agreement, the number this whole apparatus exists to move.
    ///
    /// It will never reach 1. Volatile functions are excluded rather than
    /// compared, and some cached values were written by a version of Excel making
    /// choices we may never match. A number that goes up is the goal; a number that
    /// reaches 100% would mean the harness had stopped looking.
    var agreement: Double {
        comparable == 0 ? 1 : Double(agreed) / Double(comparable)
    }

    /// Disagreements grouped by the functions their formulas call.
    ///
    /// A formula calling three functions counts once against each: the harness
    /// cannot say which one is at fault, and pretending otherwise would hide the
    /// other two.
    var byFunction: [String: Int] {
        var counts: [String: Int] = [:]
        for finding in findings {
            switch finding.outcome {
            case .agreed, .agreedOnError, .notComparable:
                continue
            default:
                for name in Set(finding.functions) {
                    counts[name, default: 0] += 1
                }
            }
        }
        return counts
    }

    /// Counts by outcome kind, for the summary line.
    var tally: (agreed: Int, agreedOnError: Int, differed: Int,
                refused: Int, threw: Int, notComparable: Int) {
        var result = (0, 0, 0, 0, 0, 0)
        for finding in findings {
            switch finding.outcome {
            case .agreed: result.0 += 1
            case .agreedOnError: result.1 += 1
            case .differed: result.2 += 1
            case .refused: result.3 += 1
            case .threw: result.4 += 1
            case .notComparable: result.5 += 1
            }
        }
        return result
    }
}

/// How close is close enough.
enum OracleTolerance {

    /// Relative agreement, with an absolute floor.
    ///
    /// Excel stores about fifteen significant digits and a `Double` carries about
    /// seventeen, so a relative epsilon of 1e-9 is far looser than rounding noise
    /// and far tighter than any real disagreement — those are whole units apart,
    /// not billionths.
    ///
    /// The floor exists for two cases a relative test cannot handle: comparing
    /// something to exactly zero, where the relative difference is undefined, and
    /// the numerical dust real models leave behind. The corpus contains a cached
    /// `-1.1224406979409424e-239`, which is a zero that took a long route; calling
    /// it different from zero would be true and useless.
    static let relative = 1e-9
    static let floor = 1e-12

    /// The band inside which an iterative solver's answer counts as agreement.
    ///
    /// Microsoft on `XIRR`: "Excel uses an iterative technique… cycles through the
    /// calculation until the result is accurate within 0.000001 percent" — 1e-8
    /// relative. Observation says that figure is Excel's ambition rather than its
    /// guarantee.
    ///
    /// A corpus cell, `Long Acre Team 2013 / Valuation!E17`, settles it. Excel
    /// caches 0.13088350892066958; we answer 0.13088350377871114, 3.9e-8 apart —
    /// four times Excel's stated accuracy. Evaluating `XNPV` at both rates says
    /// which is the root:
    ///
    /// ```
    /// XNPV at ours  =  2.18e-11
    /// XNPV at Excel = -0.00152
    /// ```
    ///
    /// So the difference is Excel's stopping point, not our error, and no amount of
    /// work here would close it — matching would mean reproducing a convergence rule
    /// Microsoft has not published. This is ADR-001's second case: Excel doing
    /// something documented, matched within the accuracy it documents.
    ///
    /// 1e-6 rather than the stated 1e-8, because the stated figure demonstrably does
    /// not hold. It is still four orders tighter than any real disagreement, which
    /// would show up in the second or third significant figure rather than the
    /// eighth.
    static let iterative = 1e-6

    /// Functions whose answer is found by iterating rather than by evaluating.
    static let iterativeFunctions: Set<String> = ["XIRR", "IRR", "MIRR", "RATE", "YIELD"]

    /// Whether two numbers agree.
    ///
    /// - Parameters:
    ///   - ours: What we computed.
    ///   - excel: What Excel recorded.
    /// - Returns: `true` when the difference is below both thresholds' allowance.
    static func agree(_ ours: Double, _ excel: Double, tolerance: Double? = nil) -> Bool {
        if ours == excel { return true }
        guard ours.isFinite, excel.isFinite else { return false }
        let difference = abs(ours - excel)
        if difference <= floor { return true }
        let scale = Swift.max(abs(ours), abs(excel))
        return difference <= (tolerance ?? relative) * scale
    }

    /// Whether two cell values agree, across the coercions Excel treats as equal.
    ///
    /// Excel caches a boolean as `1`/`0` and does not record a blank at all, so
    /// `blank` and `number(0)` are the same answer written two ways. Text is
    /// compared exactly: a spreadsheet that says "Hybrid" and one that says
    /// "" are not the same spreadsheet.
    ///
    /// - Parameters:
    ///   - ours: What we computed.
    ///   - excel: What Excel recorded.
    /// - Returns: `true` when they are the same answer.
    static func agree(_ ours: CellValue, _ excel: CellValue, tolerance: Double? = nil) -> Bool {
        switch (ours, excel) {
        case (.number(let a), .number(let b)):
            return agree(a, b, tolerance: tolerance)
        case (.array(let matrix), _):
            // One formula filling a span evaluates once, and each cell shows its own
            // element. Only the span's top-left cell carries the formula, so that is
            // the element to compare — the rest of the rectangle lives in other
            // cells and is checked when those cells are.
            guard let first = matrix.elements.first else { return false }
            return agree(first, excel, tolerance: tolerance)
        case (.text(let a), .text(let b)):
            return a == b
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.error(let a), .error(let b)):
            return a == b
        case (.bool(let flag), .number(let value)), (.number(let value), .bool(let flag)):
            return flag == (value != 0)
        case (.blank, .number(let value)), (.number(let value), .blank):
            return value == 0
        case (.blank, .text(let text)), (.text(let text), .blank):
            return text.isEmpty
        case (.date(let a), .date(let b)):
            return a == b
        default:
            return false
        }
    }
}
