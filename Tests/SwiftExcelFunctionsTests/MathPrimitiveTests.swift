import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

/// The math primitives from the unreviewed bucket — master plan priority 4.
///
/// Measured first: **0 of 286** unreviewed rows already answered, so none of this was
/// secretly covered. And the master plan's expectation held — the `math` category is
/// forty functions and most are one line of Foundation.
///
/// ## Where the expected values come from
///
/// ADR-001: *a test whose expected value came from reading a specification proves only
/// that we read it the same way twice.* So every value here is either published by
/// Microsoft or computed from Microsoft's own documented identity — `COT(x)` is
/// `1/TAN(x)`, and asserting that is asserting the definition rather than our arithmetic.
@Suite struct MathPrimitiveTests {

    private struct NoCells: CellValueProvider {
        func value(at ref: CellRef) -> CellValue? { nil }
        func value(at ref: CellRef, inSheet: String) -> CellValue? { nil }
        func values(in range: CellRange) -> [CellValue] { [] }
        func values(in range: CellRange, inSheet: String) -> [CellValue] { [] }
        func lastPopulatedCell() -> CellRef? { nil }
        func lastPopulatedCell(inSheet: String) -> CellRef? { nil }
    }

    private func call(_ name: String, _ args: Double...) throws -> CellValue {
        let fn = try #require(FunctionRegistry.builtin.function(named: name), "\(name) is not registered")
        return try fn.evaluate(args.map { .number($0) })
    }

    private func number(_ value: CellValue) throws -> Double {
        guard case .number(let d) = value else { throw TestFailure("expected a number, got \(value)") }
        return d
    }

    // MARK: - Hyperbolic, and their inverses

    /// Published by Microsoft: `COSH(4)` is 27.30823, `SINH(1)` is 1.175201194,
    /// `TANH(-2)` is -0.96403.
    @Test func hyperbolics() throws {
        #expect(try abs(number(try call("COSH", 4)) - 27.30823) <= 1e-5)
        #expect(try abs(number(try call("SINH", 1)) - 1.175201194) <= 1e-9)
        #expect(try abs(number(try call("TANH", -2)) - -0.96403) <= 1e-5)
    }

    /// Published: `ACOSH(10)` is 2.993223, `ASINH(-2.5)` is -1.647231.
    /// `ATANH` is asserted as the inverse of `TANH`, which is its definition.
    @Test func inverseHyperbolics() throws {
        #expect(try abs(number(try call("ACOSH", 10)) - 2.993223) <= 1e-6)
        #expect(try abs(number(try call("ASINH", -2.5)) - -1.647231) <= 1e-6)
        #expect(try abs(number(try call("ATANH", tanh(0.75))) - 0.75) <= 1e-12)
    }

    /// `ACOSH` is undefined below 1 and `ATANH` outside (-1, 1). Excel answers `#NUM!`
    /// for a computation with no result rather than propagating a NaN.
    @Test func domainErrorsAreNum() throws {
        #expect(try call("ACOSH", 0.5) == .error(.num))
        #expect(try call("ATANH", 1) == .error(.num))
        #expect(try call("ATANH", -1) == .error(.num))
    }

    // MARK: - Reciprocal trigonometry, by its documented identity

    /// Microsoft documents each as the reciprocal of a function we already have, so
    /// asserting the identity asserts the definition.
    @Test func reciprocalTrigonometryMatchesItsIdentity() throws {
        #expect(try abs(number(try call("SEC", 0.7)) - (1 / cos(0.7))) <= 1e-12)
        #expect(try abs(number(try call("CSC", 0.7)) - (1 / sin(0.7))) <= 1e-12)
        #expect(try abs(number(try call("COT", 0.7)) - (1 / tan(0.7))) <= 1e-12)
        #expect(try abs(number(try call("SECH", 0.7)) - (1 / cosh(0.7))) <= 1e-12)
        #expect(try abs(number(try call("CSCH", 0.7)) - (1 / sinh(0.7))) <= 1e-12)
        #expect(try abs(number(try call("COTH", 0.7)) - (1 / tanh(0.7))) <= 1e-12)
    }

    /// A reciprocal at zero divides by zero, and Excel says so rather than answering
    /// infinity.
    @Test func reciprocalAtZeroIsDivideByZero() throws {
        #expect(try call("CSC", 0) == .error(.div0))
        #expect(try call("COT", 0) == .error(.div0))
        #expect(try call("CSCH", 0) == .error(.div0))
        #expect(try call("COTH", 0) == .error(.div0))
    }

    /// `ACOT` returns a principal angle in `(0, π)` — which is why it is not simply
    /// `ATAN(1/x)`, and the difference shows at negative arguments.
    @Test func inverseCotangentStaysInItsPrincipalRange() throws {
        #expect(try abs(number(try call("ACOT", 2)) - 0.4636476) <= 1e-6)
        let negative = try number(try call("ACOT", -2))
        #expect(negative > (Double.pi / 2), "ACOT is positive for a negative argument")
        #expect(negative < Double.pi)
    }

    /// `ACOT(0)` is `π/2` — a defined answer at the point the reciprocal is not.
    @Test func inverseCotangentAtZero() throws {
        #expect(try abs(number(try call("ACOT", 0)) - (Double.pi / 2)) <= 1e-12)
    }

    /// `ACOTH` is defined only where `|x| > 1`.
    @Test func inverseHyperbolicCotangent() throws {
        #expect(try abs(number(try call("ACOTH", 6)) - 0.168236) <= 1e-6)
        #expect(try call("ACOTH", 0.5) == .error(.num))
    }

    // MARK: - Angles

    /// Published: `DEGREES(PI())` is 180, `RADIANS(270)` is 4.712389.
    @Test func angleConversion() throws {
        #expect(try abs(number(try call("DEGREES", .pi)) - 180) <= 1e-12)
        #expect(try abs(number(try call("RADIANS", 270)) - 4.712389) <= 1e-6)
    }

    // MARK: - Rounding away from zero

    /// Published: `EVEN(1.5)` is 2, `EVEN(3)` is 4, `EVEN(2)` is 2, `EVEN(-1)` is -2.
    /// Rounding is *away from zero*, which is why -1 gives -2 rather than 0.
    @Test func evenRoundsAwayFromZero() throws {
        #expect(try call("EVEN", 1.5) == .number(2))
        #expect(try call("EVEN", 3) == .number(4))
        #expect(try call("EVEN", 2) == .number(2))
        #expect(try call("EVEN", -1) == .number(-2))
        #expect(try call("EVEN", 0) == .number(0))
    }

    /// Published: `ODD(1.5)` is 3, `ODD(3)` is 3, `ODD(2)` is 3, `ODD(-1)` is -1.
    @Test func oddRoundsAwayFromZero() throws {
        #expect(try call("ODD", 1.5) == .number(3))
        #expect(try call("ODD", 3) == .number(3))
        #expect(try call("ODD", 2) == .number(3))
        #expect(try call("ODD", -1) == .number(-1))
        #expect(try call("ODD", 0) == .number(1))
    }

    // MARK: - The rest of the batch

    /// `SQRTPI(x)` is `SQRT(x * PI())`, by Microsoft's own definition.
    @Test func squareRootOfPiTimes() throws {
        #expect(try abs(number(try call("SQRTPI", 1)) - (Double.pi).squareRoot()) <= 1e-12)
        #expect(try abs(number(try call("SQRTPI", 2)) - (2 * Double.pi).squareRoot()) <= 1e-12)
        #expect(try call("SQRTPI", -1) == .error(.num))
    }

    /// Published: `QUOTIENT(5, 2)` is 2, `QUOTIENT(-10, 3)` is -3. The fractional part is
    /// discarded rather than rounded, so -10/3 truncates toward zero.
    @Test func quotientTruncatesTowardZero() throws {
        #expect(try call("QUOTIENT", 5, 2) == .number(2))
        #expect(try call("QUOTIENT", -10, 3) == .number(-3))
        #expect(try call("QUOTIENT", 4.5, 3.1) == .number(1))
        #expect(try call("QUOTIENT", 1, 0) == .error(.div0))
    }
}
