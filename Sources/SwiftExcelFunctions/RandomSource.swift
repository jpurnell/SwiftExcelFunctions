import Foundation
import BusinessMath

/// Where `RAND()` and `RANDBETWEEN()` get their randomness.
///
/// This package supplies none of its own. It never calls `Double.random`, never
/// reaches for `SystemRandomNumberGenerator`, and has no default source — so it
/// is deterministic *by construction* rather than deterministic by justification,
/// and a caller who wants reproducible results gets them by choosing, not by
/// hoping.
///
/// ## Why Excel is not imitated
///
/// Excel exposes no way to seed `RAND()`. Two sessions on the same workbook
/// produce different sequences and nothing pins them, so there is no sequence to
/// reproduce and no fact to be right or wrong about. What Excel does document is
/// the contract — a uniform value in `[0, 1)` — and that is what this promises.
///
/// One consequence is worth stating plainly rather than discovering: with a
/// seeded source, `RAND()` **stops being volatile**. Excel recomputes it on every
/// recalculation; a seeded stream gives the same workbook the same values twice.
/// For a translation layer that is the better behaviour, but it is a real
/// difference from Excel.
public protocol RandomSource: Sendable {

    /// The next uniform value in `[0, 1)`.
    ///
    /// Half-open at the top, as Excel documents. `RANDBETWEEN` relies on it:
    /// scaling a value that could reach 1.0 would put the result one past the
    /// upper bound.
    func nextUniform() -> Double
}

/// A reproducible ``RandomSource`` over BusinessMath's deterministic generator.
///
/// Backed by `DeterministicRNG` — Xoshiro256\*\* — which BusinessMath already
/// uses for its own simulation work. Binding to it rather than writing a second
/// generator is the point: two generators in one dependency chain could disagree
/// about what a seeded stream is, and that is the failure this whole arrangement
/// exists to prevent.
// Justification: generator is mutable state reached only through lock; an actor would make every call async for no gain.
public final class SeededRandomSource: RandomSource, @unchecked Sendable {

    private var generator: DeterministicRNG
    private let lock = NSLock()

    /// Creates a source that yields the same stream for the same seed.
    ///
    /// - Parameter seed: The seed. Equal seeds give equal streams, which is the
    ///   property Excel cannot offer at all.
    public init(seed: UInt64) {
        self.generator = DeterministicRNG(seed: seed)
    }

    /// The next uniform value in `[0, 1)`.
    public func nextUniform() -> Double {
        lock.lock()
        defer { lock.unlock() }
        // Scaled by 2⁻⁶⁴ rather than divided by 2⁶⁴ − 1. Two reasons, and both
        // matter: multiplying by an exact power of two is exact, so no rounding
        // can push a draw to 1.0; and the interval stays half-open, which is what
        // lets RANDBETWEEN reach its top bound exactly once instead of overshooting.
        // It also leaves no division for anyone to wonder about the divisor of.
        return Double(generator.next()) * 0x1.0p-64
    }
}
