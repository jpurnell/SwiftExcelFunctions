import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore
import BusinessMath

/// The seven continuous densities, pinned to their own cumulative branches.
///
/// ## Why this file exists
///
/// Seven `ExcelFunction`s answer a density when their `cumulative` flag is `FALSE`, and each
/// wrote the formula out by hand. BusinessMath 3.0.0-alpha.7 gave every continuous
/// distribution a `pdf(_:)`, so those seven are about to delegate instead — and a
/// delegation is exactly where a **parameterisation** slips without anything failing to
/// compile.
///
/// Three ways that goes wrong, all of which produce a plausible number:
///
/// - `GAMMA.DIST`'s `beta` is a **scale**; the other common convention is a *rate*, its
///   reciprocal. A model built against the wrong one reports a distribution stretched by
///   `1/β²`.
/// - `LOGNORM.DIST`'s `mean` and `standard_dev` are of `ln(x)`, not of `x`.
/// - `BETA.DIST`'s optional `A` and `B` rescale off the unit interval, and a density carries
///   a **Jacobian** through that change of variable. On a range of 10 the unit-interval
///   density overstates by tenfold, and still looks reasonable.
///
/// ## The check
///
/// Each density is compared against **the numerical derivative of its own cumulative
/// branch** — the same function, same arguments, `cumulative` flipped. That ties the two
/// halves of each `ExcelFunction` together, so a rebinding that changes what the parameters
/// mean fails here even though both halves still return numbers.
///
/// These assertions pass **before** the rebinding as well as after. That is the point: they
/// are a characterisation of behaviour that must not change, written while the hand-rolled
/// formulas are still in place, so "still green" afterwards means something.
final class DensityBindingTests: XCTestCase {

    private func evaluate(_ name: String, _ args: [CellValue]) throws -> CellValue {
        let fn = try XCTUnwrap(FunctionRegistry.builtin.function(named: name),
                               "\(name) is not registered")
        return try fn.evaluate(args)
    }

    private func number(_ name: String, _ args: [CellValue]) throws -> Double {
        let value = try evaluate(name, args)
        guard case .number(let d) = value else {
            XCTFail("\(name)\(args) gave \(value), expected a number")
            return .nan
        }
        return d
    }

    /// One function's density branch, and how to build its argument list.
    private struct Subject: Sendable {
        let name: String
        /// `(x, cumulative) -> arguments`, since `BETA.DIST` puts its flag mid-list.
        let arguments: @Sendable (Double, Bool) -> [CellValue]
        /// Interior points of the support, away from any boundary.
        let points: [Double]
    }

    private static let subjects: [Subject] = [
        Subject(name: "EXPON.DIST",
                arguments: { x, c in [.number(x), .number(1.5), .bool(c)] },
                points: [0.4, 1.2, 3]),
        // alpha is the shape, beta the SCALE — the reciprocal convention is the trap.
        Subject(name: "GAMMA.DIST",
                arguments: { x, c in [.number(x), .number(3), .number(2), .bool(c)] },
                points: [1.5, 4, 9]),
        // Parameters of ln(x), deliberately non-zero so a dropped shift is visible.
        Subject(name: "LOGNORM.DIST",
                arguments: { x, c in [.number(x), .number(0.4), .number(0.6), .bool(c)] },
                points: [0.8, 1.5, 3.5]),
        // The unit interval, where no Jacobian is involved.
        Subject(name: "BETA.DIST",
                arguments: { x, c in [.number(x), .number(2), .number(5), .bool(c)] },
                points: [0.15, 0.4, 0.7]),
        // And off it, where one is. A width of 8 would hide nothing at width 1.
        Subject(name: "BETA.DIST on [2, 10]",
                arguments: { x, c in
                    [.number(x), .number(2), .number(5), .bool(c), .number(2), .number(10)]
                },
                points: [3.2, 5, 7.6]),
        Subject(name: "WEIBULL.DIST",
                arguments: { x, c in [.number(x), .number(2), .number(3), .bool(c)] },
                points: [1, 2.5, 5]),
        Subject(name: "CHISQ.DIST",
                arguments: { x, c in [.number(x), .number(5), .bool(c)] },
                points: [1.5, 4, 9]),
        Subject(name: "F.DIST",
                arguments: { x, c in [.number(x), .number(5), .number(8), .bool(c)] },
                points: [0.4, 1, 2.5]),
    ]

    /// **The check that matters.** Each density is the slope of its own cumulative branch.
    func testEachDensityIsTheDerivativeOfItsOwnCumulative() throws {
        for subject in Self.subjects {
            // `BETA.DIST on [2, 10]` is a label, not a function name.
            let function = String(subject.name.split(separator: " ")[0])
            for x in subject.points {
                let h = Swift.max(Swift.abs(x), 1) * 1e-6
                let upper = try number(function, subject.arguments(x + h, true))
                let lower = try number(function, subject.arguments(x - h, true))
                let slope = (upper - lower) / (2 * h)
                let density = try number(function, subject.arguments(x, false))
                let tolerance = Swift.max(1e-6, Swift.abs(slope) * 1e-4)
                XCTAssertEqual(density, slope, accuracy: tolerance,
                               "\(subject.name) at \(x): density \(density), slope \(slope)")
            }
        }
    }

    /// Every density integrates to one over its support.
    ///
    /// Catches a missing Jacobian that the derivative check cannot: a density uniformly
    /// scaled by a constant is still proportional to the CDF's slope only if the CDF is
    /// scaled too, and these two halves are computed by different code.
    func testEachDensityIntegratesToOne() throws {
        let ranges: [(String, @Sendable (Double, Bool) -> [CellValue], Double, Double)] = [
            ("EXPON.DIST", { x, c in [.number(x), .number(1.5), .bool(c)] }, 0, 40),
            ("GAMMA.DIST", { x, c in [.number(x), .number(3), .number(2), .bool(c)] }, 0, 80),
            ("WEIBULL.DIST", { x, c in [.number(x), .number(2), .number(3), .bool(c)] }, 0, 30),
            ("CHISQ.DIST", { x, c in [.number(x), .number(5), .bool(c)] }, 0, 80),
        ]
        for (name, arguments, lower, upper) in ranges {
            let steps = 20_000
            let h = (upper - lower) / Double(steps)
            var total = try number(name, arguments(lower, false))
                + (try number(name, arguments(upper, false)))
            for step in 1..<steps {
                let x = lower + Double(step) * h
                total += (try number(name, arguments(x, false))) * (step % 2 == 0 ? 2 : 4)
            }
            XCTAssertEqual(total * h / 3, 1, accuracy: 2e-3, "\(name) did not integrate to one")
        }
    }

    // MARK: - The boundaries, which are Excel's rules rather than the mathematics'

    /// The three-way split at zero: unbounded below a shape of one, finite at one, zero above.
    ///
    /// Excel reports the unbounded case as `#NUM!` rather than as an infinity, and that is a
    /// **spreadsheet** convention, not a fact about the distribution. Upstream's
    /// `pdf(_:)` answers `infinity` there, correctly, so the delegation must not reach
    /// these cases — they stay in this package where the convention lives.
    func testTheUnboundedPointIsRefusedRatherThanInfinite() throws {
        XCTAssertEqual(try evaluate("CHISQ.DIST", [.number(0), .number(1), .bool(false)]),
                       .error(.num), "one degree of freedom is unbounded at zero")
        XCTAssertEqual(try number("CHISQ.DIST", [.number(0), .number(2), .bool(false)]), 0.5,
                       accuracy: 1e-12, "exactly two is the finite case")
        XCTAssertEqual(try number("CHISQ.DIST", [.number(0), .number(3), .bool(false)]), 0,
                       accuracy: 1e-12, "above two the density vanishes")

        // GAMMA.DIST and WEIBULL.DIST face the identical split, and used to answer the
        // unbounded case with `+∞` **as a number**. No cell can hold one — it would reach
        // `sheet.write(_:to:)` in any workbook this evaluator feeds, and SwiftXLSX has
        // already killed a corpus run once on a value it could not represent.
        XCTAssertEqual(try evaluate("GAMMA.DIST",
                                    [.number(0), .number(0.5), .number(2), .bool(false)]),
                       .error(.num), "a shape below one is unbounded at zero")
        XCTAssertEqual(try evaluate("WEIBULL.DIST",
                                    [.number(0), .number(0.5), .number(3), .bool(false)]),
                       .error(.num), "a shape below one is unbounded at zero")

        XCTAssertEqual(try number("GAMMA.DIST",
                                  [.number(0), .number(1), .number(2), .bool(false)]), 0.5,
                       accuracy: 1e-12, "a shape of one starts at 1/scale")
        XCTAssertEqual(try number("GAMMA.DIST",
                                  [.number(0), .number(3), .number(2), .bool(false)]), 0,
                       accuracy: 1e-12, "above one the density vanishes at zero")
        XCTAssertEqual(try number("WEIBULL.DIST",
                                  [.number(0), .number(1), .number(3), .bool(false)]),
                       1.0 / 3, accuracy: 1e-12, "a shape of one starts at 1/scale")
        XCTAssertEqual(try number("WEIBULL.DIST",
                                  [.number(0), .number(2), .number(3), .bool(false)]), 0,
                       accuracy: 1e-12, "above one the density vanishes at zero")

        // Nothing this package answers as a density may be non-finite, whatever the
        // convention turns out to be — that is the part which does not depend on Excel.
        for shape in [0.25, 0.5, 0.75, 1.0, 2.0] {
            for name in ["GAMMA.DIST", "WEIBULL.DIST"] {
                let answer = try evaluate(name, [.number(0), .number(shape), .number(2),
                                                 .bool(false)])
                if case .number(let d) = answer {
                    XCTAssertTrue(d.isFinite, "\(name) at shape \(shape) gave \(d)")
                }
            }
        }

        // F.DIST answers zero at zero for every numerator, which is this package's rule and
        // not the mathematics': at one numerator degree of freedom the density there is
        // unbounded, and at exactly two it is 1. **Both are open questions**, asked of Excel
        // in round eight of the conformance workbook (`ConformanceCases.roundEight`) rather
        // than settled here by argument. Pinned meanwhile so the answer cannot drift before
        // the measurement arrives, and so that changing it is a deliberate act.
        XCTAssertEqual(try number("F.DIST",
                                  [.number(0), .number(1), .number(5), .bool(false)]), 0,
                       accuracy: 1e-12, "unbounded in the mathematics; awaiting Excel")
        XCTAssertEqual(try number("F.DIST",
                                  [.number(0), .number(2), .number(5), .bool(false)]), 0,
                       accuracy: 1e-12, "exactly 1 in the mathematics; awaiting Excel")
        XCTAssertEqual(try number("F.DIST",
                                  [.number(0), .number(5), .number(8), .bool(false)]), 0,
                       accuracy: 1e-12, "above two, zero is simply correct")
    }

    /// Outside the support, and outside the parameters' domain.
    func testDomainsAreRefused() throws {
        XCTAssertEqual(try evaluate("EXPON.DIST", [.number(-1), .number(1.5), .bool(false)]),
                       .error(.num))
        XCTAssertEqual(try evaluate("EXPON.DIST", [.number(1), .number(0), .bool(false)]),
                       .error(.num), "a rate of zero describes nothing")
        XCTAssertEqual(try evaluate("LOGNORM.DIST",
                                    [.number(0), .number(0.4), .number(0.6), .bool(false)]),
                       .error(.num), "the log-normal is defined for x > 0 only")
        XCTAssertEqual(try evaluate("WEIBULL.DIST",
                                    [.number(-1), .number(2), .number(3), .bool(false)]),
                       .error(.num))
        XCTAssertEqual(try evaluate("CHISQ.DIST", [.number(-1), .number(5), .bool(false)]),
                       .error(.num))
        // BETA.DIST refuses both endpoints of its density, on the unit interval and off it.
        XCTAssertEqual(try evaluate("BETA.DIST",
                                    [.number(0), .number(2), .number(5), .bool(false)]),
                       .error(.num))
        XCTAssertEqual(try evaluate("BETA.DIST",
                                    [.number(1), .number(2), .number(5), .bool(false)]),
                       .error(.num))
        XCTAssertEqual(try evaluate("BETA.DIST",
                                    [.number(1), .number(2), .number(5), .bool(false),
                                     .number(2), .number(10)]),
                       .error(.num), "below A is outside the support")
    }

    /// `A` and `B` scale the density down by the width, and leave the cumulative alone.
    ///
    /// The single most likely rebinding defect, and the cheapest to state: the same shape on
    /// a range of 8 has a density one eighth the size at the corresponding point, while the
    /// probability below that point is unchanged.
    func testTheBetaBoundsCarryAJacobian() throws {
        let width = 8.0
        for unit in [0.15, 0.4, 0.7] {
            let scaled = 2 + unit * width
            let onUnit = try number("BETA.DIST",
                                    [.number(unit), .number(2), .number(5), .bool(false)])
            let onRange = try number("BETA.DIST",
                                     [.number(scaled), .number(2), .number(5), .bool(false),
                                      .number(2), .number(10)])
            XCTAssertEqual(onRange, onUnit / width, accuracy: 1e-12,
                           "the density must carry the change of variable")

            let cumulativeOnUnit = try number("BETA.DIST",
                                              [.number(unit), .number(2), .number(5), .bool(true)])
            let cumulativeOnRange = try number("BETA.DIST",
                                               [.number(scaled), .number(2), .number(5),
                                                .bool(true), .number(2), .number(10)])
            XCTAssertEqual(cumulativeOnRange, cumulativeOnUnit, accuracy: 1e-12,
                           "a probability is a probability on any scale")
        }
    }
}
