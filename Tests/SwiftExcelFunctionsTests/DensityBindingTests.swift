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

    /// **Every density boundary, as Excel answered it in round eight.**
    ///
    /// Five functions face the same situation — a shape parameter under a power of `x` at the
    /// edge of the support — and Excel gives **three different conventions**, none of which
    /// follows from the others:
    ///
    /// | | shape < 1 | shape = 1 | shape > 1 |
    /// |---|---|---|---|
    /// | `CHISQ.DIST` | `#NUM!` | ½ — the density | 0 |
    /// | `GAMMA.DIST` | `#NUM!` | **`#NUM!`** — where the density is `1/β` | 0 |
    /// | `BETA.DIST` | `#NUM!` | **`#NUM!`** — where the density is 5 | **0** |
    /// | `WEIBULL.DIST` | **0** | **0** | 0 |
    /// | `F.DIST` | `#NUM!` | **1** — the density | 0 |
    ///
    /// `WEIBULL.DIST` answers a flat zero even where the density is unbounded.
    /// `CHISQ.DIST` and `F.DIST` honour the mathematics. `GAMMA.DIST` and `BETA.DIST` refuse
    /// one case the other two answer. This is a measurement, not a theory about Excel, and
    /// the workbook that produced it is round eight — `ConformanceCases.roundEight`.
    ///
    /// **Three of these were guessed wrong before the round ran**, two of them by this
    /// package for years and one by the guess that was meant to fix it: `WEIBULL.DIST`'s
    /// unbounded point was changed from `+∞` to `#NUM!` by analogy with `CHISQ.DIST`, and
    /// the answer is 0.
    func testEveryDensityBoundaryIsWhatExcelAnswered() throws {
        // (formula for the record, arguments, Excel's answer)
        let measured: [(String, [CellValue], CellValue)] = [
            ("F.DIST(0, 1, 5, FALSE)",
             [.number(0), .number(1), .number(5), .bool(false)], .error(.num)),
            ("F.DIST(0, 2, 5, FALSE)",
             [.number(0), .number(2), .number(5), .bool(false)], .number(1)),
            ("F.DIST(0, 5, 8, FALSE)",
             [.number(0), .number(5), .number(8), .bool(false)], .number(0)),

            ("CHISQ.DIST(0, 1, FALSE)", [.number(0), .number(1), .bool(false)], .error(.num)),
            ("CHISQ.DIST(0, 2, FALSE)", [.number(0), .number(2), .bool(false)], .number(0.5)),
            ("CHISQ.DIST(0, 3, FALSE)", [.number(0), .number(3), .bool(false)], .number(0)),

            ("GAMMA.DIST(0, 0.5, 2, FALSE)",
             [.number(0), .number(0.5), .number(2), .bool(false)], .error(.num)),
            ("GAMMA.DIST(0, 1, 2, FALSE)",
             [.number(0), .number(1), .number(2), .bool(false)], .error(.num)),
            ("GAMMA.DIST(0, 3, 2, FALSE)",
             [.number(0), .number(3), .number(2), .bool(false)], .number(0)),

            ("WEIBULL.DIST(0, 0.5, 3, FALSE)",
             [.number(0), .number(0.5), .number(3), .bool(false)], .number(0)),
            ("WEIBULL.DIST(0, 1, 3, FALSE)",
             [.number(0), .number(1), .number(3), .bool(false)], .number(0)),
            ("WEIBULL.DIST(0, 2, 3, FALSE)",
             [.number(0), .number(2), .number(3), .bool(false)], .number(0)),

            ("BETA.DIST(0, 0.5, 5, FALSE)",
             [.number(0), .number(0.5), .number(5), .bool(false)], .error(.num)),
            ("BETA.DIST(0, 1, 5, FALSE)",
             [.number(0), .number(1), .number(5), .bool(false)], .error(.num)),
            ("BETA.DIST(0, 2, 5, FALSE)",
             [.number(0), .number(2), .number(5), .bool(false)], .number(0)),
            ("BETA.DIST(1, 2, 5, FALSE)",
             [.number(1), .number(2), .number(5), .bool(false)], .number(0)),

            ("LOGNORM.DIST(0, 0, 1, FALSE)",
             [.number(0), .number(0), .number(1), .bool(false)], .error(.num)),
            ("EXPON.DIST(0, 1.5, FALSE)",
             [.number(0), .number(1.5), .bool(false)], .number(1.5)),
        ]

        for (formula, arguments, excel) in measured {
            let name = String(formula.prefix(while: { $0 != "(" }))
            let ours = try evaluate(name, arguments)
            switch (excel, ours) {
            case (.number(let expected), .number(let actual)):
                XCTAssertEqual(actual, expected, accuracy: 1e-12,
                               "\(formula): Excel says \(expected), we say \(actual)")
            default:
                XCTAssertEqual(ours, excel, "\(formula): Excel says \(excel), we say \(ours)")
            }
        }
    }

    /// Nothing answered as a density may be non-finite, whatever the convention.
    ///
    /// The one part of the boundary question that never needed Excel. A cell cannot hold an
    /// infinity, and the value reaches `sheet.write(_:to:)` in any workbook this evaluator
    /// feeds — SwiftXLSX has already killed a corpus run once on a value it could not
    /// represent. `GAMMA.DIST` and `WEIBULL.DIST` both returned `+∞` here until round eight.
    func testNoDensityIsEverNonFinite() throws {
        for shape in [0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 5.0] {
            for x in [0.0, 1e-300, 0.5, 4.0] {
                for name in ["GAMMA.DIST", "WEIBULL.DIST"] {
                    let answer = try evaluate(name, [.number(x), .number(shape), .number(2),
                                                     .bool(false)])
                    if case .number(let d) = answer {
                        XCTAssertTrue(d.isFinite, "\(name)(\(x), \(shape), 2) gave \(d)")
                    }
                }
                let beta = try evaluate("BETA.DIST", [.number(Swift.min(x, 1)), .number(shape),
                                                      .number(5), .bool(false)])
                if case .number(let d) = beta {
                    XCTAssertTrue(d.isFinite, "BETA.DIST at shape \(shape) gave \(d)")
                }
            }
        }
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
        // Outside `[A, B]` altogether is refused; the endpoints themselves follow the
        // measured rule in `testEveryDensityBoundaryIsWhatExcelAnswered`.
        XCTAssertEqual(try evaluate("BETA.DIST",
                                    [.number(1), .number(2), .number(5), .bool(false),
                                     .number(2), .number(10)]),
                       .error(.num), "below A is outside the support")
        XCTAssertEqual(try evaluate("BETA.DIST",
                                    [.number(12), .number(2), .number(5), .bool(false),
                                     .number(2), .number(10)]),
                       .error(.num), "above B is outside the support")
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
