import Foundation
import SwiftExcelCore

/// Counting, series, Roman numerals and the two matrix builders.
///
/// The rest of the `math` bucket once the rounding family is out of it. Nothing here is
/// difficult; what each one needs is its edge cases stated, because that is where Excel's
/// answers stop being the obvious ones.
public enum BuiltinMathCounting {

    /// Every function here, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        combina, factDouble, multinomial, seriesSum,
        sumX2MY2, sumX2PY2, roman, arabic, munit, mdeterm, percentOf, randArray
    ]

    /// `RANDARRAY([rows], [columns], [min], [max], [whole_number])` — a rectangle of draws.
    ///
    /// Every argument is optional and the defaults are a single draw in `[0, 1)`, which makes
    /// `RANDARRAY()` exactly `RAND()`.
    ///
    /// Like `RAND`, it takes its numbers from the injected ``RandomSource`` and answers
    /// `#VALUE!` when there is none — a workbook audit that reached for system entropy would
    /// give a different answer every run, and this package's whole business is being
    /// checkable. `whole_number` rounds the *interval*, not the draw, so both bounds stay
    /// reachable.
    public static let randArray = ExcelFunction(
        name: "RANDARRAY", minArgs: 0, maxArgs: 5
    ) { context, args in
        if let error = args.first(where: isError) { return error }
        guard let random = context.random else { return .error(.value) }

        let rows = args.count > 0 ? (whole(args[0]) ?? 1) : 1
        let columns = args.count > 1 ? (whole(args[1]) ?? 1) : 1
        guard rows >= 1, columns >= 1 else { return .error(.value) }

        let low = args.count > 2 ? (BuiltinMathPrimitives.real(args[2]) ?? 0) : 0
        let high = args.count > 3 ? (BuiltinMathPrimitives.real(args[3]) ?? 1) : 1
        guard low <= high else { return .error(.value) }
        let wholeNumbers = args.count > 4
            && (BuiltinMathPrimitives.real(args[4]).map { $0 != 0 } ?? false)

        var elements: [CellValue] = []
        elements.reserveCapacity(rows * columns)
        for _ in 0..<(rows * columns) {
            let draw = random.nextUniform()
            if wholeNumbers {
                // Both bounds inclusive, the same way `RANDBETWEEN` reaches its top: the
                // half-open draw scaled across `high - low + 1` values.
                let span = high.rounded(.down) - low.rounded(.up) + 1
                elements.append(.number(low.rounded(.up) + (draw * span).rounded(.down)))
            } else {
                elements.append(.number(low + draw * (high - low)))
            }
        }
        guard let matrix = CellMatrix(elements: elements, rows: rows, columns: columns) else {
            return .error(.value)
        }
        return .array(matrix)
    }

    // MARK: - Counting

    /// `COMBINA(number, number_chosen)` — combinations **with** repetition.
    ///
    /// `C(n+k-1, k)`, not `C(n, k)`: choosing 3 from 4 with repetition is 20 where `COMBIN`
    /// says 4. `COMBINA(0, 0)` is 1 — there is exactly one way to choose nothing — and that
    /// is the case the general formula cannot reach.
    public static let combina = ExcelFunction(name: "COMBINA", minArgs: 2, maxArgs: 2) { args in
        if let error = args.first(where: isError) { return error }
        guard let n = whole(args[0]), let k = whole(args[1]) else { return .error(.value) }
        guard n >= 0, k >= 0, !(n == 0 && k > 0) else { return .error(.num) }
        guard n > 0 || k > 0 else { return .number(1) }
        return finite(choose(n + k - 1, k))
    }

    /// `FACTDOUBLE(number)` — `n!!`, every other factor down to 1 or 2.
    ///
    /// `FACTDOUBLE(6)` is 48 — 6 × 4 × 2 — not 720. Both `0!!` and `(-1)!!` are 1 by
    /// convention, and Excel follows it; anything below −1 is `#NUM!`.
    public static let factDouble = ExcelFunction(
        name: "FACTDOUBLE", minArgs: 1, maxArgs: 1
    ) { args in
        if let error = args.first(where: isError) { return error }
        guard let n = whole(args[0]) else { return .error(.value) }
        guard n >= -1 else { return .error(.num) }
        var product = 1.0
        var factor = n
        // Bounded: `factor` falls by two each pass and stops at or below 1.
        while factor > 1 {
            product *= Double(factor)
            factor -= 2
        }
        return finite(product)
    }

    /// `MULTINOMIAL(number1, …)` — `(Σn)! / Πn!`, the ways to partition a set.
    ///
    /// The factorials overflow long before the answer does, so this multiplies the binomial
    /// coefficients instead: the count of ways to take the first group from everything, times
    /// the ways to take the second from what is left, and so on. Same number, and it survives
    /// arguments that the direct form cannot.
    public static let multinomial = ExcelFunction(
        name: "MULTINOMIAL", minArgs: 1, maxArgs: nil
    ) { args in
        if let error = args.first(where: isError) { return error }
        var counts: [Int] = []
        for value in flatten(args) {
            guard let n = whole(value) else { return .error(.value) }
            guard n >= 0 else { return .error(.num) }
            counts.append(n)
        }
        guard !counts.isEmpty else { return .error(.value) }

        var remaining = 0
        var product = 1.0
        for count in counts {
            remaining += count
            product *= choose(remaining, count)
        }
        return finite(product)
    }

    // MARK: - Series and sums of squares

    /// `SERIESSUM(x, n, m, coefficients)` — `Σ aᵢ · x^(n + i·m)`.
    ///
    /// A power series with a stride. The coefficients arrive as a range, and their *order* is
    /// the exponents' order, which is why they are flattened rather than sorted.
    public static let seriesSum = ExcelFunction(
        name: "SERIESSUM", minArgs: 4, maxArgs: 4
    ) { args in
        if let error = args.first(where: isError) { return error }
        guard let x = BuiltinMathPrimitives.real(args[0]),
              let n = BuiltinMathPrimitives.real(args[1]),
              let m = BuiltinMathPrimitives.real(args[2]) else { return .error(.value) }

        var total = 0.0
        for (index, value) in flatten([args[3]]).enumerated() {
            guard let coefficient = BuiltinMathPrimitives.real(value) else {
                return .error(.value)
            }
            total += coefficient * Foundation.pow(x, n + Double(index) * m)
        }
        return finite(total)
    }

    /// `SUMX2MY2(array_x, array_y)` — `Σ (xᵢ² − yᵢ²)`.
    public static let sumX2MY2 = pairwise("SUMX2MY2") { $0 * $0 - $1 * $1 }

    /// `SUMX2PY2(array_x, array_y)` — `Σ (xᵢ² + yᵢ²)`.
    public static let sumX2PY2 = pairwise("SUMX2PY2") { $0 * $0 + $1 * $1 }

    // MARK: - Roman numerals

    /// `ROMAN(number, [form])` — a number as Roman numerals.
    ///
    /// Form 0 is classic; 1 through 4 are progressively more concise, and `TRUE`/`FALSE` are
    /// accepted for 0 and 4. Only the classic form is produced here, and the concise forms
    /// **are not silently approximated** — they answer `#VALUE!`, because `ROMAN(499, 2)` is
    /// `XDIX` and returning `CDXCIX` would be a different string that looks right.
    ///
    /// Excel's range is 1 to 3,999; 0 is the empty string and negatives are `#VALUE!`.
    public static let roman = ExcelFunction(name: "ROMAN", minArgs: 1, maxArgs: 2) { args in
        if let error = args.first(where: isError) { return error }
        guard let number = whole(args[0]) else { return .error(.value) }
        guard number >= 0, number <= 3_999 else { return .error(.value) }

        if args.count > 1 {
            guard let form = BuiltinMathPrimitives.real(args[1]) else { return .error(.value) }
            // A concise form this cannot produce is refused rather than answered with the
            // classic one. See the note above: a wrong string that looks right is worse.
            guard form == 0 else { return .error(.value) }
        }
        guard number > 0 else { return .text("") }

        var remaining = number
        var text = ""
        for (value, numeral) in classicNumerals where remaining > 0 {
            // Bounded: each pass reduces `remaining` by at least `value`, or not at all and
            // moves to a smaller numeral.
            while remaining >= value {
                text += numeral
                remaining -= value
            }
        }
        return .text(text)
    }

    /// `ARABIC(text)` — Roman numerals as a number.
    ///
    /// More permissive than ``roman``, deliberately, because it reads what a person wrote:
    /// any sequence where a smaller numeral before a larger one subtracts. `MCMXCIX` is 1999
    /// and so is `MIM`, which no form of `ROMAN` produces.
    ///
    /// A leading minus is accepted, as Excel accepts it. Empty text is 0.
    public static let arabic = ExcelFunction(name: "ARABIC", minArgs: 1, maxArgs: 1) { args in
        if let error = args.first(where: isError) { return error }
        guard case .text(let raw) = args[0] else {
            // A number is already arabic; Excel answers `#VALUE!` rather than echoing it.
            if case .blank = args[0] { return .number(0) }
            return .error(.value)
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard !trimmed.isEmpty else { return .number(0) }

        let negative = trimmed.hasPrefix("-")
        let body = negative ? String(trimmed.dropFirst()) : trimmed

        var total = 0
        var previous = 0
        // Right to left: a numeral smaller than the one after it subtracts, which is the
        // whole of the subtractive rule and needs no table of exceptions.
        for character in body.reversed() {
            guard let value = numeralValues[character] else { return .error(.value) }
            total += value < previous ? -value : value
            previous = Swift.max(previous, value)
        }
        return .number(Double(negative ? -total : total))
    }

    // MARK: - Matrices

    /// `MUNIT(dimension)` — the identity matrix.
    public static let munit = ExcelFunction(name: "MUNIT", minArgs: 1, maxArgs: 1) { args in
        if let error = args.first(where: isError) { return error }
        guard let size = whole(args[0]), size >= 1 else { return .error(.value) }
        var elements: [CellValue] = []
        elements.reserveCapacity(size * size)
        for row in 0..<size {
            for column in 0..<size {
                elements.append(.number(row == column ? 1 : 0))
            }
        }
        guard let matrix = CellMatrix(elements: elements, rows: size, columns: size) else {
            return .error(.value)
        }
        return .array(matrix)
    }

    /// `MDETERM(array)` — the determinant of a square matrix.
    ///
    /// By LU decomposition with partial pivoting, which is what makes it usable past 3×3:
    /// cofactor expansion is `n!` multiplications and is hopeless by about 10×10, while this
    /// is `n³` and is also the numerically stable choice.
    ///
    /// A singular matrix answers 0 rather than a tiny number, because the pivot search
    /// finding nothing *is* the determination that it is singular.
    public static let mdeterm = ExcelFunction(name: "MDETERM", minArgs: 1, maxArgs: 1) { args in
        if let error = args.first(where: isError) { return error }
        guard case .array(let matrix) = args[0] else {
            // A single cell is a 1×1 matrix, and its determinant is itself.
            guard let value = BuiltinMathPrimitives.real(args[0]) else { return .error(.value) }
            return .number(value)
        }
        guard matrix.rows == matrix.columns, matrix.rows >= 1 else { return .error(.value) }

        let size = matrix.rows
        var a = [Double](repeating: 0, count: size * size)
        for row in 0..<size {
            for column in 0..<size {
                guard let value = BuiltinMathPrimitives.real(matrix[row, column]) else {
                    return .error(.value)
                }
                a[row * size + column] = value
            }
        }

        var determinant = 1.0
        for step in 0..<size {
            // Partial pivoting: the largest magnitude in the column, which keeps the
            // division below from amplifying whatever error is already there.
            var pivot = step
            for row in (step + 1)..<size
            where Swift.abs(a[row * size + step]) > Swift.abs(a[pivot * size + step]) {
                pivot = row
            }
            guard Swift.abs(a[pivot * size + step]) > 0 else { return .number(0) }
            if pivot != step {
                for column in 0..<size {
                    a.swapAt(step * size + column, pivot * size + column)
                }
                // Each row exchange flips the sign, which is the half of this that is easy
                // to leave out and impossible to notice on a symmetric example.
                determinant = -determinant
            }
            determinant *= a[step * size + step]
            for row in (step + 1)..<size {
                let factor = a[row * size + step] / a[step * size + step]
                guard factor != 0 else { continue }
                for column in step..<size {
                    a[row * size + column] -= factor * a[step * size + column]
                }
            }
        }
        return finite(determinant)
    }

    /// `PERCENTOF(data_subset, data_all)` — the subset's share of the whole.
    ///
    /// A sum divided by a sum, which is all Excel does with it. A total of zero is
    /// `#DIV/0!` rather than 0, because "none of nothing" has no share to report.
    public static let percentOf = ExcelFunction(
        name: "PERCENTOF", minArgs: 2, maxArgs: 2
    ) { args in
        if let error = args.first(where: isError) { return error }
        let subset = flatten([args[0]]).compactMap(BuiltinMathPrimitives.real).reduce(0, +)
        let whole = flatten([args[1]]).compactMap(BuiltinMathPrimitives.real).reduce(0, +)
        guard whole != 0 else { return .error(.div0) }
        return finite(subset / whole)
    }

    // MARK: - Plumbing

    private static let classicNumerals: [(Int, String)] = [
        (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"),
        (100, "C"), (90, "XC"), (50, "L"), (40, "XL"),
        (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
    ]

    private static let numeralValues: [Character: Int] = [
        "I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000,
    ]

    private static func isError(_ value: CellValue) -> Bool {
        if case .error = value { return true }
        return false
    }

    /// A number truncated toward zero, as Excel truncates a count.
    private static func whole(_ value: CellValue) -> Int? {
        guard let number = BuiltinMathPrimitives.real(value) else { return nil }
        return Int(exactly: number.rounded(.towardZero))
    }

    /// A number as plain text, without an exponent for ordinary magnitudes.
    ///
    /// Shared with the database family, whose headers and conditions may be written as
    /// numbers and must compare as the text a person typed.
    static func plainNumber(_ number: Double) -> String {
        guard let whole = Int(exactly: number) else { return String(number) }
        return String(whole)
    }

    private static func finite(_ value: Double) -> CellValue {
        value.isFinite ? .number(value) : .error(.num)
    }

    /// `C(n, k)`, multiplied term by term so the factorials never exist.
    private static func choose(_ n: Int, _ k: Int) -> Double {
        guard k >= 0, k <= n else { return 0 }
        let take = Swift.min(k, n - k)
        var result = 1.0
        // Bounded by `take`, which is at most n/2. The divisor is `step + 1` over a range
        // starting at zero, so it is one or more at every pass and never zero.
        for step in 0..<take {
            let divisor = Double(step + 1)
            guard divisor > 0 else { return 0 }
            result = result * Double(n - step) / divisor
        }
        return result.rounded()
    }

    /// Every value in a nested set of arguments, in order.
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

    /// Two arrays walked together, summing a function of each pair.
    private static func pairwise(
        _ name: String, _ body: @escaping @Sendable (Double, Double) -> Double
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 2, maxArgs: 2) { args in
            if let error = args.first(where: isError) { return error }
            let xs = flatten([args[0]]), ys = flatten([args[1]])
            // Excel refuses arrays of different lengths rather than stopping at the shorter:
            // a pairwise sum over mismatched data is a number with no meaning.
            guard xs.count == ys.count, !xs.isEmpty else { return .error(.na) }

            var total = 0.0
            for (x, y) in zip(xs, ys) {
                // A pair where either side is not a number is skipped, as the statistical
                // family skips text — not zero, which would drag the sum.
                guard let a = BuiltinMathPrimitives.real(x),
                      let b = BuiltinMathPrimitives.real(y) else { continue }
                total += body(a, b)
            }
            return finite(total)
        }
    }
}
