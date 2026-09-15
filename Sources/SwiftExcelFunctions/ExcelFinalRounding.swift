import Foundation

/// Excel's correction to a final addition or subtraction.
///
/// ## What it is
///
/// When a subtraction cancels nearly everything, Excel returns exactly zero rather than the
/// residue IEEE arithmetic leaves. `0.1+0.2-0.3` is `0` in Excel and
/// `5.551115123125783e-17` in every language that does not intervene.
///
/// **This was measured rather than read.** Twenty formulas were put to Excel and its answers
/// read back; one rule accounts for all of them, and it is a rule about the *ratio*, not
/// about smallness:
///
/// | relative size of the result | Excel |
/// |---|---|
/// | 1.11e-16 … 9.99e-16 | zero |
/// | 2.00e-15 … 1e-13 | kept |
///
/// So `100000.1-100000-0.1` keeps its `5.8e-12` — a hundred thousand times *larger* in
/// absolute terms than a residue that gets snapped — because relative to operands of about
/// `0.1` it is `5.8e-11`, and that is a real difference.
///
/// ## Where it applies, which is the surprising part
///
/// **Only to the last operation.** `(0.1+0.2-0.3)*1` returns the residue in Excel: the inner
/// subtraction is not corrected, because a multiplication came after it. The same
/// subtraction alone in a cell returns zero. One measured case rules out correcting every
/// addition as it happens.
///
/// **And always to comparisons**, wherever they sit. `a = b` is a subtraction underneath, and
/// this is what settles the famous pair:
///
/// ```
/// IF(0.1+0.2=0.3, …)   → "equal"    0.30000000000000004 − 0.3 is 1.85e-16 of the operands
/// (0.1+0.2-0.3)=0      → FALSE      5.55e-17 − 0 is the whole of it
/// ```
///
/// Both obey the rule. They look inconsistent only if the rule is read as being about small
/// numbers.
///
/// ## What is deliberately not implemented
///
/// Excel also stores numbers to **15 significant decimal digits**, so
/// `0.9999999999999985` becomes `0.999999999999998` before any arithmetic happens. That was
/// measured in the same round and is *not* reproduced here: it makes Excel's answers less
/// accurate rather than differently computed, and this package has already decided —
/// over the Bessel functions and `IMSQRT` — that it does not reproduce Excel's arithmetic
/// errors. The correction below is Excel computing differently; the digit limit is Excel
/// computing worse.
enum ExcelFinalRounding {

    /// Below this share of the larger operand, a difference is nothing.
    ///
    /// Measured to lie in `(1e-15, 2e-15]`. A decimal `1e-15` and a binary `2⁻⁴⁹ ≈ 1.78e-15`
    /// both fit, and the cases that would separate them were spoiled by Excel's 15-digit
    /// storage. `1e-15` is used because it is the value Microsoft documents, and the
    /// difference between the two candidates is unreachable from a spreadsheet.
    static let relativeThreshold = 1e-15

    /// The result of an addition or subtraction, corrected as Excel corrects it.
    ///
    /// - Parameters:
    ///   - result: What the arithmetic produced.
    ///   - lhs: The left operand.
    ///   - rhs: The right operand.
    /// - Returns: Zero where the result is negligible against the operands; `result` otherwise.
    static func corrected(_ result: Double, lhs: Double, rhs: Double) -> Double {
        guard result != 0, result.isFinite else { return result }
        let scale = Swift.max(abs(lhs), abs(rhs))
        // Nothing to be negligible against: `0 - 0` is zero already, and a scale of zero
        // would make every result negligible by division.
        guard scale > 0, scale.isFinite else { return result }
        return abs(result) < relativeThreshold * scale ? 0 : result
    }
}
