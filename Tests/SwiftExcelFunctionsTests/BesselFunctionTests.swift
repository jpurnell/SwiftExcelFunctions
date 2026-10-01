import Foundation
import SwiftExcelCore
import Foundation
import Testing
@testable import SwiftExcelFunctions

/// Excel's four Bessel functions, bound to BusinessMath.
///
/// ## Why there is not a table of expected values here
///
/// Three tests in this project have failed *correct* code because the expected value was
/// recalled rather than read — `ERF(0.745)` among them. A Bessel value is exactly the kind of
/// constant nobody can check by eye, so a table of them tests the transcription and nothing
/// else.
///
/// These assert **relationships** instead: the recurrences that define the functions, the
/// values at zero, and the Wronskian that ties `J` to `Y`. A wrong implementation cannot
/// satisfy a recurrence by accident, and none of these can fail because a digit was
/// misremembered.
@Suite struct BesselFunctionTests {

    private let registry = FunctionRegistry.builtin

    private func call(_ name: String, _ x: Double, _ n: Double) throws -> CellValue {
        let function = try #require(registry.function(named: name), "\(name) is not registered")
        return try function.evaluate([.number(x), .number(n)])
    }

    private func value(_ name: String, _ x: Double, _ n: Double) throws -> Double {
        let result = try call(name, x, n)
        guard case .number(let v) = result else {
            Issue.record("\(name)(\(x), \(n)) returned \(result)")
            return .nan
        }
        return v
    }

    // MARK: - Registration

    @Test func allFourBesselFunctionsAreRegistered() {
        for name in ["BESSELI", "BESSELJ", "BESSELK", "BESSELY"] {
            #expect(registry.resolvedName(name) == FunctionRegistry.canonical(name), "\(name) is not registered")
        }
    }

    // MARK: - The values at zero, which are definitional

    @Test func theOrdinaryFunctionsAtZero() throws {
        // J₀(0) = 1 and Jₙ(0) = 0 for n ≥ 1. Likewise for the modified I.
        #expect(try abs(value("BESSELJ", 0, 0) - 1) <= 1e-12)
        #expect(try abs(value("BESSELJ", 0, 1) - 0) <= 1e-12)
        #expect(try abs(value("BESSELJ", 0, 3) - 0) <= 1e-12)
        #expect(try abs(value("BESSELI", 0, 0) - 1) <= 1e-12)
        #expect(try abs(value("BESSELI", 0, 1) - 0) <= 1e-12)
    }

    // MARK: - The recurrences that define them

    /// `Jₙ₋₁(x) + Jₙ₊₁(x) = (2n/x)·Jₙ(x)` — and the same relation holds for `Y`.
    @Test func theOrdinaryRecurrenceHolds() throws {
        for x in [0.5, 1.0, 2.5, 7.0] {
            for n in 1...4 {
                let expected = (2 * Double(n) / x) * (try value("BESSELJ", x, Double(n)))
                let actual = try value("BESSELJ", x, Double(n - 1))
                    + (try value("BESSELJ", x, Double(n + 1)))
                #expect(abs(actual - expected) <= 1e-9, "J recurrence failed at x=\(x), n=\(n)")

                let yExpected = (2 * Double(n) / x) * (try value("BESSELY", x, Double(n)))
                let yActual = try value("BESSELY", x, Double(n - 1))
                    + (try value("BESSELY", x, Double(n + 1)))
                #expect(abs(yActual - yExpected) <= 1e-7, "Y recurrence failed at x=\(x), n=\(n)")
            }
        }
    }

    /// The modified functions carry a **sign difference**, which is the whole point of them:
    /// `Iₙ₋₁(x) − Iₙ₊₁(x) = (2n/x)·Iₙ(x)`, and `Kₙ₊₁(x) − Kₙ₋₁(x) = (2n/x)·Kₙ(x)`.
    ///
    /// Writing either with the ordinary `+` gives a plausible number and fails here.
    @Test func theModifiedRecurrencesHoldWithTheirSigns() throws {
        for x in [0.5, 1.0, 2.5, 7.0] {
            for n in 1...4 {
                let expected = (2 * Double(n) / x) * (try value("BESSELI", x, Double(n)))
                let actual = try value("BESSELI", x, Double(n - 1))
                    - (try value("BESSELI", x, Double(n + 1)))
                #expect(abs(actual - expected) <= 1e-9, "I recurrence failed at x=\(x), n=\(n)")

                let kExpected = (2 * Double(n) / x) * (try value("BESSELK", x, Double(n)))
                let kActual = try value("BESSELK", x, Double(n + 1))
                    - (try value("BESSELK", x, Double(n - 1)))
                #expect(abs(kActual - kExpected) <= 1e-7, "K recurrence failed at x=\(x), n=\(n)")
            }
        }
    }

    /// `Jₙ₊₁(x)·Yₙ(x) − Jₙ(x)·Yₙ₊₁(x) = 2/(πx)`.
    ///
    /// The Wronskian ties the two ordinary functions together, so it fails if either is
    /// wrong *or* if they are right but mismatched — which a per-function test cannot catch.
    @Test func theWronskianTiesJToY() throws {
        for x in [0.5, 1.0, 2.5, 7.0] {
            for n in 0...3 {
                let left = (try value("BESSELJ", x, Double(n + 1)))
                    * (try value("BESSELY", x, Double(n)))
                    - (try value("BESSELJ", x, Double(n)))
                    * (try value("BESSELY", x, Double(n + 1)))
                #expect(abs(left - (2 / (.pi * x))) <= 1e-8, "Wronskian failed at x=\(x), n=\(n)")
            }
        }
    }

    // MARK: - Shape

    /// `K` decays and `I` grows; confusing them returns a number of the wrong magnitude
    /// rather than an error.
    @Test func theModifiedPairGoOppositeWays() throws {
        #expect(try value("BESSELI", 4, 0) > value("BESSELI", 1, 0))
        #expect(try value("BESSELK", 4, 0) < value("BESSELK", 1, 0))
        #expect(try value("BESSELK", 1, 0) > 0)
    }

    // MARK: - What Excel refuses

    @Test func aNegativeOrderIsRefused() throws {
        for name in ["BESSELI", "BESSELJ", "BESSELK", "BESSELY"] {
            #expect(try call(name, 1, -1) == .error(.num), "\(name) must refuse n < 0")
        }
    }

    @Test func theOrderIsTruncatedRatherThanRounded() throws {
        // Microsoft: "If n is not an integer, it is truncated."
        #expect(try abs(value("BESSELJ", 2.5, 1.9) - value("BESSELJ", 2.5, 1)) <= 1e-15)
        #expect(try abs(value("BESSELI", 2.5, 2.99) - value("BESSELI", 2.5, 2)) <= 1e-15)
    }

    @Test func textArgumentsAreAValueError() throws {
        let function = try #require(registry.function(named: "BESSELJ"))
        #expect(try function.evaluate([.text("x"), .number(1)]) == .error(.value))
        #expect(try function.evaluate([.number(1), .text("n")]) == .error(.value))
    }

    @Test func anErrorArgumentPropagates() throws {
        let function = try #require(registry.function(named: "BESSELJ"))
        #expect(try function.evaluate([.error(.div0), .number(1)]) == .error(.div0))
    }

    /// `K` and `Y` are singular at the origin and undefined to its left.
    @Test func theSingularPairRefuseNonPositiveArguments() throws {
        for name in ["BESSELK", "BESSELY"] {
            #expect(try call(name, 0, 0) == .error(.num), "\(name) is singular at 0")
            #expect(try call(name, -1, 0) == .error(.num), "\(name) is undefined below 0")
        }
    }
}
