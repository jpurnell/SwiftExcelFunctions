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

        // A spilled result caches only its anchor. Excel writes the top-left cell of the
        // spill into the formula cell and the rest into the cells around it, so comparing a
        // cached value against our whole matrix compares a corner to a rectangle. Our anchor
        // matches Excel's in every one of these — the shape is measured by the `ROWS`,
        // `COLUMNS` and `SUM` rows beside them, which is what round ten wrapped its questions
        // for and what these six were left bare of.
        "GROUPBY({\"b\";\"a\";\"b\"}, {1;2;3}, SUM)":
            "a spill caches its anchor only; ours is the whole array. Anchor agrees: \"a\".",
        "GROUPBY({\"b\";\"a\";\"b\"}, {1;2;3}, SUM, 0, 0)":
            "a spill caches its anchor only. Anchor agrees: \"a\".",
        "GROUPBY({\"b\";\"a\";\"b\"}, {1;2;3}, SUM, 0, 1, -1)":
            "a spill caches its anchor only. Anchor agrees: \"b\".",
        "GROUPBY({\"B\";\"b\"}, {1;2}, SUM, 0, 0)":
            "a spill caches its anchor only. Anchor agrees: \"B\" — case-insensitive "
            + "grouping, keeping the casing first seen.",
        "GROUPBY({2;1;\"a\"}, {1;2;3}, SUM, 0, 0)":
            "a spill caches its anchor only. Anchor agrees: 1 — numbers sort before text.",
        "GROUPBY({\"a\";\"b\"}, {1;2}, AVERAGE)":
            "a spill caches its anchor only. Anchor agrees: \"a\".",
    ]

    /// Every case, in the order they are written to the sheet.
    static let all: [ConformanceCase] = compatibility + complex + convert + bessel + roundTwo + roundThree + roundFour + roundFive + roundSix + roundEight + roundNine + roundTen + roundEleven + roundTwelveBuild + roundTwelve

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
    /// **Answered.** Excel gives *three different conventions*, none derivable from another:
    ///
    /// | | shape < 1 | shape = 1 | shape > 1 |
    /// |---|---|---|---|
    /// | `CHISQ.DIST` | `#NUM!` | ½ — the density | 0 |
    /// | `GAMMA.DIST` | `#NUM!` | `#NUM!` — where the density is `1/β` | 0 |
    /// | `BETA.DIST` | `#NUM!` | `#NUM!` — where the density is 5 | 0 |
    /// | `WEIBULL.DIST` | **0** | **0** | 0 |
    /// | `F.DIST` | `#NUM!` | **1** — the density | 0 |
    ///
    /// `WEIBULL.DIST` answers a flat zero even where the density is unbounded. `CHISQ.DIST`
    /// and `F.DIST` honour the mathematics. `GAMMA.DIST` and `BETA.DIST` refuse one case the
    /// other two answer. Seven of the twenty-three rows came back disagreeing, and every one
    /// is now matched.
    ///
    /// **Three had been guessed wrong**, and the third is the instructive one: `GAMMA.DIST`
    /// and `WEIBULL.DIST` both answered `+∞` *as a number* before this round, which is
    /// unrepresentable in a cell; the guess that replaced it — `#NUM!`, by analogy with
    /// `CHISQ.DIST` — was right for `GAMMA.DIST` and wrong for `WEIBULL.DIST`. **Analogy
    /// between two Excel functions is not evidence about either**, which is the whole reason
    /// this file exists.
    ///
    /// **Each row has a control beside it** — an interior point of the same distribution,
    /// which this package and Excel already agree on. All controls held.
    ///
    /// Kept in the sheet now that they are answered, per this project's practice: a question
    /// that has been settled stays as a control, so a later round that goes wrong says so
    /// rather than looking like news.
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

    // MARK: - Round nine: the one boundary round eight did not ask

    /// `BETA.DIST` at its **upper** endpoint, below a shape of one.
    ///
    /// Round eight measured the lower endpoint across α < 1, α = 1 and α > 1, and the upper
    /// endpoint only at β = 5. The rule implemented from that — refuse at or below one,
    /// answer zero above — is applied to the upper endpoint **by symmetry with the lower**,
    /// and symmetry is exactly the kind of reasoning round eight just punished: `GAMMA.DIST`
    /// and `WEIBULL.DIST` face the same boundary and disagree with each other.
    ///
    /// So it was asked rather than assumed. **Answered: the inference held.** Excel refuses
    /// the upper endpoint at or below a shape of one and answers zero above it, mirroring the
    /// lower endpoint exactly — and `BETA.DIST(1, 2, 1, FALSE)` is `#NUM!` where the density
    /// is an ordinary 2.
    ///
    /// Worth keeping the reasoning rather than deleting it now that it came out right: being
    /// correct is not the same as being entitled to guess. `GAMMA.DIST` and `WEIBULL.DIST`
    /// face the same boundary and disagree, so the symmetry that held here was a coin that
    /// happened to land the right way up.
    ///
    /// Round nine returned **zero disagreements** across all 158 cases. No density boundary in
    /// this package now rests on an inference.
    static let roundNine: [ConformanceCase] = [
        .init(family: "density boundary", formula: "BETA.DIST(1, 2, 0.5, FALSE)",
              note: "upper endpoint, beta < 1: unbounded. We infer #NUM! from the lower end"),
        .init(family: "density boundary", formula: "BETA.DIST(1, 2, 1, FALSE)",
              note: "upper endpoint, beta = 1: the density is 2. We infer #NUM!"),
        .init(family: "density boundary", formula: "BETA.DIST(1, 2, 3, FALSE)",
              note: "upper endpoint, beta > 1: zero — the control, measured in round eight"),
        // The same question one function over, since GAMMA and WEIBULL proved that a rule
        // measured on one distribution says nothing about its neighbour.
        .init(family: "density boundary", formula: "F.DIST(0, 3, 5, FALSE)",
              note: "d1 = 3: just above the split, where zero is expected"),
        .init(family: "density boundary", formula: "CHISQ.DIST(0, 4, FALSE)",
              note: "df = 4: control for the chi-squared rule that round eight confirmed"),
    ]

    // MARK: - Round ten: GROUPBY and PIVOTBY, whose defaults are choices

    /// The optional arguments of `GROUPBY` and `PIVOTBY`.
    ///
    /// These are **Excel's own functions**, so unlike the `Psi*` family they can be asked.
    /// The grouping and aggregation are not in doubt; the defaults are:
    ///
    /// - Is a grand total row present when `total_depth` is omitted? This package appends one,
    ///   following Microsoft's documented default of 1 — which is documentation, and this
    ///   project's record with documentation is seven wrongs.
    /// - Where does the total row sit, above the groups or below?
    /// - What does an empty intersection hold in `PIVOTBY` — a blank, a zero, or `#N/A`? This
    ///   package answers blank, on the reasoning that no observation is not an observation of
    ///   nothing.
    /// - How is a mixed-type key column ordered, and are text keys matched case-insensitively?
    ///
    /// Each row pairs with a control whose answer is not in question, so a round where the
    /// controls move says so rather than looking like news.
    ///
    /// **Written with array constants so they need no sheet**, which is what lets `check`
    /// compare both columns the way it does for every other round. That spelling only became
    /// available today: `{1;2;3}` did not parse at all until this morning, and the first draft
    /// of this comment said these rows would come back as `!evaluation failed` because it was
    /// written before that was true. They evaluate.
    ///
    /// Two of the rows wrap their call in `SUM`, `ROWS` or `COLUMNS` on purpose. `GROUPBY`
    /// spills a table, and a spilled range is awkward to compare cell-for-cell across a
    /// workbook round trip — one number in one cell survives it intact.
    static let roundTen: [ConformanceCase] = [
        .init(family: "groupby", formula: "GROUPBY({\"b\";\"a\";\"b\"}, {1;2;3}, SUM)",
              note: "the shape: is a Total row present by default, and above or below?"),
        .init(family: "groupby", formula: "GROUPBY({\"b\";\"a\";\"b\"}, {1;2;3}, SUM, 0, 0)",
              note: "total_depth 0 — no totals, the control for the row above"),
        .init(family: "groupby", formula: "GROUPBY({\"b\";\"a\";\"b\"}, {1;2;3}, SUM, 0, 1, -1)",
              note: "descending: does -1 reverse the group order?"),
        .init(family: "groupby", formula: "GROUPBY({\"B\";\"b\"}, {1;2}, SUM, 0, 0)",
              note: "are text keys matched case-insensitively? We answer one group of 3"),
        .init(family: "groupby", formula: "GROUPBY({2;1;\"a\"}, {1;2;3}, SUM, 0, 0)",
              note: "a mixed key column: do numbers sort before text?"),
        .init(family: "groupby", formula: "GROUPBY({\"a\";\"b\"}, {1;2}, AVERAGE)",
              note: "the grand total of an average — over the data, or over the group means?"),
        .init(family: "groupby", formula: "SUM(GROUPBY({\"b\";\"a\";\"b\"}, {1;2;3}, SUM))",
              note: "one number rather than a spill, so the answer survives a single cell"),
        .init(family: "groupby", formula: "PIVOTBY({\"a\";\"b\"}, {\"x\";\"y\"}, {1;2}, SUM, 0, 0)",
              note: "an empty intersection: blank, zero, or #N/A? We answer blank"),
        .init(family: "groupby", formula: "ROWS(PIVOTBY({\"a\";\"b\"}, {\"x\";\"y\"}, {1;2}, SUM, 0, 0))",
              note: "the shape without the spill — is there a header row?"),
        .init(family: "groupby", formula: "COLUMNS(PIVOTBY({\"a\";\"b\"}, {\"x\";\"y\"}, {1;2}, SUM, 0, 0))",
              note: "and is there a corner cell?"),
    ]

    // MARK: - Round eleven: the date serial floor, which the corpus moved

    /// Where the date functions stop accepting a serial number.
    ///
    /// **This round exists because the corpus answered one of these and not the other five.**
    /// `Digital Sales Budget 2.0.xlsx` holds 1,664 cells reading `MONTH(AFn)` where `AFn`
    /// caches `0`, and Excel cached **1** for every one of them — with a control in the same
    /// column, `MONTH(AF4)` over serial 41640, answering 1 for January 2014. So Excel treats
    /// serial 0 as January 0, 1900: a date that does not exist, and is accepted anyway.
    ///
    /// This package guards `serial >= 1` and refuses with `#NUM!`. That guard is written **six
    /// times**, in `WEEKDAY`, `EOMONTH`, `EDATE`, `YEAR`, `MONTH` and `DAY`, and the corpus
    /// measured exactly one of them.
    ///
    /// **Moving the other five on the strength of `MONTH` is the inference this project has
    /// been wrong about seven times.** The seventh was `GAMMA.DIST` and `WEIBULL.DIST`, which
    /// face an identical density boundary and answer it differently. One function's floor
    /// says nothing about its neighbour's, so each is asked here.
    ///
    /// Three other boundaries ride along, because the workbook costs the same either way:
    ///
    /// - **Serial 60 is 1900-02-29**, a day that never happened — Excel keeps it to stay
    ///   bug-compatible with Lotus 1-2-3. What the date functions say about it is not
    ///   something this package should be guessing.
    /// - **Fractions.** Serial 0.5 is noon on that non-existent January 0.
    /// - **The ceiling**, at 9999-12-31, and one step past it.
    ///
    /// Every question is paired with a control whose answer is not in doubt, so a round that
    /// goes wrong says so rather than reading as news.
    static let roundEleven: [ConformanceCase] = [
        // The measured one, kept as a control now that the corpus has answered it.
        .init(family: "dateFloor", formula: "MONTH(0)",
              note: "MEASURED: the corpus says 1 — kept as the control for this round"),
        .init(family: "dateFloor", formula: "MONTH(41640)",
              note: "the corpus's own control: January 2014, answered 1 by both"),

        // The five the corpus did not answer.
        .init(family: "dateFloor", formula: "YEAR(0)", note: "1900, or #NUM!?"),
        .init(family: "dateFloor", formula: "DAY(0)", note: "0 for a zeroth day, or #NUM!?"),
        .init(family: "dateFloor", formula: "WEEKDAY(0)", note: "a weekday for a non-day?"),
        .init(family: "dateFloor", formula: "WEEKDAY(0, 2)",
              note: "and the same question with a return_type"),
        .init(family: "dateFloor", formula: "EOMONTH(0, 0)",
              note: "the end of the month containing a date that is not one"),
        .init(family: "dateFloor", formula: "EDATE(0, 0)", note: "zero months from nothing"),
        .init(family: "dateFloor", formula: "EDATE(0, 1)", note: "and one month from it"),

        // Serial 1 — the floor we currently enforce, and certainly valid.
        .init(family: "dateFloor", formula: "YEAR(1)", note: "control: 1900"),
        .init(family: "dateFloor", formula: "MONTH(1)", note: "control: 1"),
        .init(family: "dateFloor", formula: "DAY(1)", note: "control: 1"),
        .init(family: "dateFloor", formula: "WEEKDAY(1)", note: "control: 1 January 1900"),

        // Below the floor.
        .init(family: "dateFloor", formula: "MONTH(-1)", note: "below zero: #NUM! expected"),
        .init(family: "dateFloor", formula: "YEAR(-1)", note: "below zero"),
        .init(family: "dateFloor", formula: "DAY(-1)", note: "below zero"),
        .init(family: "dateFloor", formula: "WEEKDAY(-1)", note: "below zero"),
        .init(family: "dateFloor", formula: "EOMONTH(-1, 0)", note: "below zero"),
        .init(family: "dateFloor", formula: "EDATE(-1, 0)", note: "below zero"),

        // Fractions: noon on the day that does not exist.
        .init(family: "dateFloor", formula: "MONTH(0.5)", note: "is a fraction truncated?"),
        .init(family: "dateFloor", formula: "DAY(0.5)", note: "the same question for DAY"),
        .init(family: "dateFloor", formula: "YEAR(0.99)",
              note: "just under one — still the zeroth day?"),

        // The Lotus leap day. 1900 was not a leap year; Excel says it was.
        .init(family: "dateFloor", formula: "DAY(59)", note: "control: 28 February 1900"),
        .init(family: "dateFloor", formula: "DAY(60)",
              note: "29 February 1900, a day that never happened"),
        .init(family: "dateFloor", formula: "MONTH(60)", note: "and its month"),
        .init(family: "dateFloor", formula: "WEEKDAY(60)", note: "and its weekday"),
        .init(family: "dateFloor", formula: "DAY(61)", note: "control: 1 March 1900"),
        .init(family: "dateFloor", formula: "EOMONTH(60, 0)",
              note: "the end of a month containing a day that never happened"),

        // The ceiling.
        .init(family: "dateFloor", formula: "YEAR(2958465)", note: "control: 9999"),
        .init(family: "dateFloor", formula: "MONTH(2958465)", note: "control: 12"),
        .init(family: "dateFloor", formula: "DAY(2958465)", note: "control: 31"),
        .init(family: "dateFloor", formula: "YEAR(2958466)", note: "one past the end"),
        .init(family: "dateFloor", formula: "EOMONTH(2958465, 1)",
              note: "a month past the end — overflow, or a date Excel will not name?"),
    ]

    // MARK: - Round twelve: what the answering Excel knows, and GROUPBY in depth

    /// Which functions the Excel that answered this round actually has.
    ///
    /// **Round ten came back `#NAME?` on all ten `GROUPBY` rows and nothing in the workbook
    /// said why.** Working out that the build simply did not have the function took a session;
    /// `AppVersion` was no help, because every Excel since 2016 writes `16.0300`. A round that
    /// cannot say what answered it cannot be read later by anyone, including us.
    ///
    /// So each of these names one function and asks for a value small enough to check at a
    /// glance. A `#NAME?` here is not a disagreement — it is the build telling us what it is,
    /// and it dates the answering Excel far better than any metadata in the file.
    ///
    /// Every spilling result is wrapped in `SUM`, `ROWS` or `COLUMNS`. Round ten learned that:
    /// a spilled range is awkward to compare cell-for-cell across a workbook round trip, and
    /// one number in one cell survives it intact.
    ///
    /// **`LAMBDA` and `LET` are not asked here, and their absence is deliberate.** Both bind
    /// parameter names, and a stored one needs those spelled `_xlpm.x` as well as the function
    /// spelled `_xlfn.LAMBDA`; this emitter handles the function name only. Asking it in this round would have put an unanswerable
    /// question beside answerable ones and invited the same confusion the first attempt at
    /// this round produced — where 34 struck formulas read as a build without the functions.
    /// It wants `_xlpm.` support first, and then a round of its own.
    static let roundTwelveBuild: [ConformanceCase] = [
        .init(family: "build", formula: "XLOOKUP(2, {1;2;3}, {\"a\";\"b\";\"c\"})",
              note: "XLOOKUP — 2021 and 365. Expect \"b\""),
        .init(family: "build", formula: "SUM(FILTER({1;2;3}, {TRUE;FALSE;TRUE}))",
              note: "FILTER — the dynamic array release. Expect 4"),
        .init(family: "build", formula: "ROWS(UNIQUE({1;1;2}))",
              note: "UNIQUE — same release. Expect 2"),
        .init(family: "build", formula: "SUM(SEQUENCE(3))",
              note: "SEQUENCE — same release. Expect 6"),
        .init(family: "build", formula: "INDEX(SORT({3;1;2}), 1)",
              note: "SORT — same release. Expect 1"),
        .init(family: "build", formula: "COLUMNS(TEXTSPLIT(\"a,b\", \",\"))",
              note: "TEXTSPLIT — 2022 and 365. Expect 2"),
        .init(family: "build", formula: "SUM(TOCOL({1,2;3,4}))",
              note: "TOCOL — 2022 and 365. Expect 10"),
    ]

    /// The `GROUPBY` and `PIVOTBY` arguments round ten could not reach.
    ///
    /// Round ten asked the shape questions and got `#NAME?` for every one of them, so none of
    /// it is settled. These go further than that round did, into the arguments this package
    /// accepts in its signature — `maxArgs` is 8 for `GROUPBY` and 11 for `PIVOTBY` — but
    /// implements only the first few of. Where we answer an error, that is this package
    /// saying so honestly, and the Excel column is the measurement.
    ///
    /// Round ten's own ten rows are still asked, from ``roundTen``, and they are the controls
    /// for this round: if they come back `#NAME?` again then the build has not changed and
    /// nothing here can be read.
    static let roundTwelve: [ConformanceCase] = [
        // total_depth beyond 0 and 1.
        .init(family: "groupby2", formula: "ROWS(GROUPBY({\"a\";\"a\";\"b\"}, {1;2;3}, SUM, 0, 2))",
              note: "total_depth 2 — do subtotals appear, and how many rows result?"),
        .init(family: "groupby2", formula: "ROWS(GROUPBY({\"a\";\"a\";\"b\"}, {1;2;3}, SUM, 0, -1))",
              note: "a negative total_depth — totals above rather than below?"),

        // field_headers: present, absent, and detected.
        .init(family: "groupby2",
              formula: "ROWS(GROUPBY({\"k\";\"a\";\"b\"}, {\"v\";1;2}, SUM, 1))",
              note: "field_headers 1 — is the first row consumed as a header?"),
        .init(family: "groupby2",
              formula: "ROWS(GROUPBY({\"k\";\"a\";\"b\"}, {\"v\";1;2}, SUM, 0))",
              note: "field_headers 0 — and treated as data when told not to?"),
        .init(family: "groupby2",
              formula: "ROWS(GROUPBY({\"k\";\"a\";\"b\"}, {\"v\";1;2}, SUM))",
              note: "omitted — the documented default is 'detect'. Does it?"),

        // sort_order selecting a column rather than a direction.
        .init(family: "groupby2",
              formula: "INDEX(GROUPBY({\"a\";\"b\"}, {2;1}, SUM, 0, 0, 2), 1, 1)",
              note: "sort_order 2 — sort by the values column? Which key comes first?"),
        .init(family: "groupby2",
              formula: "INDEX(GROUPBY({\"a\";\"b\"}, {2;1}, SUM, 0, 0, -2), 1, 1)",
              note: "and -2 — the same column, descending?"),

        // filter_array.
        .init(family: "groupby2",
              formula: "SUM(GROUPBY({\"a\";\"b\";\"c\"}, {1;2;3}, SUM, 0, 0, 1, {TRUE;FALSE;TRUE}))",
              note: "filter_array — is the middle row excluded? Expect 4 if so"),

        // Aggregates that are not sums.
        .init(family: "groupby2", formula: "SUM(GROUPBY({\"a\";\"a\";\"b\"}, {1;2;3}, COUNT, 0, 0))",
              note: "COUNT as the aggregate — expect 3 over two groups"),
        .init(family: "groupby2", formula: "SUM(GROUPBY({\"a\";\"a\";\"b\"}, {1;2;3}, MAX, 0, 0))",
              note: "MAX — expect 5"),

        // PIVOTBY's two independent total depths.
        .init(family: "groupby2",
              formula: "ROWS(PIVOTBY({\"a\";\"b\"}, {\"x\";\"y\"}, {1;2}, SUM))",
              note: "both total depths defaulted — how tall?"),
        .init(family: "groupby2",
              formula: "COLUMNS(PIVOTBY({\"a\";\"b\"}, {\"x\";\"y\"}, {1;2}, SUM))",
              note: "and how wide?"),
        .init(family: "groupby2",
              formula: "ROWS(PIVOTBY({\"a\";\"b\"}, {\"x\";\"y\"}, {1;2}, SUM, 0, 0, 1, 1, 0))",
              note: "row_total_depth 0, col_total_depth 1 — are they independent?"),
        .init(family: "groupby2",
              formula: "SUM(PIVOTBY({\"a\";\"b\";\"a\"}, {\"x\";\"y\";\"x\"}, {1;2;3}, SUM, 0, 0))",
              note: "a repeated intersection — is 1+3 summed into one cell?"),
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
