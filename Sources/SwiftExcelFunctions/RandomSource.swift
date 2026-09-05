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
    /// Half-open at the top, as Excel documents. Note this is *not* the open
    /// interval `(0, 1)`: zero is a legitimate result of `RAND()`, where a
    /// quantile function would need it excluded. The two are different primitives
    /// and sharing one would break whichever came second.
    func nextUniform() -> Double

    /// A uniform integer in `0..<bound`.
    ///
    /// Its own method rather than `Int(nextUniform() * bound)`, because scaling a
    /// double across a span is modulo bias wearing a different hat: some outcomes
    /// come from a wider band of doubles than others. `RANDBETWEEN` over a range
    /// that does not divide evenly into 2⁵³ would lean, slightly and invisibly.
    ///
    /// - Parameter bound: The exclusive upper bound. Must be positive.
    /// - Returns: A uniform integer below `bound`.
    func nextInteger(below bound: Int) -> Int
}

/// A reproducible ``RandomSource`` over BusinessMath's deterministic generator.
///
/// Backed by `DeterministicRNG` — Xoshiro256\*\* — which BusinessMath already
/// uses for its own simulation work. Binding to it rather than writing a second
/// generator is the point: two generators in one dependency chain could disagree
/// about what a seeded stream is, and that is the failure this whole arrangement
/// exists to prevent.
// Justification: generator is mutable state reached only through lock; an actor would make every call async for no gain.
public final class SeededRandomSource<Generator: RandomNumberGenerator>: RandomSource, @unchecked Sendable {

    private var generator: Generator
    private let lock = NSLock()

    /// Wraps any generator.
    ///
    /// Generic over the stdlib's `RandomNumberGenerator` rather than over a
    /// concrete type, on the BusinessMath session's advice and for its reason: a
    /// caller handing in their own generator is the thing people actually want
    /// from a seeded spreadsheet, and depending on the protocol means nothing
    /// downstream of us can move under this.
    ///
    /// - Parameter generator: The generator to draw from.
    public init(_ generator: Generator) {
        self.generator = generator
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
        let draw: UInt64 = generator.next()
        return Double(draw) * 0x1.0p-64
    }

    /// A uniform integer in `0..<bound`, without bias.
    ///
    /// Delegates to the stdlib's `next(upperBound:)`, which rejects and redraws
    /// rather than folding the range — so every outcome is equally likely even
    /// when `bound` does not divide the generator's range.
    public func nextInteger(below bound: Int) -> Int {
        guard bound > 1 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        return Int(generator.next(upperBound: UInt64(bound)))
    }
}

extension SeededRandomSource where Generator == DeterministicRNG {

    /// A source over BusinessMath's deterministic generator, seeded.
    ///
    /// The default, because binding to the same engine BusinessMath uses for its
    /// own simulation work is the point: two generators in one dependency chain
    /// could disagree about what a seeded stream is.
    ///
    /// - Parameter seed: The seed. Equal seeds give equal streams, which is the
    ///   property Excel cannot offer at all.
    public convenience init(seed: UInt64) {
        self.init(DeterministicRNG(seed: seed))
    }
}
