@testable import SwiftExcelFunctions
import SwiftExcelCore

extension Double {
    /// Whether this value is within `tolerance` of `expected`.
    ///
    /// The comparison a computed result calls for. Written as a predicate rather than an
    /// assertion helper so that the `#expect` sits in the test body, where both a reader and
    /// the quality gate look for it — and so that Swift Testing, which expands a member call
    /// into its receiver and arguments, reports the actual value when it fails.
    func isClose(to expected: Double, within tolerance: Double) -> Bool {
        abs(self - expected) <= tolerance
    }
}

extension CellValue {
    /// Whether this is a number within `tolerance` of `expected`.
    ///
    /// Anything that is not a number — text, an error, a blank — is not close to anything,
    /// so a function that answers the wrong *kind* of value fails here rather than slipping
    /// past a numeric comparison.
    func isNumber(_ expected: Double, within tolerance: Double = 1e-10) -> Bool {
        guard case .number(let value) = self else { return false }
        return value.isClose(to: expected, within: tolerance)
    }
}

extension CellValue {
    /// Whether this is a number, of any value.
    ///
    /// For tests whose claim is the *kind* of answer — a function answered rather than
    /// refused — and not its size.
    var isNumeric: Bool {
        if case .number = self { return true }
        return false
    }

    /// Whether this is a logical value.
    var isBool: Bool {
        if case .bool = self { return true }
        return false
    }

    /// Whether this is an array, of any shape.
    var isArray: Bool {
        if case .array = self { return true }
        return false
    }
}

extension Array where Element == Double {
    /// Whether the two arrays have the same count and each element is within `tolerance`
    /// of its partner.
    func isElementwiseClose(to expected: [Double], within tolerance: Double) -> Bool {
        count == expected.count
            && zip(self, expected).allSatisfy { $0.isClose(to: $1, within: tolerance) }
    }
}

extension FunctionRegistry {
    /// The uppercased name of the function a lookup of `name` resolves to, or `nil` when
    /// nothing answers to it.
    ///
    /// A stronger claim than "something answers": a lookup that resolved `_xlfn.SUMIFS` to
    /// the wrong function would pass a `!= nil` check and fail this one.
    func resolvedName(_ name: String) -> String? {
        function(named: name)?.name.uppercased()
    }
}
