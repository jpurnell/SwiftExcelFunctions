import Foundation
import SwiftExcelCore

/// The twelve `D` functions — `DSUM` and its relatives.
///
/// All twelve have the same signature and differ only in what they do with the numbers they
/// select, so the selection is written once here and the aggregate is a closure.
///
/// ```
/// DSUM(database, field, criteria)
/// ```
///
/// **`database`** is a range whose *first row is the header*. **`field`** names a column,
/// either by its header text or by its one-based position. **`criteria`** is a second range,
/// also headed, whose rows are conditions.
///
/// ## The criteria range is the whole of the design
///
/// Its shape carries the logic, and it is the part that surprises people:
///
/// - **Columns are `AND`.** A row with `>100` under *Amount* and `North` under *Region*
///   selects records satisfying both.
/// - **Rows are `OR`.** Two criteria rows select records satisfying either.
/// - **A blank cell is not a condition**, it is the absence of one. A criteria row that is
///   entirely blank therefore matches every record — which is correct and catches people out.
///
/// Each condition is matched with `BuiltinAggregationFunctions.matchesCriteria`, the same
/// function `SUMIF` and `COUNTIF` use. One criteria vocabulary, so `">100"` means the
/// same thing wherever it is written.
public enum BuiltinDatabaseFunctions {

    /// All twelve database functions, for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        dsum, dproduct, dcount, dcountA, dget, dmax, dmin,
        daverage, dstdev, dstdevP, dvar, dvarP
    ]

    // MARK: - The twelve

    /// `DSUM(database, field, criteria)` — the sum of the matching values.
    public static let dsum = aggregate("DSUM") { .number($0.reduce(0, +)) }

    /// `DPRODUCT(database, field, criteria)` — their product.
    public static let dproduct = aggregate("DPRODUCT") { values in
        // The product of nothing is zero in Excel, not the empty product of one — the same
        // rule `SUBTOTAL`'s product follows.
        values.isEmpty ? .number(0) : .number(values.reduce(1, *))
    }

    /// `DCOUNT(database, field, criteria)` — how many matching cells hold numbers.
    public static let dcount = aggregate("DCOUNT") { .number(Double($0.count)) }

    /// `DMAX` / `DMIN` — the largest and smallest matching values.
    ///
    /// Zero when nothing matched, which is Excel's answer and not `#NUM!`.
    public static let dmax = aggregate("DMAX") { .number($0.max() ?? 0) }
    /// `DMIN(database, field, criteria)` — the smallest matching value.
    public static let dmin = aggregate("DMIN") { .number($0.min() ?? 0) }

    /// `DAVERAGE(database, field, criteria)` — the mean of the matching values.
    public static let daverage = aggregate("DAVERAGE") { values in
        guard !values.isEmpty else { return .error(.div0) }
        return .number(values.reduce(0, +) / Double(values.count))
    }

    /// `DSTDEV` / `DVAR` — the **sample** statistics, with `n − 1` beneath.
    public static let dstdev = aggregate("DSTDEV") { spread($0, sample: true, root: true) }
    /// `DVAR(database, field, criteria)` — the sample variance.
    public static let dvar = aggregate("DVAR") { spread($0, sample: true, root: false) }
    /// `DSTDEVP(database, field, criteria)` — the population standard deviation.
    public static let dstdevP = aggregate("DSTDEVP") { spread($0, sample: false, root: true) }
    /// `DVARP(database, field, criteria)` — the population variance.
    public static let dvarP = aggregate("DVARP") { spread($0, sample: false, root: false) }

    /// `DCOUNTA(database, field, criteria)` — how many matching cells are non-blank.
    ///
    /// The one that counts cells rather than numbers, so it cannot go through the shared
    /// path: by the time the values are `[Double]` the text and the blanks are gone, and
    /// those are exactly what it is counting.
    public static let dcountA = ExcelFunction(
        name: "DCOUNTA", minArgs: 3, maxArgs: 3
    ) { context, args in
        selected(args, context) { cells in
            .number(Double(cells.filter { if case .blank = $0 { return false }
                                          else { return true } }.count))
        }
    }

    /// `DGET(database, field, criteria)` — the single matching value.
    ///
    /// The only one that refuses ambiguity: `#VALUE!` when nothing matched, `#NUM!` when more
    /// than one did. Returning the first of several would be a plausible answer to a question
    /// the author did not ask.
    public static let dget = ExcelFunction(name: "DGET", minArgs: 3, maxArgs: 3) { context, args in
        selected(args, context) { cells in
            let present = cells.filter { if case .blank = $0 { return false } else { return true } }
            guard let only = present.first else { return .error(.value) }
            guard present.count == 1 else { return .error(.num) }
            return only
        }
    }

    // MARK: - Selection

    /// One database function: select the matching cells in a column, then aggregate.
    private static func aggregate(
        _ name: String, _ body: @escaping @Sendable ([Double]) -> CellValue
    ) -> ExcelFunction {
        ExcelFunction(name: name, minArgs: 3, maxArgs: 3) { context, args in
            selected(args, context) { cells in
                body(cells.compactMap(BuiltinMathPrimitives.real))
            }
        }
    }

    /// The matching cells of the chosen column, handed to a closure.
    ///
    /// - Parameters:
    ///   - args: database, field, criteria — as evaluated values.
    ///   - context: carries the unevaluated argument trees, which is how the *ranges* are
    ///     recovered. A range arrives as a flat `CellMatrix` and a matrix has no header row
    ///     until something says which row that is, so the shape is read from the value and
    ///     the meaning from the first row.
    ///   - body: what to do with the selected cells.
    private static func selected(
        _ args: [CellValue], _ context: EvaluationContext,
        _ body: ([CellValue]) -> CellValue
    ) -> CellValue {
        if let error = args.first(where: isError) { return error }
        guard let database = Table(args[0]), let criteria = Table(args[2]),
              let column = database.column(named: args[1]) else {
            return .error(.value)
        }
        var kept: [CellValue] = []
        for row in database.records where criteria.selects(row, from: database) {
            kept.append(row[column])
        }
        return body(kept)
    }

    /// A headed rectangle: the first row names the columns, the rest are records.
    private struct Table {
        let headers: [String]
        let records: [[CellValue]]

        init?(_ value: CellValue) {
            guard case .array(let matrix) = value, matrix.rows >= 1 else { return nil }
            headers = (0..<matrix.columns).map { column in
                BuiltinDatabaseFunctions.text(matrix[0, column])
            }
            records = (1..<matrix.rows).map { row in
                (0..<matrix.columns).map { matrix[row, $0] }
            }
        }

        /// Which column a `field` argument names.
        ///
        /// By header text, or by one-based position — Excel accepts both, and a workbook
        /// written against column 3 keeps working when the header is renamed.
        func column(named field: CellValue) -> Int? {
            if case .text(let name) = field {
                let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
                return headers.firstIndex { $0.lowercased() == wanted }
            }
            guard let position = BuiltinMathPrimitives.real(field) else { return nil }
            let index = Int(position.rounded(.towardZero)) - 1
            guard index >= 0, index < headers.count else { return nil }
            return index
        }

        /// Whether this criteria table selects a record from `database`.
        ///
        /// **Rows are `OR`, columns within a row are `AND`**, and a blank cell states no
        /// condition at all. An entirely blank criteria row therefore matches everything,
        /// which is correct and is the behaviour people trip over.
        func selects(_ record: [CellValue], from database: Table) -> Bool {
            guard !records.isEmpty else { return true }
            return records.contains { conditions in
                conditions.enumerated().allSatisfy { position, condition in
                    guard position < headers.count else { return true }
                    let written = BuiltinDatabaseFunctions.text(condition)
                    guard !written.isEmpty else { return true }
                    guard let column = database.column(named: .text(headers[position])),
                          column < record.count else { return false }
                    return BuiltinAggregationFunctions.matchesCriteria(
                        record[column], written)
                }
            }
        }
    }

    // MARK: - Plumbing

    private static func isError(_ value: CellValue) -> Bool {
        if case .error = value { return true }
        return false
    }

    /// A cell as the text a header or a condition is written in.
    private static func text(_ value: CellValue) -> String {
        switch value {
        case .text(let string): return string.trimmingCharacters(in: .whitespaces)
        case .number(let number): return BuiltinMathCounting.plainNumber(number)
        case .bool(let flag): return flag ? "TRUE" : "FALSE"
        default: return ""
        }
    }

    /// Sample or population spread, optionally rooted.
    private static func spread(_ values: [Double], sample: Bool, root: Bool) -> CellValue {
        // Both divisors are guarded here, once, and named so the guard is visible at the
        // division rather than three lines above it.
        let count = Double(values.count)
        let denominator = sample ? count - 1 : count
        guard count > 0, denominator > 0 else { return .error(.div0) }

        let mean = values.reduce(0, +) / count
        let sum = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let result = sum / denominator
        return .number(root ? result.squareRoot() : result)
    }
}
