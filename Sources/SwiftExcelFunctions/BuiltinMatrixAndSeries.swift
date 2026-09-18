import Foundation
import SwiftExcelCore
import BusinessMath

/// The `math` and `datetime` rows that were bindable and unbound.
///
/// `FACT`, `COMBIN`, `SUMXMY2`, `SEQUENCE`, `MMULT`, `MINVERSE` and `DAYS360`. Each was
/// recorded in the coverage matrix as *bindable* — known, unimplemented, with the mathematics
/// already somewhere — and stayed that way because a status is not a binding.
public enum BuiltinMatrixAndSeries {

    /// Everything here, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        fact, combin, sumXMY2, sequence, mmult, minverse, days360
    ]

    // MARK: - Counting

    /// `FACT(number)` — the factorial.
    ///
    /// **Computed in `Double`, not `Int`.** BusinessMath's `factorial` returns an `Int` and
    /// overflows at 21!; Excel answers up to `FACT(170)` ≈ 7.26e306 and gives `#NUM!` at 171.
    /// Binding to the `Int` form would have been a crash or a wrong answer for every argument
    /// above 20, which is most of the range the function has.
    public static let fact = ExcelFunction(name: "FACT", minArgs: 1, maxArgs: 1) { args in
        if let error = args.first(where: isError) { return error }
        guard let n = whole(args[0]) else { return .error(.value) }
        guard n >= 0 else { return .error(.num) }
        var product = 1.0
        // Bounded by `n`, and `finite` catches the overflow past 170 as `#NUM!`.
        for factor in stride(from: 2, through: n, by: 1) { product *= Double(factor) }
        return finite(product)
    }

    /// `COMBIN(number, number_chosen)` — combinations **without** repetition.
    ///
    /// The sibling of `COMBINA`, which counts with repetition. `COMBIN(4, 3)` is 4 where
    /// `COMBINA(4, 3)` is 20.
    public static let combin = ExcelFunction(name: "COMBIN", minArgs: 2, maxArgs: 2) { args in
        if let error = args.first(where: isError) { return error }
        guard let n = whole(args[0]), let k = whole(args[1]) else { return .error(.value) }
        guard n >= 0, k >= 0, k <= n else { return .error(.num) }
        // Term by term, so the factorials never exist: `COMBIN(1000, 500)` overflows every
        // intermediate in the direct form and is an ordinary number in this one.
        let take = Swift.min(k, n - k)
        var result = 1.0
        for step in 0..<take {
            let divisor = Double(step + 1)
            guard divisor > 0 else { return .error(.num) }
            result = result * Double(n - step) / divisor
        }
        return finite(result.rounded())
    }

    /// `SUMXMY2(array_x, array_y)` — `Σ (xᵢ − yᵢ)²`.
    ///
    /// The third of the paired sums, beside `SUMX2MY2` and `SUMX2PY2`.
    public static let sumXMY2 = ExcelFunction(name: "SUMXMY2", minArgs: 2, maxArgs: 2) { args in
        if let error = args.first(where: isError) { return error }
        let xs = flatten([args[0]]), ys = flatten([args[1]])
        guard xs.count == ys.count, !xs.isEmpty else { return .error(.na) }

        var total = 0.0
        for (x, y) in zip(xs, ys) {
            guard let a = real(x), let b = real(y) else { continue }
            total += (a - b) * (a - b)
        }
        return finite(total)
    }

    // MARK: - Building

    /// `SEQUENCE(rows, [columns], [start], [step])` — a rectangle of evenly spaced numbers.
    ///
    /// Worth its own note: the conformance workbook's `REDUCE` control writes
    /// `REDUCE(0, SEQUENCE(8192), …)`, so until now this package could not evaluate the very
    /// formula it uses to ask Excel a question.
    public static let sequence = ExcelFunction(
        name: "SEQUENCE", minArgs: 1, maxArgs: 4
    ) { args in
        if let error = args.first(where: isError) { return error }
        guard let rows = whole(args[0]) else { return .error(.value) }
        let columns = args.count > 1 ? (whole(args[1]) ?? 1) : 1
        let start = args.count > 2 ? (real(args[2]) ?? 1) : 1
        let step = args.count > 3 ? (real(args[3]) ?? 1) : 1
        guard rows >= 1, columns >= 1 else { return .error(.value) }

        var elements: [CellValue] = []
        elements.reserveCapacity(rows * columns)
        for index in 0..<(rows * columns) {
            elements.append(.number(start + Double(index) * step))
        }
        return shaped(elements, rows: rows, columns: columns)
    }

    // MARK: - Matrices

    /// `MMULT(array1, array2)` — the matrix product.
    ///
    /// The inner dimensions must agree, and Excel answers `#VALUE!` rather than broadcasting
    /// when they do not — there is no sensible product of mismatched shapes.
    public static let mmult = ExcelFunction(name: "MMULT", minArgs: 2, maxArgs: 2) { args in
        if let error = args.first(where: isError) { return error }
        let left = matrix(of: args[0]), right = matrix(of: args[1])
        guard left.columns == right.rows else { return .error(.value) }

        var elements: [CellValue] = []
        elements.reserveCapacity(left.rows * right.columns)
        for row in 0..<left.rows {
            for column in 0..<right.columns {
                var total = 0.0
                for inner in 0..<left.columns {
                    guard let a = real(left[row, inner]), let b = real(right[inner, column])
                    else { return .error(.value) }
                    total += a * b
                }
                guard total.isFinite else { return .error(.num) }
                elements.append(.number(total))
            }
        }
        return shaped(elements, rows: left.rows, columns: right.columns)
    }

    /// `MINVERSE(array)` — the inverse of a square matrix.
    ///
    /// By Gauss–Jordan with partial pivoting, the same reasoning as `MDETERM`: the pivot
    /// search is what keeps the division stable, and a pivot that cannot be found *is* the
    /// determination that the matrix is singular. Excel answers `#VALUE!` for that, not a
    /// matrix of very large numbers.
    public static let minverse = ExcelFunction(name: "MINVERSE", minArgs: 1, maxArgs: 1) { args in
        if let error = args.first(where: isError) { return error }
        let source = matrix(of: args[0])
        guard source.rows == source.columns, source.rows >= 1 else { return .error(.value) }

        let size = source.rows
        var a = [Double](repeating: 0, count: size * size)
        var inverse = [Double](repeating: 0, count: size * size)
        for row in 0..<size {
            inverse[row * size + row] = 1
            for column in 0..<size {
                guard let value = real(source[row, column]) else { return .error(.value) }
                a[row * size + column] = value
            }
        }

        for step in 0..<size {
            var pivot = step
            for row in (step + 1)..<size
            where Swift.abs(a[row * size + step]) > Swift.abs(a[pivot * size + step]) {
                pivot = row
            }
            let head = a[pivot * size + step]
            guard Swift.abs(head) > 0 else { return .error(.value) }
            if pivot != step {
                for column in 0..<size {
                    a.swapAt(step * size + column, pivot * size + column)
                    inverse.swapAt(step * size + column, pivot * size + column)
                }
            }
            let divisor = a[step * size + step]
            guard divisor != 0 else { return .error(.value) }
            for column in 0..<size {
                a[step * size + column] /= divisor
                inverse[step * size + column] /= divisor
            }
            for row in 0..<size where row != step {
                let factor = a[row * size + step]
                guard factor != 0 else { continue }
                for column in 0..<size {
                    a[row * size + column] -= factor * a[step * size + column]
                    inverse[row * size + column] -= factor * inverse[step * size + column]
                }
            }
        }
        guard inverse.allSatisfy(\.isFinite) else { return .error(.num) }
        return shaped(inverse.map { CellValue.number($0) }, rows: size, columns: size)
    }

    // MARK: - Dates

    /// `DAYS360(start_date, end_date, [method])` — days on a 360-day year.
    ///
    /// Two methods, and they differ only at a month end. **US (the default, `FALSE`)** moves a
    /// start date on the 31st to the 30th, and an end date on the 31st to the 1st of the next
    /// month *unless* the start was already pulled back. **European (`TRUE`)** simply clamps
    /// both to 30. The US rule is the one people get wrong, because it is conditional.
    public static let days360 = ExcelFunction(name: "DAYS360", minArgs: 2, maxArgs: 3) { args in
        if let error = args.first(where: isError) { return error }
        guard let start = date(args[0]), let end = date(args[1]) else { return .error(.value) }
        let european = args.count > 2 && (real(args[2]).map { $0 != 0 } ?? false)

        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return .error(.value) }
        calendar.timeZone = utc
        let from = calendar.dateComponents([.year, .month, .day], from: start)
        let to = calendar.dateComponents([.year, .month, .day], from: end)
        guard let y1 = from.year, let m1 = from.month, var d1 = from.day,
              let y2 = to.year, let m2 = to.month, var d2 = to.day else {
            return .error(.value)
        }

        var endMonth = m2
        if european {
            d1 = Swift.min(d1, 30)
            d2 = Swift.min(d2, 30)
        } else {
            if d1 == 31 { d1 = 30 }
            if d2 == 31 {
                if d1 == 30 {
                    d2 = 30
                } else {
                    // The 1st of the *next* month — and the month has to move with it. Left
                    // at the old month this loses thirty days, which is how
                    // `DAYS360("1/1/2008","12/31/2008")` answered 330 instead of 360.
                    d2 = 1
                    endMonth += 1
                }
            }
        }
        let days = (y2 - y1) * 360 + (endMonth - m1) * 30 + (d2 - d1)
        return .number(Double(days))
    }

    // MARK: - Plumbing

    private static func isError(_ value: CellValue) -> Bool {
        if case .error = value { return true }
        return false
    }

    private static func real(_ value: CellValue) -> Double? {
        BuiltinMathPrimitives.real(value)
    }

    private static func whole(_ value: CellValue) -> Int? {
        guard let number = real(value) else { return nil }
        return Int(exactly: number.rounded(.towardZero))
    }

    private static func date(_ value: CellValue) -> Date? {
        guard let serial = real(value), serial >= 0 else { return nil }
        return BuiltinDateTimeFunctions.serialToDate(Int(serial))
    }

    private static func finite(_ value: Double) -> CellValue {
        value.isFinite ? .number(value) : .error(.num)
    }

    private static func matrix(of value: CellValue) -> CellMatrix {
        if case .array(let matrix) = value { return matrix }
        return CellMatrix(single: value)
    }

    private static func shaped(_ elements: [CellValue], rows: Int, columns: Int) -> CellValue {
        guard let matrix = CellMatrix(elements: elements, rows: rows, columns: columns) else {
            return .error(.value)
        }
        return .array(matrix)
    }

    private static func flatten(_ args: [CellValue]) -> [CellValue] {
        var out: [CellValue] = []
        for value in args {
            if case .array(let matrix) = value {
                out.append(contentsOf: flatten(matrix.elements))
            } else {
                out.append(value)
            }
        }
        return out
    }
}
