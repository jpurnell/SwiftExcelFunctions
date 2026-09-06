import Foundation
import SwiftExcelCore

/// Lookup category built-in Excel functions.
///
/// Provides implementations of 4 standard Excel lookup functions:
/// `VLOOKUP`, `HLOOKUP`, `INDEX`, and `MATCH`.
///
/// Register all functions at once via ``all``:
/// ```swift
/// var registry = FunctionRegistry()
/// for fn in BuiltinNavigationFunctions.all {
///     registry.register(fn)
/// }
/// ```
public enum BuiltinNavigationFunctions {

    /// All lookup functions for registration in a ``FunctionRegistry``.
    public static let all: [ExcelFunction] = [
        vlookup, hlookup, xlookup, index, match, address, column, row, indirect,
        offset, choose, lookup, rows, columns, hyperlink, getPivotData,
    ]

    // MARK: - Choosing among values

    /// `CHOOSE(index, value1, …)` — the value at a one-based position.
    ///
    /// Excel evaluates only the chosen argument. This evaluates all of them, which
    /// gives the same answer here because an error is a value rather than a
    /// thrown failure: an unchosen `1/0` becomes `#DIV/0!` and is discarded.
    public static let choose = ExcelFunction(name: "CHOOSE", minArgs: 2, maxArgs: nil) { args in
        catching {
            let index = Int(try toNumber(args[0]))
            guard index >= 1, index < args.count else { return .error(.value) }
            return args[index]
        }
    }

    /// `LOOKUP(value, lookupVector, [resultVector])` — the vector form.
    ///
    /// Finds the **last** entry not greater than the target, which is Excel's
    /// rule and assumes the vector is sorted. Below everything there is no match,
    /// and the answer is `#N/A` rather than the first entry.
    ///
    /// With no result vector the lookup vector supplies the answer.
    public static let lookup = ExcelFunction(name: "LOOKUP", minArgs: 2, maxArgs: 3) { args in
        catching {
            let target = try toNumber(args[0])
            let haystack = toArray(args[1])
            let results = args.count > 2 ? toArray(args[2]) : haystack

            var match: Int?
            for (index, entry) in haystack.enumerated() {
                guard case .number(let value) = entry else { continue }
                if value <= target { match = index } else { break }
            }
            guard let found = match, found < results.count else { return .error(.na) }
            return results[found]
        }
    }

    // MARK: - Asking about a position

    /// `COLUMN([reference])` — the column number of a reference, or of this cell.
    ///
    /// With no argument it answers about the cell the formula was written in,
    /// which is how 86,400 of the corpus's 86,620 calls are written. With one, it
    /// answers about the address it was *handed* rather than the value inside it:
    /// `COLUMN(B5)` is 2 whatever B5 holds.
    public static let column = ExcelFunction(name: "COLUMN", minArgs: 0, maxArgs: 1) { context, _ in
        guard !context.arguments.isEmpty else {
            guard let cell = context.callingCell else { return .error(.value) }
            return .number(Double(cell.cell.column))
        }
        guard let referenced = context.referencedCell(at: 0) else { return .error(.value) }
        return .number(Double(referenced.column))
    }

    /// `ROW([reference])` — the row number of a reference, or of this cell.
    public static let row = ExcelFunction(name: "ROW", minArgs: 0, maxArgs: 1) { context, _ in
        guard !context.arguments.isEmpty else {
            guard let cell = context.callingCell else { return .error(.value) }
            return .number(Double(cell.cell.row))
        }
        guard let referenced = context.referencedCell(at: 0) else { return .error(.value) }
        return .number(Double(referenced.row))
    }

    // MARK: - Reading a reference built while the formula runs

    /// `INDIRECT(text, [a1])` — read the cell that text names.
    ///
    /// The reference is decided during evaluation, which is what makes this
    /// function useful and also what makes it opaque: nothing reading the formula
    /// beforehand can know which cell it depends on. Recognition reports that
    /// separately as a dynamic reference, and should keep doing so even though
    /// the evaluator can now compute the value — *what it reads* and *what can be
    /// known about what it reads* are different questions.
    ///
    /// R1C1 style is refused rather than guessed at. Reading `R2C3` as an A1
    /// reference would return a plausible value for the wrong cell, which is
    /// worse than an error.
    public static let indirect = ExcelFunction(name: "INDIRECT", minArgs: 1, maxArgs: 2) { context, args in
        guard case .text(let reference) = args[0] else { return .error(.ref) }

        if args.count > 1 {
            let wantsA1: Bool
            if case .bool(let flag) = args[1] { wantsA1 = flag } else { wantsA1 = true }
            guard wantsA1 else { return .error(.ref) }
        }

        let (sheet, cellPart) = splitSheet(from: reference)
        guard let cell = parseReference(cellPart) else { return .error(.ref) }

        // An unqualified reference belongs to the sheet the provider is already
        // pointed at — that is what `value(at:)` means. Asking by name instead
        // would make the provider resolve a sheet it is standing on.
        let value = sheet.isEmpty
            ? context.cells.value(at: cell)
            : context.cells.value(at: cell, inSheet: sheet)
        return value ?? .blank
    }

    /// `OFFSET(reference, rows, columns, [height], [width])` — a reference
    /// displaced from another.
    ///
    /// Needs the *address* of its first argument, which is why it takes a context:
    /// by the time a function is called its arguments are values, and the address
    /// has gone.
    ///
    /// Three arguments name a single cell and the value comes back. Five name a
    /// block and the values come back as an array, which is what `SUM(OFFSET(…))`
    /// needs — so a reference never has to become a value for this to work. Every
    /// one of the corpus's 9,798 calls uses the three-argument form.
    public static let offset = ExcelFunction(name: "OFFSET", minArgs: 3, maxArgs: 5) { context, args in
        guard let base = context.referencedCell(at: 0) else { return .error(.ref) }
        let rows = Int(try toNumber(args[1]))
        let columns = Int(try toNumber(args[2]))

        let startRow = base.row + rows
        let startColumn = base.column + columns
        guard startRow >= 1, startColumn >= 1,
              startRow <= 1_048_576, startColumn <= 16_384 else { return .error(.ref) }

        let height = args.count > 3 ? Int(try toNumber(args[3])) : 1
        let width = args.count > 4 ? Int(try toNumber(args[4])) : 1
        guard height >= 1, width >= 1 else { return .error(.ref) }

        if height == 1 && width == 1 {
            let cell = CellRef(column: startColumn, row: startRow)
            return context.cells.value(at: cell) ?? .blank
        }

        let range = CellRange(
            from: CellRef(column: startColumn, row: startRow),
            to: CellRef(column: startColumn + width - 1, row: startRow + height - 1))
        return .array(context.cells.matrix(in: range))
    }

    // MARK: - Reading a reference out of text

    /// Splits `'Other Sheet'!A1` into its sheet and its cell.
    ///
    /// - Parameter reference: The reference as written.
    /// - Returns: The sheet name, empty when none was given, and the rest.
    static func splitSheet(from reference: String) -> (sheet: String, cell: String) {
        guard let bang = reference.lastIndex(of: "!") else { return ("", reference) }
        var sheet = String(reference[reference.startIndex..<bang])
        if sheet.hasPrefix("'") && sheet.hasSuffix("'") && sheet.count >= 2 {
            sheet = String(sheet.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return (sheet, String(reference[reference.index(after: bang)...]))
    }

    /// Reads `A1`, `$A$1` and the like into a reference.
    ///
    /// Returns `nil` for anything that is not one, so `INDIRECT("nonsense")` can
    /// answer `#REF!` rather than a cell nobody named. `CellRef` does the parsing;
    /// this only decides whether the text was a reference at all.
    static func parseReference(_ text: String) -> CellRef? {
        let bare = text.replacingOccurrences(of: "$", with: "")
        guard !bare.isEmpty else { return nil }

        let letters = bare.prefix { $0.isLetter }
        let digits = bare.dropFirst(letters.count)
        guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        guard let rowValue = Int(digits), (1...1_048_576).contains(rowValue) else { return nil }

        var columnValue = 0
        for character in letters {
            guard let scalar = character.uppercased().unicodeScalars.first?.value else { return nil }
            columnValue = columnValue * 26 + Int(scalar - 64)
        }
        guard (1...16_384).contains(columnValue) else { return nil }
        return CellRef(column: columnValue, row: rowValue)
    }

    // MARK: - Building a reference

    /// `ADDRESS(row, column, [abs], [a1], [sheet])` — a reference, as text.
    ///
    /// Numbers in, a string out. It builds a reference rather than reading one,
    /// which is why it needs no evaluation context: nothing here has to know
    /// where it was called from or what any cell holds.
    ///
    /// In the corpus it is always paired with `INDIRECT` — a sheet computes a row
    /// and a column, asks `ADDRESS` for the reference, and hands the text to
    /// `INDIRECT` to read. 20,978 calls across 32 sheets, every one with five
    /// arguments and the fourth left empty.
    public static let address = ExcelFunction(name: "ADDRESS", minArgs: 2, maxArgs: 5) { args in
        catching {
            let row = Int(try toNumber(args[0]))
            let column = Int(try toNumber(args[1]))
            guard (1...1_048_576).contains(row), (1...16_384).contains(column) else {
                return .error(.value)
            }

            // An omitted argument arrives as `.blank` and means "use the default",
            // which is not the same as a zero. The corpus writes
            // `ADDRESS(r, c, 1, , "Sheet")` 20,978 times, and reading that blank
            // as a value would ask for R1C1 every time.
            let style = try defaulted(args, 2, to: 1) { Int(try toNumber($0)) }
            let useA1 = try defaulted(args, 3, to: true) { value in
                if case .bool(let flag) = value { return flag }
                return try toNumber(value) != 0
            }
            guard (1...4).contains(style) else { return .error(.value) }

            let absoluteRow = style == 1 || style == 2
            let absoluteColumn = style == 1 || style == 3
            let reference = useA1
                ? "\(absoluteColumn ? "$" : "")\(columnLetters(column))"
                    + "\(absoluteRow ? "$" : "")\(row)"
                : (absoluteRow ? "R\(row)" : "R[\(row)]")
                    + (absoluteColumn ? "C\(column)" : "C[\(column)]")

            guard args.count > 4, case .text(let sheet) = args[4], !sheet.isEmpty else {
                return .text(reference)
            }
            return .text("\(quoted(sheet))!\(reference)")
        }
    }

    /// An argument's value, or a default when it was omitted.
    ///
    /// `.blank` is how an omitted argument arrives, and it is distinct from any
    /// value the caller could have written.
    private static func defaulted<T>(
        _ args: [CellValue],
        _ index: Int,
        to fallback: T,
        read: (CellValue) throws -> T
    ) rethrows -> T {
        guard args.count > index else { return fallback }
        if case .blank = args[index] { return fallback }
        return try read(args[index])
    }

    /// A column number as Excel's letters: 1 is `A`, 26 is `Z`, 27 is `AA`.
    ///
    /// Bijective base-26, which is why the usual base conversion is wrong here —
    /// there is no zero digit, so 26 is `Z` rather than `A0`.
    static func columnLetters(_ column: Int) -> String {
        var remaining = column
        var letters = ""
        while remaining > 0 {
            let digit = (remaining - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + digit))) + letters
            remaining = (remaining - 1) / 26
        }
        return letters
    }

    /// A sheet name, quoted only if it needs to be.
    ///
    /// Excel quotes a name containing anything but letters, digits and
    /// underscores, and doubles any apostrophe inside it.
    static func quoted(_ sheet: String) -> String {
        let plain = sheet.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        guard !plain || sheet.isEmpty else { return sheet }
        return "'\(sheet.replacingOccurrences(of: "'", with: "''"))'"
    }

    // MARK: - Type coercion

    /// Extracts a `Double` from a `CellValue`, applying Excel-style type coercion.
    private static func toNumber(_ value: CellValue) throws -> Double {
        switch value {
        case .number(let n):
            return n
        case .text(let s):
            guard let n = Double(s) else { throw EvalError.typeMismatch }
            return n
        case .bool(let b):
            return b ? 1.0 : 0.0
        case .blank:
            return 0.0
        case .error(let e):
            throw EvalError.excelError(e)
        case .date(let d):
            return d.timeIntervalSinceReferenceDate / 86_400.0
        case .formula(_, let cached):
            return try toNumber(cached ?? .blank)
        case .array:
            throw EvalError.typeMismatch
        }
    }

    /// Wraps a function body so that ``EvalError`` maps to the correct ``CellValue/error(_:)``.
    private static func catching(_ body: () throws -> CellValue) -> CellValue {
        do {
            return try body()
        } catch EvalError.excelError(let e) {
            return .error(e)
        } catch EvalError.numError {
            return .error(.num)
        } catch EvalError.div0Error {
            return .error(.div0)
        } catch {
            return .error(.value)
        }
    }

    /// Extracts the flat array of values from a `CellValue`.
    ///
    /// If the value is `.array(...)`, returns the elements. Otherwise returns a single-element array.
    ///
    /// For anything that indexes by position — the lookups, `INDEX` — use
    /// ``asMatrix(_:)`` instead: flattening is what made those wrong.
    private static func toArray(_ value: CellValue) -> [CellValue] {
        if case .array(let matrix) = value {
            return matrix.elements
        }
        return [value]
    }

    /// The first argument that is an error, if any.
    ///
    /// Excel propagates an error through a function rather than absorbing it: an
    /// argument of `#NAME?` makes the result `#NAME?`. Only functions built to trap
    /// errors — `IFERROR`, `ISERROR`, `IFNA` — see one and carry on.
    ///
    /// It matters most where a function has an error of its own to return. A lookup
    /// handed `#NAME?` used to answer `#N/A`, which says "looked and did not find"
    /// about a lookup that never happened, and loses the only clue to where the
    /// trouble started. One corpus sheet has 337 cells cached `#NAME?`; every lookup
    /// reading them reported `#N/A` instead.
    ///
    /// The *first* error wins, so the answer names the failure nearest the start of
    /// the argument list rather than whichever the implementation happened to test.
    ///
    /// - Parameter args: The arguments as evaluated.
    /// - Returns: The error to propagate, or `nil`.
    private static func propagatedError(_ args: [CellValue]) -> CellValue? {
        for argument in args {
            if case .error = argument { return argument }
        }
        return nil
    }

    /// A shaped view of an argument.
    ///
    /// A lone value is a 1×1 table, which is what makes `VLOOKUP(x, A1, 1)` behave
    /// like the degenerate case it is rather than a special one.
    ///
    /// - Parameter value: The argument.
    /// - Returns: The rectangle it stands for.
    private static func asMatrix(_ value: CellValue) -> CellMatrix {
        if case .array(let matrix) = value { return matrix }
        return CellMatrix(single: value)
    }

    /// Determines whether range_lookup is exact match (false) or approximate (true).
    ///
    /// - Parameter value: The range_lookup argument.
    /// - Returns: `true` for approximate match, `false` for exact.
    private static func isApproximate(_ value: CellValue) -> Bool {
        switch value {
        case .bool(let b):
            return b
        case .number(let n):
            return n != 0
        case .blank:
            return true // default is approximate
        default:
            return true
        }
    }

    /// Compares two `CellValue` instances for equality in lookup context.
    ///
    /// Text comparison is case-insensitive. Numbers and bools compare by value.
    private static func valuesEqual(_ lhs: CellValue, _ rhs: CellValue) -> Bool {
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)):
            return a == b
        case (.text(let a), .text(let b)):
            return a.caseInsensitiveCompare(b) == .orderedSame
        case (.bool(let a), .bool(let b)):
            return a == b
        case (.blank, .blank):
            return true
        // Cross-type: number to text coercion for lookups
        case (.number(let n), .text(let s)):
            return Double(s).map { $0 == n } ?? false
        case (.text(let s), .number(let n)):
            return Double(s).map { $0 == n } ?? false
        default:
            return false
        }
    }

    /// Compares two `CellValue` instances for ordering in approximate match lookups.
    ///
    /// Returns negative if lhs < rhs, 0 if equal, positive if lhs > rhs.
    /// Returns nil if values are not comparable.
    private static func compareValues(_ lhs: CellValue, _ rhs: CellValue) -> Int? {
        switch (lhs, rhs) {
        case (.number(let a), .number(let b)):
            if a < b { return -1 }
            if a > b { return 1 }
            return 0
        case (.text(let a), .text(let b)):
            let result = a.caseInsensitiveCompare(b)
            switch result {
            case .orderedAscending: return -1
            case .orderedDescending: return 1
            case .orderedSame: return 0
            }
        default:
            return nil
        }
    }

    // MARK: - VLOOKUP

    /// `VLOOKUP(lookup_value, table_array, col_index_num, [range_lookup])` -- vertical lookup.
    ///
    /// Searches for `lookup_value` in the first column of the table and returns
    /// a value from the same row in the specified column.
    ///
    /// The table's width comes from the table, not from `col_index_num`. It used to
    /// be inferred by testing which divisors of the element count came out even,
    /// which returned `#N/A` for a four-column table asked for its third column.
    ///
    /// - `range_lookup` = `FALSE` (or 0): exact match
    /// - `range_lookup` = `TRUE` (or 1, default): approximate match (data must be sorted ascending)
    ///
    /// Returns `#N/A` if not found, `#REF!` if `col_index_num` is out of bounds.
    static let vlookup = ExcelFunction(name: "VLOOKUP", minArgs: 3, maxArgs: 4) { args in
        catching {
            if let error = propagatedError(args) { return error }
            let table = asMatrix(args[1])
            let colIndex = Int(try toNumber(args[2]))
            let approximate = args.count > 3 ? isApproximate(args[3]) : true

            guard colIndex >= 1 else { return .error(.value) }
            guard colIndex <= table.columns else { return .error(.ref) }
            guard table.rows > 0 else { return .error(.na) }

            let lookupValue = args[0]
            guard let match = firstRow(in: table, matching: lookupValue, approximate: approximate)
            else { return .error(.na) }
            return table[match, colIndex - 1]
        }
    }

    /// The row whose first cell answers the lookup, or `nil`.
    ///
    /// - Parameters:
    ///   - table: The table to search.
    ///   - lookupValue: The value to find.
    ///   - approximate: Whether to take the largest key not exceeding the value,
    ///     which requires the keys be sorted ascending — Excel's rule, and the
    ///     reason this may stop early.
    /// - Returns: The row index, or `nil` when nothing matches.
    private static func firstRow(
        in table: CellMatrix, matching lookupValue: CellValue, approximate: Bool
    ) -> Int? {
        guard approximate else {
            return (0..<table.rows).first { valuesEqual(table[$0, 0], lookupValue) }
        }
        var best: Int?
        for row in 0..<table.rows {
            guard let comparison = compareValues(table[row, 0], lookupValue) else { continue }
            if comparison <= 0 { best = row } else { break }
        }
        return best
    }

    // MARK: - HLOOKUP

    /// `HLOOKUP(lookup_value, table_array, row_index_num, [range_lookup])` -- horizontal lookup.
    ///
    /// Searches for `lookup_value` in the first row of the table and returns
    /// a value from the same column in the specified row.
    ///
    /// The `table_array` should be a flat `.array(...)` organized row-major.
    /// Since we cannot infer the number of columns from a flat array for HLOOKUP,
    /// we treat the first row as having all elements up to the first occurrence
    /// of `row_index_num` rows fitting evenly.
    ///
    /// Returns `#N/A` if not found, `#REF!` if `row_index_num` is out of bounds.
    static let hlookup = ExcelFunction(name: "HLOOKUP", minArgs: 3, maxArgs: 4) { args in
        catching {
            if let error = propagatedError(args) { return error }
            let table = asMatrix(args[1])
            let rowIndex = Int(try toNumber(args[2]))
            let approximate = args.count > 3 ? isApproximate(args[3]) : true

            guard rowIndex >= 1 else { return .error(.value) }
            guard rowIndex <= table.rows else { return .error(.ref) }
            guard table.columns > 0 else { return .error(.na) }

            let lookupValue = args[0]
            guard let match = firstColumn(in: table, matching: lookupValue,
                                          approximate: approximate)
            else { return .error(.na) }
            return table[rowIndex - 1, match]
        }
    }

    /// The column whose first cell answers the lookup, or `nil`.
    ///
    /// - Parameters:
    ///   - table: The table to search.
    ///   - lookupValue: The value to find.
    ///   - approximate: Whether to take the largest key not exceeding the value.
    /// - Returns: The column index, or `nil` when nothing matches.
    private static func firstColumn(
        in table: CellMatrix, matching lookupValue: CellValue, approximate: Bool
    ) -> Int? {
        guard approximate else {
            return (0..<table.columns).first { valuesEqual(table[0, $0], lookupValue) }
        }
        var best: Int?
        for column in 0..<table.columns {
            guard let comparison = compareValues(table[0, column], lookupValue) else { continue }
            if comparison <= 0 { best = column } else { break }
        }
        return best
    }

    // MARK: - INDEX

    /// `INDEX(array, row_num, [col_num])` -- returns the value at a position in an array.
    ///
    /// With just `row_num`: counts along a vector, or returns a whole row of a block.
    /// With both: reads the position directly, since the array knows its own width.
    ///
    /// Returns `#REF!` if the index is out of bounds.
    static let index = ExcelFunction(name: "INDEX", minArgs: 2, maxArgs: 3) { args in
        catching {
            let array = asMatrix(args[0])
            let rowNum = Int(try toNumber(args[1]))
            guard rowNum >= 1 else { return .error(.value) }

            guard args.count == 3 else {
                // One index. Along a vector it counts cells; across a block Excel
                // means the whole row, which is now a value this can return.
                if array.isVector {
                    guard rowNum <= array.count else { return .error(.ref) }
                    return array.elements[rowNum - 1]
                }
                guard let row = array.row(rowNum - 1) else { return .error(.ref) }
                return .array(CellMatrix(row: row))
            }

            let colNum = Int(try toNumber(args[2]))
            guard colNum >= 1 else { return .error(.value) }
            guard let value = array.element(row: rowNum - 1, column: colNum - 1) else {
                return .error(.ref)
            }
            return value
        }
    }

    // MARK: - XLOOKUP

    /// `XLOOKUP(lookup, lookup_array, return_array, [if_not_found], [match_mode], [search_mode])`
    ///
    /// The generalisation of `VLOOKUP` and `HLOOKUP`, and the reason it supersedes
    /// them is that it stops conflating three things they had to share. Where they
    /// take one table and an offset *into* it — so the key must be its first row or
    /// column, and the answer must be to the right or below — this takes the keys
    /// and the answers as separate ranges. They need not touch, and neither has to
    /// come first.
    ///
    /// | | `VLOOKUP` | `XLOOKUP` |
    /// |---|---|---|
    /// | key and result | one table, an offset | two ranges |
    /// | result before key | impossible | ordinary |
    /// | not found | `#N/A` | `#N/A`, or what you say |
    /// | default match | approximate | **exact** |
    /// | search direction | forwards | either |
    ///
    /// The default reversal is the one to notice: `VLOOKUP`'s fourth argument
    /// defaults to *approximate*, which is why so many spreadsheets carry a
    /// `FALSE` nobody remembers adding. `XLOOKUP` defaults to exact.
    ///
    /// `match_mode`: `0` exact (default), `-1` exact or next smaller, `1` exact or
    /// next larger, `2` wildcard — not supported here, and answers `#VALUE!` rather
    /// than pretending.
    ///
    /// `search_mode`: `1` first to last (default), `-1` last to first, `2` and `-2`
    /// binary search on sorted data. The binary modes are accepted and searched
    /// linearly: on a sorted range that finds the same element, and on an unsorted
    /// one Excel's own result is undefined, so the difference is not observable in a
    /// well-formed workbook.
    ///
    /// The lookup and return ranges must be the same length; anything else is
    /// `#VALUE!`, as in Excel.
    static let xlookup = ExcelFunction(name: "XLOOKUP", minArgs: 3, maxArgs: 6) { args in
        catching {
            // `if_not_found` is exempt: it is the argument whose whole purpose is to
            // be produced when something fails, so an error there is a value.
            var checked = args
            if checked.count > 3 { checked.remove(at: 3) }
            if let error = propagatedError(checked) { return error }

            let keys = asMatrix(args[1])
            let results = asMatrix(args[2])
            guard keys.count > 0, keys.count == results.count else { return .error(.value) }

            let matchMode = args.count > 4 ? Int(try toNumber(args[4])) : 0
            let searchMode = args.count > 5 ? Int(try toNumber(args[5])) : 1
            guard [0, -1, 1, 2].contains(matchMode) else { return .error(.value) }
            guard [1, -1, 2, -2].contains(searchMode) else { return .error(.value) }
            // Wildcard matching is not implemented; refusing is honest, and
            // answering an exact match instead would silently find the wrong row.
            guard matchMode != 2 else { return .error(.value) }

            let order = searchMode < 0
                ? Array((0..<keys.count).reversed())
                : Array(0..<keys.count)
            let lookupValue = args[0]

            if let hit = order.first(where: { valuesEqual(keys.elements[$0], lookupValue) }) {
                return results.elements[hit]
            }
            if matchMode != 0 {
                // Nearest smaller (-1) or nearest larger (1), by value rather than by
                // position, so an unsorted range still answers what Excel answers.
                var best: (index: Int, key: CellValue)?
                for index in order {
                    let key = keys.elements[index]
                    guard let comparison = compareValues(key, lookupValue) else { continue }
                    let wanted = matchMode < 0 ? comparison < 0 : comparison > 0
                    guard wanted else { continue }
                    guard let current = best,
                          let better = compareValues(key, current.key) else {
                        best = (index, key)
                        continue
                    }
                    if matchMode < 0 ? better > 0 : better < 0 { best = (index, key) }
                }
                if let best { return results.elements[best.index] }
            }
            if args.count > 3 { return args[3] }
            return .error(.na)
        }
    }

    // MARK: - MATCH

    /// `MATCH(lookup_value, lookup_array, [match_type])` -- finds the position of a value in an array.
    ///
    /// - `match_type` = 1 (default): finds largest value <= `lookup_value` (array must be sorted ascending)
    /// - `match_type` = 0: exact match
    /// - `match_type` = -1: finds smallest value >= `lookup_value` (array must be sorted descending)
    ///
    /// Returns a 1-based position. Returns `#N/A` if not found.
    static let match = ExcelFunction(name: "MATCH", minArgs: 2, maxArgs: 3) { args in
        catching {
            if let error = propagatedError(args) { return error }
            let lookupValue = args[0]
            let lookupArray = toArray(args[1])
            let matchType: Int
            if args.count > 2 {
                matchType = Int(try toNumber(args[2]))
            } else {
                matchType = 1
            }

            guard !lookupArray.isEmpty else { return .error(.na) }

            switch matchType {
            case 0:
                // Exact match
                for (i, val) in lookupArray.enumerated() {
                    if valuesEqual(val, lookupValue) {
                        return .number(Double(i + 1))
                    }
                }
                return .error(.na)

            case 1:
                // Sorted ascending: find largest <= lookup_value
                var bestIndex: Int?
                for (i, val) in lookupArray.enumerated() {
                    if let cmp = compareValues(val, lookupValue) {
                        if cmp <= 0 {
                            bestIndex = i
                        } else {
                            break
                        }
                    }
                }
                guard let found = bestIndex else { return .error(.na) }
                return .number(Double(found + 1))

            case -1:
                // Sorted descending: find smallest >= lookup_value
                var bestIndex: Int?
                for (i, val) in lookupArray.enumerated() {
                    if let cmp = compareValues(val, lookupValue) {
                        if cmp >= 0 {
                            bestIndex = i
                        } else {
                            break
                        }
                    }
                }
                guard let found = bestIndex else { return .error(.na) }
                return .number(Double(found + 1))

            default:
                return .error(.na)
            }
        }
    }

    // MARK: - Counting a shape

    /// `ROWS(array)` — how many rows a range or array has.
    ///
    /// Answerable directly now that a value carries its own dimensions; before
    /// `CellMatrix` this would have had to guess, the way `VLOOKUP` used to.
    static let rows = ExcelFunction(name: "ROWS", minArgs: 1, maxArgs: 1) { args in
        if let error = propagatedError(args) { return error }
        return .number(Double(asMatrix(args[0]).rows))
    }

    /// `COLUMNS(array)` — how many columns a range or array has.
    static let columns = ExcelFunction(name: "COLUMNS", minArgs: 1, maxArgs: 1) { args in
        if let error = propagatedError(args) { return error }
        return .number(Double(asMatrix(args[0]).columns))
    }

    /// `HYPERLINK(link_location, [friendly_name])` — a link, and what it reads as.
    ///
    /// The jump is a thing the spreadsheet application does when someone clicks; the
    /// *value* is the text shown, which is the friendly name when there is one and
    /// the location otherwise. Evaluation has only the second half to answer, and
    /// answering it is what stops a cell full of links reading as `#NAME?`.
    static let hyperlink = ExcelFunction(name: "HYPERLINK", minArgs: 1, maxArgs: 2) { args in
        if let error = propagatedError(args) { return error }
        return args.count > 1 ? args[1] : args[0]
    }

    // MARK: - Pivot tables

    /// `GETPIVOTDATA(data_field, pivot_table, [field, item]…)` — a value from a
    /// PivotTable report.
    ///
    /// Answers `#REF!`. The number is not computed from the arguments: it is looked
    /// up in a pivot cache, which lives in `xl/pivotCache/` in the file and which
    /// this family does not read. Pivot caches are out of scope — a decision, not an
    /// omission.
    ///
    /// `#REF!` because that is what Excel answers when the PivotTable being pointed
    /// at is not available, which is exactly our situation: the pivot table really is
    /// not here. It is the honest report rather than a stand-in.
    ///
    /// Deliberately **not** `#NAME?`. The function exists and its name is known; what
    /// is missing is the data behind it, and a caller debugging a sheet needs to be
    /// able to tell those apart. Registering it is what makes that distinction
    /// available at all.
    ///
    /// The corpus writes it 1,398 times across six workbooks. Every one of those
    /// cells would need the cache to answer correctly, so none of them is a near
    /// miss.
    static let getPivotData = ExcelFunction(
        name: "GETPIVOTDATA", minArgs: 2, maxArgs: nil
    ) { args in
        if let error = propagatedError(args) { return error }
        return .error(.ref)
    }
}
