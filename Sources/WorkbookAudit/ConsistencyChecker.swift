import Foundation
import SwiftExcelCore
import SwiftExcelFunctions

/// One cell in a run differing from its neighbours.
///
/// The classic spreadsheet defect: the copy that stopped short, the hand-edit nobody
/// noticed. It is also the one a person is least likely to see, because the wrong cell
/// looks exactly like the right ones — it is a number in a row of numbers.
///
/// ## Modulo relative offset
///
/// `=B2*C2` in row 2 and `=B3*C3` in row 3 are the *same* formula written in two places, so
/// comparing them literally finds a difference in every cell of every copied row. The
/// comparison has to be against R1C1 form, where both read `R[-1]C[-2]*R[-1]C[-1]` and only
/// a genuine difference survives.
///
/// An **absolute** reference stays distinct from a relative one on purpose. `$B$1`
/// deliberately anchored is not the same intent as `B1` that happened not to move, and
/// collapsing them would hide the copy that lost its anchor — itself one of the defects
/// this exists to find.
public struct ConsistencyChecker: WorkbookChecker {

    /// The name on every finding this makes.
    public static let name = "consistency"

    /// Structure only. Nothing is evaluated to compare two shapes.
    public static let requires: Requirement = .structure

    /// How many cells must agree before one that disagrees is worth reporting.
    ///
    /// Three, so a run is a majority rather than a coin toss. Two against two is a model
    /// with two sections, not a mistake, and reporting it is the noise that gets a checker
    /// switched off — which `PROPOSAL_workbook_validator.md` §9 puts the census before the
    /// second checker to prevent.
    private let quorum: Int

    /// - Parameter quorum: how many agreeing neighbours make a run. Defaults to 3.
    public init(quorum: Int = 3) { self.quorum = quorum }

    /// Reports cells that break a run their neighbours agree on.
    ///
    /// - Parameter model: the workbook and its addresses.
    /// - Returns: one finding per interior dissenter, naming the run it broke.
    public func check(_ model: AuditModel) -> [Finding] {
        var findings: [Finding] = []
        let bySheet = Dictionary(grouping: model.addresses, by: \.sheet)

        for (sheet, addresses) in bySheet.sorted(by: { $0.key < $1.key }) {
            let formulas = addresses.reduce(into: [CellRef: String]()) { table, address in
                guard let ast = model.cells
                    .value(at: address.cell, inSheet: address.sheet)?.formulaAST else { return }
                table[address.cell] = Self.shapeSignature(of: ast, at: address.cell)
            }
            findings += oddOnesOut(in: formulas, sheet: sheet, byRow: true)
            findings += oddOnesOut(in: formulas, sheet: sheet, byRow: false)
        }
        return findings
    }

    /// Scans each line for a contiguous run whose members mostly agree.
    private func oddOnesOut(
        in formulas: [CellRef: String], sheet: String, byRow: Bool
    ) -> [Finding] {
        let lines = Dictionary(grouping: formulas.keys) { byRow ? $0.row : $0.column }
        var findings: [Finding] = []

        for (_, cells) in lines.sorted(by: { $0.key < $1.key }) {
            let ordered = cells.sorted { byRow ? $0.column < $1.column : $0.row < $1.row }

            // Split into maximal contiguous spans: a formula at B5 and another at Z5 are
            // unrelated however similar they look.
            var span: [CellRef] = []
            for cell in ordered {
                let position = byRow ? cell.column : cell.row
                let previous = span.last.map { byRow ? $0.column : $0.row }
                if let previous, position != previous + 1 {
                    findings += judge(span, formulas: formulas, sheet: sheet, byRow: byRow)
                    span = []
                }
                span.append(cell)
            }
            findings += judge(span, formulas: formulas, sheet: sheet, byRow: byRow)
        }
        return findings
    }

    /// Reports the members of one span that disagree with a clear majority.
    private func judge(
        _ span: [CellRef], formulas: [CellRef: String], sheet: String, byRow: Bool
    ) -> [Finding] {
        guard span.count > quorum else { return [] }

        let signatures = span.compactMap { formulas[$0] }
        var counts: [String: [CellRef]] = [:]
        for cell in span { counts[formulas[cell] ?? "", default: []].append(cell) }

        // One shape must hold the quorum, and everything else together must be a small
        // minority. Two large groups are two sections of a model, not a defect.
        guard let (majoritySignature, majority) = counts.max(by: { $0.value.count < $1.value.count }),
              majority.count >= quorum,
              signatures.count - majority.count > 0,
              majority.count > (signatures.count - majority.count) * 2
        else { return [] }

        // **Only the interior.** The first and last cells of a run are seeds and
        // terminators, and differing there is how a series works rather than a mistake.
        // Measured on six real models: `E6 = acquisition_date` starting a row whose every
        // later cell reads `EOMONTH(previous, months)` is the shape of nearly every false
        // positive this checker produced before the rule — 415 findings across 67% of
        // workbooks, most of them a legitimate anchor.
        //
        // An interior cell has agreeing neighbours on *both* sides, so it broke a pattern
        // that closed around it. That is the defect; an edge cell starting a different
        // pattern is not.
        let interior = Set(span.dropFirst().dropLast())

        return counts
            .filter { $0.key != majoritySignature }
            .flatMap(\.value)
            .filter { interior.contains($0) }
            .sorted { ($0.row, $0.column) < ($1.row, $1.column) }
            .map { cell in
                Finding(
                    checker: Self.name,
                    severity: .warning,
                    address: CellAddress(sheet: sheet, cell: cell),
                    summary: "\(cell.reference) does not match the "
                        + "\(majority.count) \(byRow ? "cells beside it" : "cells above and below it")",
                    detail: """
                        Compared modulo relative offset, so a copied formula counts as the \
                        same shape. This cell's shape is \(formulas[cell] ?? "—"); its \
                        neighbours' is \(majoritySignature). That is the pattern of a copy \
                        that stopped short or an edit made in one place — and the wrong \
                        cell looks like the right ones, which is why it survives review.
                        """,
                    related: majority
                        .sorted { ($0.row, $0.column) < ($1.row, $1.column) }
                        .map { CellAddress(sheet: sheet, cell: $0) })
            }
    }

    // MARK: - The signature

    /// A formula's shape, with references written relative to the cell holding it.
    ///
    /// R1C1 by another name: `R[-1]C[-2]` for a relative reference one row up and two
    /// columns left, `R3C2` for an absolute one. Two formulas have the same signature
    /// exactly when one is a faithful copy of the other.
    ///
    /// - Parameters:
    ///   - ast: the formula.
    ///   - origin: the cell it lives in, which the offsets are measured from.
    /// - Returns: a canonical string, equal for equal shapes.
    public static func shapeSignature(of ast: FormulaAST, at origin: CellRef) -> String {
        switch ast {
        case .number(let v): return "#\(v)"
        case .text(let t): return "\"\(t)\""
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .error(let e): return "!\(e)"
        case .missing: return "_"
        case .namedRange(let n): return "N(\(n))"
        case .sheetRef: return "S"

        case .cellRef(let ref):
            return reference(ref, from: origin)

        case .cellRange(let range):
            return "\(reference(range.start, from: origin)):\(reference(range.end, from: origin))"

        case .negate(let operand):
            return "neg(\(shapeSignature(of: operand, at: origin)))"

        case .function(let rawName, let arguments):
            let inner = arguments.map { shapeSignature(of: $0, at: origin) }.joined(separator: ",")
            return "\(FunctionRegistry.canonical(rawName))(\(inner))"

        default:
            guard let (kind, lhs, rhs) = ast.binary else { return "?" }
            return "(\(shapeSignature(of: lhs, at: origin))"
                + "\(kind)"
                + "\(shapeSignature(of: rhs, at: origin)))"
        }
    }

    /// One reference in R1C1 terms.
    ///
    /// Absolute stays absolute — an anchored reference does not move when the formula is
    /// copied, so writing it as an offset would make two genuinely different formulas look
    /// identical.
    private static func reference(_ ref: CellRef, from origin: CellRef) -> String {
        let row = ref.absoluteRow ? "R\(ref.row)" : "R[\(ref.row - origin.row)]"
        let column = ref.absoluteColumn ? "C\(ref.column)" : "C[\(ref.column - origin.column)]"
        return row + column
    }
}
