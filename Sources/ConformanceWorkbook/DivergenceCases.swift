import Foundation

/// Points where this package and Excel disagree, with an independent reference for each.
///
/// ## Why a third number is in the sheet
///
/// "We disagree with Excel" is not a claim about who is right, and the first conformance
/// round proved that by getting it backwards: four Bessel differences were written up as an
/// accuracy problem in BusinessMath on no evidence beyond its being the newer of the two.
/// A third implementation reversed the answer in one command.
///
/// So every row here carries a reference value that is neither Excel's nor this package's,
/// and the sheet has Excel compute its own error against it. Nobody has to take the claim on
/// trust, least of all whoever reads it next.
///
/// ## Where the references come from
///
/// The Bessel values are **scipy 1.18.1**, whose special functions are a long-standing
/// independent implementation. The exact values are definitions — J₀(0) is 1 because the
/// series has only its first term at zero, and √−1 is i because that is what i means. A
/// definition beats any implementation, including scipy's.
enum DivergenceCases {

    /// One point, and what is true there.
    struct Point: Sendable {
        /// The formula, put to both.
        let formula: String
        /// What the value actually is.
        let reference: Double

        init(_ formula: String, reference: Double) {
            self.formula = formula
            self.reference = reference
        }
    }

    /// A case whose answer is text, or exactly known, and so cannot be compared by subtraction.
    struct Exact: Sendable {
        let formula: String
        /// The answer, written as Excel would write it if it were exact.
        let truth: String
        /// What is being demonstrated.
        let note: String
    }

    /// Bessel points, against scipy 1.18.1.
    ///
    /// A grid rather than the eight that happened to be tested: the question "how wrong is
    /// Excel here" is worth answering across the range rather than at the points that first
    /// raised it, and a systematic error looks quite different from a few unlucky values.
    static let bessel: [Point] = [
        .init("BESSELJ(0.5, 0)", reference: 0.938469807240813),
        .init("BESSELJ(1, 0)", reference: 0.7651976865579666),
        .init("BESSELJ(2.5, 0)", reference: -0.048383776468197914),
        .init("BESSELJ(5, 0)", reference: -0.17759677131433835),
        .init("BESSELJ(7, 0)", reference: 0.30007927051955563),
        .init("BESSELJ(0.5, 1)", reference: 0.2422684576748739),
        .init("BESSELJ(1, 1)", reference: 0.44005058574493355),
        .init("BESSELJ(2.5, 1)", reference: 0.4970941024642741),
        .init("BESSELJ(5, 1)", reference: -0.3275791375914652),
        .init("BESSELJ(7, 1)", reference: -0.0046828234823457346),
        .init("BESSELJ(0.5, 2)", reference: 0.030604023458682638),
        .init("BESSELJ(1, 2)", reference: 0.1149034849319005),
        .init("BESSELJ(2.5, 2)", reference: 0.44605905843961724),
        .init("BESSELJ(5, 2)", reference: 0.04656511627775229),
        .init("BESSELJ(7, 2)", reference: -0.3014172200859401),
        .init("BESSELY(0.5, 0)", reference: -0.44451873350670656),
        .init("BESSELY(1, 0)", reference: 0.088256964215677),
        .init("BESSELY(2.5, 0)", reference: 0.4980703596152317),
        .init("BESSELY(7, 0)", reference: -0.02594974396720927),
        .init("BESSELY(0.5, 1)", reference: -1.4714723926702433),
        .init("BESSELY(1, 1)", reference: -0.7812128213002889),
        .init("BESSELY(2.5, 1)", reference: 0.1459181379667858),
        .init("BESSELY(7, 1)", reference: -0.30266723702418485),
        .init("BESSELY(0.5, 2)", reference: -5.441370837174266),
        .init("BESSELY(1, 2)", reference: -1.6506826068162548),
        .init("BESSELY(2.5, 2)", reference: -0.3813358492418031),
        .init("BESSELY(7, 2)", reference: -0.06052660946827211),
        .init("BESSELI(0.5, 0)", reference: 1.0634833707413236),
        .init("BESSELI(2.5, 0)", reference: 3.289839144050126),
        .init("BESSELI(7, 0)", reference: 168.5939085102895),
        .init("BESSELI(0.5, 1)", reference: 0.25789430539089636),
        .init("BESSELI(2.5, 1)", reference: 2.5167162452887006),
        .init("BESSELI(7, 1)", reference: 156.03909286995528),
        .init("BESSELI(0.5, 3)", reference: 0.002645111968990286),
        .init("BESSELI(2.5, 3)", reference: 0.4743704087780359),
        .init("BESSELI(7, 3)", reference: 85.1754868428438),
        .init("BESSELK(1, 0)", reference: 0.42102443824070834),
        .init("BESSELK(2.5, 0)", reference: 0.06234755320036618),
        .init("BESSELK(7, 0)", reference: 0.0004247957418692318),
        .init("BESSELK(1, 1)", reference: 0.6019072301972346),
        .init("BESSELK(2.5, 1)", reference: 0.07389081634774707),
        .init("BESSELK(7, 1)", reference: 0.00045418248688489695),
        .init("BESSELK(1, 2)", reference: 1.6248388986351774),
        .init("BESSELK(2.5, 2)", reference: 0.12146020627856384),
        .init("BESSELK(7, 2)", reference: 0.0005545621666934881),
    ]

    /// Cases where the true answer is exact, and no reference implementation is needed.
    static let exact: [Exact] = [
        .init(formula: "BESSELJ(0, 0)", truth: "1",
              note: "J₀(0) is exactly 1 — at zero the series has only its first term."),
        .init(formula: "IMSQRT(\"-1\")", truth: "i",
              note: "√−1 is i by definition. Excel goes through polar form and keeps the error."),
        .init(formula: "IMSQRT(\"-4\")", truth: "2i",
              note: "√−4 is exactly 2i, and the same polar rounding shows up again."),
        .init(formula: "IMLN(\"-1\")", truth: "3.14159265358979i",
              note: "Both agree here — included so the sheet shows agreement as well as not."),
        .init(formula: "IMPOWER(\"i\", 2)", truth: "-1",
              note: "i² is exactly −1. Excel computes exp(log(i)·2) and keeps sin(π) = 1.2e-16; "
                  + "this multiplies i by itself. Both answers agreed until this package's own "
                  + "IMPRODUCT was found to disagree with its IMPOWER."),
    ]
}
