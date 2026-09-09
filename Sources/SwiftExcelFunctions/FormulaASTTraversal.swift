import Foundation
import SwiftExcelCore

/// Which binary operator a node is.
///
/// `FormulaAST` gives each of the twelve its own case, which is right for a tree that has
/// to be pattern-matched exactly. It is wrong for every consumer that treats them
/// uniformly — and all of them do, because `a + b` and `a > b` differ only in the function
/// applied to the operands.
public enum BinaryKind: Sendable, Equatable {
    case add, subtract, multiply, divide, power, concatenate
    case equal, notEqual, greaterThan, lessThan, greaterOrEqual, lessOrEqual

    /// Whether this operator produces a truth value rather than a number.
    public var isComparison: Bool {
        switch self {
        case .equal, .notEqual, .greaterThan, .lessThan, .greaterOrEqual, .lessOrEqual:
            return true
        case .add, .subtract, .multiply, .divide, .power, .concatenate:
            return false
        }
    }
}

/// Structural access to a formula tree.
///
/// ## Why this exists
///
/// Four things in this package walked `FormulaAST` and each enumerated its cases itself:
/// the recognizer's function visitor, the trial loop's precedent extractor, and the
/// lowering pass's audit and builder. Twelve binary operators written out four times, and
/// the cost is not the lines — it is that adding a node kind to `FormulaAST` means finding
/// every one of them, and the compiler only helps where the switch is exhaustive.
///
/// So the shape is described once, here, and everything else asks.
public extension FormulaAST {

    /// This node's immediate children, whatever kind it is.
    ///
    /// The single place that knows a `.function`'s children are its arguments and a
    /// `.negate`'s is its operand. A traversal built on this cannot miss a case, because
    /// there is only one switch to keep exhaustive.
    var children: [FormulaAST] {
        switch self {
        case .add(let l, let r), .subtract(let l, let r), .multiply(let l, let r),
             .divide(let l, let r), .power(let l, let r), .concatenate(let l, let r),
             .equal(let l, let r), .notEqual(let l, let r),
             .greaterThan(let l, let r), .lessThan(let l, let r),
             .greaterOrEqual(let l, let r), .lessOrEqual(let l, let r):
            return [l, r]
        case .negate(let operand):
            return [operand]
        case .function(_, let arguments):
            return arguments
        case .cellRef, .cellRange, .sheetRef, .namedRange,
             .number, .text, .bool, .error, .missing:
            return []
        }
    }

    /// The operator and operands, if this node is a binary operation.
    ///
    /// Collapses twelve cases into one for every consumer that applies a function to two
    /// operands — which is all of them.
    var binary: (kind: BinaryKind, lhs: FormulaAST, rhs: FormulaAST)? {
        switch self {
        case .add(let l, let r): return (.add, l, r)
        case .subtract(let l, let r): return (.subtract, l, r)
        case .multiply(let l, let r): return (.multiply, l, r)
        case .divide(let l, let r): return (.divide, l, r)
        case .power(let l, let r): return (.power, l, r)
        case .concatenate(let l, let r): return (.concatenate, l, r)
        case .equal(let l, let r): return (.equal, l, r)
        case .notEqual(let l, let r): return (.notEqual, l, r)
        case .greaterThan(let l, let r): return (.greaterThan, l, r)
        case .lessThan(let l, let r): return (.lessThan, l, r)
        case .greaterOrEqual(let l, let r): return (.greaterOrEqual, l, r)
        case .lessOrEqual(let l, let r): return (.lessOrEqual, l, r)
        default: return nil
        }
    }

    /// Visits this node and every node beneath it, parents first.
    ///
    /// Bounded by ``FormulaEvaluator/maxDepth``, and by it rather than by a second number:
    /// a formula the evaluator would refuse as too deep is one nothing here should recurse
    /// into either, and two limits that could disagree would mean a tree one walker
    /// entered and another rejected.
    ///
    /// - Parameters:
    ///   - maxDepth: how deep to descend. Defaults to the evaluator's own bound.
    ///   - visit: called for each node, the receiver first.
    func walk(maxDepth: Int = FormulaEvaluator.maxDepth, _ visit: (FormulaAST) -> Void) {
        guard maxDepth > 0 else { return }
        visit(self)
        for child in children { child.walk(maxDepth: maxDepth - 1, visit) }
    }
}
