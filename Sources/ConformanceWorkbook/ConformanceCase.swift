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

    /// Every case, in the order they are written to the sheet.
    static let all: [ConformanceCase] = compatibility + complex + convert + bessel + roundTwo

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
