import Foundation
import SwiftExcelCore
import SwiftExcelFunctions

/// One question to put to Excel.
///
/// A case is a **single formula string**. Excel computes it because the workbook stores it
/// as a formula; this package computes it by parsing and evaluating the same string. There is
/// no second expression to keep in step with the first, which is the only way two independent
/// answers to "the same question" are actually answers to the same question.
struct ConformanceCase: Sendable {
    /// Which family this belongs to, so a failure points somewhere.
    let family: String
    /// The formula, without a leading `=`.
    let formula: String
    /// Why this case is here — what it would catch.
    let note: String
}

/// Everything this package computes that has never been checked against Excel.
///
/// ## What is missing from here, and why
///
/// Not everything unverified is worth a row. The twenty-one compatibility functions that are
/// plain aliases delegate to a modern function: if `CHISQ.DIST.RT` is right then `CHIDIST`
/// is right, because it *is* `CHISQ.DIST.RT`. A handful appear anyway as a spot check on the
/// delegation itself, but the rows concentrate on the five that are **not** aliases, the
/// suffix rules in the complex family, and the two inferences in `CONVERT` — the places
/// where this package made a judgement rather than followed a delegation.
enum ConformanceCases {

    /// Cases where this package and Excel disagree **and this package is right**.
    ///
    /// ## Why these are recorded rather than fixed
    ///
    /// Matching Excel here would mean reproducing its arithmetic error on purpose. Every one
    /// was checked against a third implementation or against a definition, so "we are right"
    /// is measured rather than asserted: scipy agrees with this package to 1.0 × 10⁻¹⁵ or
    /// better on all eight Bessel points while Excel is off by up to 1.6 × 10⁻⁷, and
    /// `BESSELJ(0, 0)` needs no reference at all because J₀(0) is exactly 1.
    ///
    /// ## What this list is for
    ///
    /// It is the difference between a report and a gate. Without it every run shows the same
    /// ten disagreements and a new one hides in the noise; with it, **a new disagreement is
    /// the only thing `check` reports as a failure**, and the tool can be run after any
    /// change to the functions it covers.
    static let knownDivergences: [String: String] = [
        "BESSELJ(0, 0)": "J₀(0) is exactly 1 by definition. Excel returns 1.00000000283141.",
        "BESSELJ(1, 0)": "scipy agrees with this package to 1e-15; Excel is off by 3.7e-9.",
        "BESSELY(2.5, 0)": "scipy agrees with this package to 1e-15; Excel is off by 2.4e-9.",
        "BESSELY(7, 2)": "scipy agrees with this package to 1e-15; Excel is off by 1.6e-7.",
        "BESSELI(2.5, 0)": "scipy agrees with this package to 8e-16; Excel is off by 8.6e-9.",
        "BESSELI(7, 3)": "scipy agrees with this package to 7e-16; Excel is off by 4.4e-9.",
        "BESSELI(0.5, 1)": "scipy agrees with this package to 4e-16; Excel is off by 8.2e-9.",
        "BESSELK(1, 1)": "scipy agrees with this package to 4e-16; Excel is off by 2.4e-9.",
        "IMSQRT(\"-1\")": "√-1 is exactly i. Excel goes through polar form and keeps 6.1e-17.",
        "IMSQRT(\"-4\")": "√-4 is exactly 2i. Excel keeps 1.2e-16 of polar rounding.",
        "IMPOWER(\"i\", 2)": "i² is exactly -1. Excel returns -1+1.22464679914735E-16i, "
            + "computing it as exp(log(i)·2); this multiplies instead.",
    ]

    /// Every case, in the order they are written to the sheet.
    static let all: [ConformanceCase] = compatibility + complex + convert + bessel + roundTwo + roundThree + roundFour + roundFive + roundSix + roundEight

    // MARK: - The five that are not aliases, and spot checks on the ones that are

    static let compatibility: [ConformanceCase] = [
        .init(family: "compatibility", formula: "TDIST(1.5, 8, 1)",
              note: "one tail — must equal T.DIST.RT, not half of the two-tailed answer"),
        .init(family: "compatibility", formula: "TDIST(1.5, 8, 2)",
              note: "two tails — must equal T.DIST.2T"),
        .init(family: "compatibility", formula: "T.DIST.RT(1.5, 8)",
              note: "the reference for the one-tailed reading"),
        .init(family: "compatibility", formula: "T.DIST.2T(1.5, 8)",
              note: "the reference for the two-tailed reading"),
        .init(family: "compatibility", formula: "TDIST(-1.5, 8, 2)",
              note: "negative x — documented as #NUM! for TDIST though T.DIST accepts it"),
        .init(family: "compatibility", formula: "TDIST(1.5, 8, 3)",
              note: "tails is 1 or 2 and nothing else"),
        .init(family: "compatibility", formula: "BETADIST(0.4, 2, 3)",
              note: "cumulative by definition — must equal BETA.DIST(...,TRUE)"),
        .init(family: "compatibility", formula: "BETA.DIST(0.4, 2, 3, TRUE)",
              note: "the reference for BETADIST"),
        .init(family: "compatibility", formula: "BETADIST(4, 2, 3, 0, 10)",
              note: "the bounds shift by one because cumulative sits before them"),
        .init(family: "compatibility", formula: "LOGNORMDIST(2, 1, 0.5)",
              note: "cumulative only — must equal LOGNORM.DIST(...,TRUE)"),
        .init(family: "compatibility", formula: "LOGNORM.DIST(2, 1, 0.5, TRUE)",
              note: "the reference for LOGNORMDIST"),
        .init(family: "compatibility", formula: "HYPGEOMDIST(1, 4, 8, 20)",
              note: "the mass function — must equal HYPGEOM.DIST(...,FALSE)"),
        .init(family: "compatibility", formula: "HYPGEOM.DIST(1, 4, 8, 20, FALSE)",
              note: "the reference for HYPGEOMDIST"),
        .init(family: "compatibility", formula: "NEGBINOMDIST(3, 5, 0.4)",
              note: "the mass function — must equal NEGBINOM.DIST(...,FALSE)"),
        .init(family: "compatibility", formula: "NEGBINOM.DIST(3, 5, 0.4, FALSE)",
              note: "the reference for NEGBINOMDIST"),
        .init(family: "compatibility", formula: "CHIDIST(3.5, 4)",
              note: "spot check on a delegation: right-tailed, not left"),
        .init(family: "compatibility", formula: "CRITBINOM(10, 0.3, 0.6)",
              note: "spot check: the rename to BINOM.INV kept nothing of the old name"),
        // QUARTILE and PERCENTRANK want a range, and an array literal — `{1;2;3}` — is not
        // something this package's parser reads. They are plain aliases and safe by
        // delegation, so they are left out rather than given a sheet to point at: a case
        // that needs scaffolding is a case whose failure would be about the scaffolding.
    ]

    // MARK: - The complex family, where the text rules are ours to get wrong

    static let complex: [ConformanceCase] = [
        .init(family: "complex", formula: "COMPLEX(7, 0)",
              note: "THE open question: is a zero imaginary part written bare, as \"7\"?"),
        .init(family: "complex", formula: "COMPLEX(0, 1)",
              note: "is the unit written as \"i\" alone?"),
        .init(family: "complex", formula: "COMPLEX(0, 4)",
              note: "is a zero real part omitted entirely?"),
        .init(family: "complex", formula: "COMPLEX(3, -4)",
              note: "a negative imaginary part takes no separate operator"),
        .init(family: "complex", formula: "COMPLEX(3, 4, \"j\")",
              note: "the j suffix is carried"),
        .init(family: "complex", formula: "COMPLEX(3, 4, \"I\")",
              note: "uppercase is documented as #VALUE!"),
        .init(family: "complex", formula: "IMSUM(\"1+1i\", \"1+1j\")",
              note: "INFERRED: mixed suffixes assumed #VALUE! — not documented anywhere"),
        .init(family: "complex", formula: "IMSUM(\"3\", \"4\")",
              note: "two reals — is the result \"7\" with no suffix?"),
        .init(family: "complex", formula: "IMABS(\"3+4I\")",
              note: "uppercase suffix in an argument"),
        .init(family: "complex", formula: "IMABS(\"3+4\")",
              note: "a missing suffix — #NUM! rather than an implied i?"),
        .init(family: "complex", formula: "IMABS(\"banana\")",
              note: "text that is not a complex number"),
        .init(family: "complex", formula: "IMARGUMENT(\"0\")",
              note: "the argument of zero — #DIV/0! rather than 0?"),
        .init(family: "complex", formula: "IMLN(\"0\")", note: "log of zero"),
        .init(family: "complex", formula: "IMDIV(\"3+4i\", \"0\")", note: "division by zero"),
        .init(family: "complex", formula: "IMSQRT(\"3+4i\")", note: "a value with a known exact answer"),
        .init(family: "complex", formula: "IMPOWER(\"1+1i\", 3)", note: "an integral power"),
        .init(family: "complex", formula: "IMEXP(\"1+1i\")", note: "formatting of a long decimal"),
        .init(family: "complex", formula: "IMSEC(\"1+1i\")", note: "a reciprocal spelling"),
        .init(family: "complex", formula: "IMCOT(\"1+1i\")", note: "a reciprocal spelling"),
        .init(family: "complex", formula: "IMLOG2(\"3+4i\")", note: "a change of base"),
    ]

    // MARK: - CONVERT, including both inferences

    static let convert: [ConformanceCase] = [
        .init(family: "convert", formula: "CONVERT(1, \"ft\", \"in\")", note: "exact by definition"),
        .init(family: "convert", formula: "CONVERT(1, \"mi\", \"ft\")", note: "exact by definition"),
        .init(family: "convert", formula: "CONVERT(1, \"lbm\", \"ozm\")", note: "exact by definition"),
        .init(family: "convert", formula: "CONVERT(1, \"gal\", \"qt\")", note: "exact by definition"),
        .init(family: "convert", formula: "CONVERT(1, \"byte\", \"bit\")", note: "exact by definition"),
        .init(family: "convert", formula: "CONVERT(0, \"C\", \"F\")", note: "the affine offset"),
        .init(family: "convert", formula: "CONVERT(100, \"C\", \"F\")", note: "the affine slope"),
        .init(family: "convert", formula: "CONVERT(0, \"C\", \"K\")", note: "absolute zero offset"),
        .init(family: "convert", formula: "CONVERT(20, \"C\", \"Reau\")", note: "the Réaumur scale"),
        .init(family: "convert", formula: "CONVERT(1, \"km2\", \"m2\")",
              note: "a prefix on an area — squared, or not?"),
        .init(family: "convert", formula: "CONVERT(1, \"km3\", \"m3\")",
              note: "a prefix on a volume — cubed, or not?"),
        .init(family: "convert", formula: "CONVERT(1, \"kibyte\", \"byte\")", note: "a binary prefix"),
        .init(family: "convert", formula: "CONVERT(1, \"mn\", \"sec\")",
              note: "mn is a minute — if it reads as milli-newton this is wrong"),
        .init(family: "convert", formula: "CONVERT(1, \"cwt\", \"lbm\")",
              note: "cwt is a hundredweight, not a centi-watt"),
        .init(family: "convert", formula: "CONVERT(1, \"c\", \"J\")",
              note: "c is the thermodynamic calorie; cal is the IT one"),
        .init(family: "convert", formula: "CONVERT(1, \"cal\", \"J\")",
              note: "and they differ in the fourth digit"),
        .init(family: "convert", formula: "CONVERT(1, \"Picapt\", \"in\")",
              note: "Picapt is 1/72 inch; pica is 1/6"),
        .init(family: "convert", formula: "CONVERT(1, \"pica\", \"in\")", note: "the other pica"),
        .init(family: "convert", formula: "CONVERT(1, \"mK\", \"K\")",
              note: "INFERRED: prefixes assumed refused on temperature"),
        .init(family: "convert", formula: "CONVERT(1, \"furlong\", \"m\")",
              note: "INFERRED: an unknown unit assumed #N/A"),
        .init(family: "convert", formula: "CONVERT(1, \"kft\", \"m\")",
              note: "a prefix on a non-metric unit"),
        .init(family: "convert", formula: "CONVERT(1, \"m\", \"g\")", note: "across measures"),
        .init(family: "convert", formula: "CONVERT(1, \"uk_acre\", \"m2\")", note: "the two acres differ"),
        .init(family: "convert", formula: "CONVERT(1, \"us_acre\", \"m2\")", note: "and this is the other"),
        .init(family: "convert", formula: "CONVERT(1, \"kn\", \"m/s\")", note: "a knot"),
        .init(family: "convert", formula: "CONVERT(1, \"admkn\", \"m/s\")", note: "the admiralty knot"),
    ]

    // MARK: - Round two: what the first round raised

    /// Questions the first round created rather than answered.
    ///
    /// Excel allowed `mK`, which this package had refused. It scales the magnitude, which is
    /// unambiguous on an absolute scale and a guess on a scale with an offset — so the guess
    /// goes back to Excel rather than into the source as a comment.
    static let roundTwo: [ConformanceCase] = [
        .init(family: "round2", formula: "CONVERT(1, \"mC\", \"C\")",
              note: "does a prefix compose with an offset scale, or only an absolute one?"),
        .init(family: "round2", formula: "CONVERT(1000, \"mC\", \"C\")",
              note: "and if it does, is it a plain scaling of the magnitude?"),
        .init(family: "round2", formula: "CONVERT(1, \"mF\", \"F\")",
              note: "the same question for Fahrenheit"),
        .init(family: "round2", formula: "CONVERT(1, \"kK\", \"K\")",
              note: "a prefix upward, to check it is not milli-only"),
        .init(family: "round2", formula: "IMABS(\"3+4J\")",
              note: "uppercase J — #NUM! like uppercase I, measured last round?"),
        .init(family: "round2", formula: "IMSUM(\"1+1i\", \"2\")",
              note: "a suffixed and an unsuffixed argument together — not a disagreement"),
        .init(family: "round2", formula: "IMPRODUCT(\"2i\", \"2i\")",
              note: "a purely imaginary product, which should land on a bare real -4"),
        .init(family: "round2", formula: "IMSQRT(\"-1\")",
              note: "the principal root of a negative real"),
        .init(family: "round2", formula: "IMPOWER(\"1+1i\", 0.5)",
              note: "a fractional power, which takes the other code path"),
        .init(family: "round2", formula: "IMLN(\"-1\")",
              note: "a logarithm landing exactly on a multiple of pi"),
        .init(family: "round2", formula: "BESSELJ(0, 0)", note: "J at the origin is exactly 1"),
        .init(family: "round2", formula: "BESSELI(0.5, 1)",
              note: "a small argument, where the series should be most accurate"),
        .init(family: "round2", formula: "BESSELY(1, 1)",
              note: "another point, to say whether the Y error is systematic"),
        .init(family: "round2", formula: "BESSELK(1, 1)",
              note: "K agreed last round; a second point to confirm"),
    ]

    // MARK: - Round three: what round two raised

    /// Round two answered `mK` yes and `mC`/`mF` no, which leaves the absolute scales that
    /// are not kelvin unmeasured. The pattern says `Rank` should take a prefix and `Reau`
    /// should not; the pattern has been wrong twice on this exact question, so it is asked.
    static let roundThree: [ConformanceCase] = [
        .init(family: "round3", formula: "CONVERT(1, \"mRank\", \"Rank\")",
              note: "Rank is absolute — does it take a prefix as K does?"),
        .init(family: "round3", formula: "CONVERT(1, \"mReau\", \"Reau\")",
              note: "Reau has an offset — refused as C and F are?"),
        .init(family: "round3", formula: "CONVERT(1, \"kK\", \"mK\")",
              note: "a prefix on both sides at once"),
        .init(family: "round3", formula: "IMSQRT(\"-4\")",
              note: "does Excel keep the polar rounding error here too, or only at -1?"),
        .init(family: "round3", formula: "IMLN(\"-1\")",
              note: "the same question for a logarithm landing on pi"),
        .init(family: "round3", formula: "IMPOWER(\"i\", 2)",
              note: "i squared is exactly -1; does Excel say so?"),
        .init(family: "round3", formula: "BESSELJ(1, 0)",
              note: "one more point to size Excel's Bessel error"),
        .init(family: "round3", formula: "BESSELY(0.5, 0)",
              note: "Y near the origin, where it diverges fastest"),
    ]

    // MARK: - Round four: the size of the grid

    /// How big Excel's sheet actually is.
    ///
    /// 16,384 columns by 1,048,576 rows has been the answer since Excel 2007 introduced the
    /// XML format, and both this package and SwiftExcelCore encode it. It is being asked
    /// anyway, because a bound about to be written into a shared library on the strength of
    /// "everyone knows this" is exactly the sort of thing this project has been wrong about
    /// five times — and `COLUMNS(1:1)` settles it in one cell.
    static let roundFour: [ConformanceCase] = [
        .init(family: "grid", formula: "COLUMNS(1:1)",
              note: "a whole row — 16384, if the grid is what it has been since 2007"),
        .init(family: "grid", formula: "ROWS(A:A)",
              note: "a whole column — 1048576"),
        .init(family: "grid", formula: "COLUMNS($A$1:$XFD$1)",
              note: "the same row written out, in case the shorthand parses differently"),
        .init(family: "grid", formula: "COLUMN($XFD$1)",
              note: "XFD's index, which is the column count if XFD is the last"),
        .init(family: "grid", formula: "ROWS($A$1:$A$1048576)",
              note: "the same column written out"),
    ]

    // MARK: - Round five: when Excel decides a number is zero

    /// Excel snaps a result to exactly zero when subtraction has cancelled nearly all of it,
    /// and this package does not.
    ///
    /// Fifteen cells in one corpus disagree for this reason alone — `D50-B50` computing
    /// `-1.4551915228366852e-11` where Excel writes `0`. The values are not in dispute: both
    /// sides do the same IEEE arithmetic and get the same bits. What differs is that Excel
    /// then decides the answer was meant to be nothing.
    ///
    /// **Knowing the rule is worth more than fixing the fifteen.** These cases are built to
    /// find its shape rather than to confirm it exists:
    ///
    /// - whether the snap depends on *cancellation* or merely on being small
    /// - whether it survives another operation afterwards
    /// - whether it scales with the operands' magnitude, as a relative epsilon would
    /// - whether comparison sees the snapped value or the real one
    static let roundFive: [ConformanceCase] = [
        // The classics: exact zero is intended, IEEE leaves a residue.
        .init(family: "snap", formula: "0.1+0.2-0.3",
              note: "the canonical case — IEEE leaves 5.55e-17"),
        .init(family: "snap", formula: "1.1-1-0.1", note: "residue about 2.8e-17"),
        .init(family: "snap", formula: "0.5-0.4-0.1", note: "residue about -2.8e-17"),

        // Magnitude: a relative rule should snap all of these, an absolute one only some.
        .init(family: "snap", formula: "100000.1-100000-0.1",
              note: "residue near 1e-11 — the scale the corpus cells sit at"),
        .init(family: "snap", formula: "10000000.1-10000000-0.1",
              note: "residue near 1e-9, two orders larger"),
        .init(family: "snap", formula: "1000000000.1-1000000000-0.1",
              note: "residue near 1e-7 — still relatively tiny, absolutely not"),

        // Small but honest: no cancellation, so nothing should be snapped away.
        .init(family: "snap", formula: "0.00000000001",
              note: "1e-11 written down — if this became 0, the rule is about size alone"),
        .init(family: "snap", formula: "0.00000000001*1",
              note: "the same, arrived at by multiplication"),
        .init(family: "snap", formula: "0.00000000001/10",
              note: "1e-12 by division"),

        // Does the snap survive a later operation?
        .init(family: "snap", formula: "(0.1+0.2-0.3)*1",
              note: "multiplied after cancelling — snapped before, or after?"),
        .init(family: "snap", formula: "(0.1+0.2-0.3)+0",
              note: "added to nothing afterwards"),
        .init(family: "snap", formula: "(0.1+0.2-0.3)*1000000",
              note: "scaled up — 5.55e-11 if the residue survived"),
        .init(family: "snap", formula: "SUM(0.1,0.2,-0.3)",
              note: "the same cancellation inside SUM rather than between operators"),

        // What sees the snapped value?
        .init(family: "snap", formula: "IF(0.1+0.2-0.3=0,\"zero\",\"not zero\")",
              note: "does a comparison see the snap?"),
        .init(family: "snap", formula: "IF(0.1+0.2=0.3,\"equal\",\"not equal\")",
              note: "and the classic form of the same question"),
        .init(family: "snap", formula: "(0.1+0.2-0.3)=0",
              note: "the comparison on its own"),
        .init(family: "snap", formula: "SIGN(0.1+0.2-0.3)",
              note: "sign of the residue — 0 if snapped, 1 if not"),

        // Where the boundary sits.
        .init(family: "snap", formula: "1-0.9999999999999",
              note: "1e-13 — a real difference, well above any residue"),
        .init(family: "snap", formula: "1-0.999999999999999",
              note: "1e-15, approaching the last bits of a double"),
        .init(family: "snap", formula: "1-0.9999999999999999",
              note: "1e-16 — below a double's resolution at 1, so exactly 0 anyway"),
    ]

    // MARK: - Round six: where the snapping threshold sits

    /// Round five found the rule; this finds its edge.
    ///
    /// The rule: on a final addition or subtraction, Excel returns exactly zero when the
    /// result is negligible against the operands. Round five bracketed the threshold only
    /// loosely — a relative size of 1.0 × 10⁻¹⁵ snapped and 1.0 × 10⁻¹³ did not, which leaves
    /// two orders of magnitude unexplored.
    ///
    /// Each case is `1 − (1 − r)`, so the operands are both about 1 and the result is `r`.
    /// That makes the relative size the only thing varying.
    static let roundSix: [ConformanceCase] = [
        .init(family: "threshold", formula: "1-0.99999999999999",
              note: "r = 1e-14"),
        .init(family: "threshold", formula: "1-0.999999999999995",
              note: "r = 5e-15"),
        .init(family: "threshold", formula: "1-0.999999999999997",
              note: "r = 3e-15"),
        .init(family: "threshold", formula: "1-0.999999999999998",
              note: "r = 2e-15"),
        .init(family: "threshold", formula: "1-0.9999999999999985",
              note: "r = 1.5e-15"),
        .init(family: "threshold", formula: "1-0.9999999999999995",
              note: "r = 5e-16 — below the last snapping case from round five"),
        // 2^-48 is 3.55e-15 and sits inside the bracket; worth naming in case the
        // threshold is a power of two rather than a decimal.
        .init(family: "threshold", formula: "1-0.9999999999999964",
              note: "r near 2^-48 = 3.55e-15, in case the bound is binary"),
    ]

    // MARK: - Round eight: the density at a support boundary

    /// **Five functions face the same three-way split, and answer it four different ways.**
    ///
    /// Where a shape parameter sits under a power of `x`, the density at the boundary is
    /// unbounded below a shape of one, finite at exactly one, and zero above. That is the
    /// mathematics and it is not in doubt. What Excel *reports* for the unbounded case is a
    /// spreadsheet convention, and this package has never asked.
    ///
    /// It shows, because the four answers are ours rather than Excel's:
    ///
    /// | | at the boundary, shape < 1 | shape = 1 | shape > 1 |
    /// |---|---|---|---|
    /// | `CHISQ.DIST` | `#NUM!` | ½ | 0 |
    /// | `GAMMA.DIST` | `#NUM!` — was `+∞` as a **number** until this round | 1/β | 0 |
    /// | `WEIBULL.DIST` | `#NUM!` — same, same round | 1/β | 0 |
    /// | `BETA.DIST` | `#NUM!` | `#NUM!` — where the density is finite and non-zero | `#NUM!` |
    /// | `F.DIST` | **0** | **0** — where the density is exactly 1 | 0 |
    ///
    /// The last two rows are the ones that cannot all be right. `BETA.DIST(0, 1, 5, FALSE)`
    /// refuses a density that is exactly 5; `F.DIST(0, 2, 5, FALSE)` answers zero where the
    /// density is exactly 1, and `F.DIST(0, 1, 5, FALSE)` answers zero where it is unbounded.
    ///
    /// **Each row below has a control beside it** — an interior point of the same
    /// distribution, which this package and Excel already agree on. A round where the
    /// controls move is a round that went wrong, and says so rather than looking like news.
    static let roundEight: [ConformanceCase] = [
        // The question this round was opened for.
        .init(family: "density boundary", formula: "F.DIST(0, 1, 5, FALSE)",
              note: "unbounded: d1 = 1. We answer 0. Excel?"),
        .init(family: "density boundary", formula: "F.DIST(0, 2, 5, FALSE)",
              note: "the density here is exactly 1. We answer 0. Excel?"),
        .init(family: "density boundary", formula: "F.DIST(0, 5, 8, FALSE)",
              note: "d1 > 2, so zero is correct — the control for the two above"),
        .init(family: "density boundary", formula: "F.DIST(0.5, 5, 8, FALSE)",
              note: "interior control: already agreed"),

        // The one case in the family that was already decided, and never measured either.
        .init(family: "density boundary", formula: "CHISQ.DIST(0, 1, FALSE)",
              note: "unbounded. We answer #NUM! — this is where that convention came from"),
        .init(family: "density boundary", formula: "CHISQ.DIST(0, 2, FALSE)",
              note: "exactly two: the density is ½"),
        .init(family: "density boundary", formula: "CHISQ.DIST(0, 3, FALSE)",
              note: "above two: zero"),
        .init(family: "density boundary", formula: "CHISQ.DIST(2, 5, FALSE)",
              note: "interior control: already agreed"),

        .init(family: "density boundary", formula: "GAMMA.DIST(0, 0.5, 2, FALSE)",
              note: "unbounded. Answered +INF as a number until this round; now #NUM!"),
        .init(family: "density boundary", formula: "GAMMA.DIST(0, 1, 2, FALSE)",
              note: "shape one: the density is 1/scale = 0.5"),
        .init(family: "density boundary", formula: "GAMMA.DIST(0, 3, 2, FALSE)",
              note: "shape above one: zero"),
        .init(family: "density boundary", formula: "GAMMA.DIST(4, 3, 2, FALSE)",
              note: "interior control: already agreed"),

        .init(family: "density boundary", formula: "WEIBULL.DIST(0, 0.5, 3, FALSE)",
              note: "unbounded. Answered +INF as a number until this round; now #NUM!"),
        .init(family: "density boundary", formula: "WEIBULL.DIST(0, 1, 3, FALSE)",
              note: "shape one: the density is 1/scale = 0.3333…"),
        .init(family: "density boundary", formula: "WEIBULL.DIST(0, 2, 3, FALSE)",
              note: "shape above one: zero"),
        .init(family: "density boundary", formula: "WEIBULL.DIST(2, 2, 3, FALSE)",
              note: "interior control: already agreed"),

        // BETA.DIST refuses its endpoints unconditionally. Two of these three have a
        // perfectly ordinary density there.
        .init(family: "density boundary", formula: "BETA.DIST(0, 0.5, 5, FALSE)",
              note: "unbounded: alpha < 1. We answer #NUM!"),
        .init(family: "density boundary", formula: "BETA.DIST(0, 1, 5, FALSE)",
              note: "the density here is exactly 5. We answer #NUM!. Excel?"),
        .init(family: "density boundary", formula: "BETA.DIST(0, 2, 5, FALSE)",
              note: "the density here is exactly 0. We answer #NUM!. Excel?"),
        .init(family: "density boundary", formula: "BETA.DIST(1, 2, 5, FALSE)",
              note: "the upper endpoint, density 0. We answer #NUM!. Excel?"),
        .init(family: "density boundary", formula: "BETA.DIST(0.4, 2, 5, FALSE)",
              note: "interior control: already agreed"),

        // Two boundaries that are not the three-way split, for contrast.
        .init(family: "density boundary", formula: "LOGNORM.DIST(0, 0, 1, FALSE)",
              note: "x = 0 is outside the support outright, not a shape case"),
        .init(family: "density boundary", formula: "EXPON.DIST(0, 1.5, FALSE)",
              note: "the exponential starts at lambda; no shape, so no split"),
    ]

    // MARK: - Bessel

    static let bessel: [ConformanceCase] = [
        .init(family: "bessel", formula: "BESSELJ(2.5, 0)", note: "J at a middling argument"),
        .init(family: "bessel", formula: "BESSELJ(2.5, 1)", note: "order one"),
        .init(family: "bessel", formula: "BESSELJ(7, 3)", note: "further out, higher order"),
        .init(family: "bessel", formula: "BESSELY(2.5, 0)", note: "the second kind"),
        .init(family: "bessel", formula: "BESSELY(7, 2)", note: "second kind, higher order"),
        .init(family: "bessel", formula: "BESSELI(2.5, 0)", note: "the modified first kind"),
        .init(family: "bessel", formula: "BESSELI(7, 3)", note: "modified, growing"),
        .init(family: "bessel", formula: "BESSELK(2.5, 0)", note: "the modified second kind"),
        .init(family: "bessel", formula: "BESSELK(7, 2)", note: "modified, decaying"),
        .init(family: "bessel", formula: "BESSELJ(2.5, 1.9)",
              note: "a fractional order — truncated to 1, or rounded to 2?"),
        .init(family: "bessel", formula: "BESSELJ(1, -1)", note: "a negative order"),
        .init(family: "bessel", formula: "BESSELK(0, 0)",
              note: "INFERRED: K at the origin assumed #NUM!"),
        .init(family: "bessel", formula: "BESSELY(-1, 0)",
              note: "INFERRED: Y below the origin assumed #NUM!"),
    ]
}
