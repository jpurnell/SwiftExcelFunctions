import Foundation

/// A `RandomNumberGenerator` view of a ``RandomSource``.
///
/// Most of BusinessMath's distributions expose a `quantile`, so a single uniform
/// is enough and this is not needed. The multivariate ones do not: a correlated
/// draw has no scalar inverse, so `sample(using:)` asks for a generator and does
/// its own Cholesky work internally.
///
/// Sampling the marginals independently instead would type-check and throw away
/// the correlation, which is the entire reason those distributions exist. So the
/// generator is bridged rather than the mathematics reimplemented.
///
/// ## What the bridge costs
///
/// `nextUniform()` yields a `Double` in `[0, 1)`, which carries at most 53 bits of
/// state, so one call cannot fill a `UInt64`. Two are drawn and packed, 32 bits
/// each. That is a *derived* stream rather than the source's own bits, and it is
/// deterministic: the same ``RandomSource`` state gives the same sequence, which is
/// the only reproducibility this package promises.
///
/// It is not a cryptographic generator and is not offered as one. Nothing here
/// reaches for system entropy — the caller still supplies every bit.
struct RandomSourceGenerator: RandomNumberGenerator {

    private let source: any RandomSource

    init(_ source: any RandomSource) {
        self.source = source
    }

    /// A 64-bit value packed from two uniform draws.
    ///
    /// - Returns: The next value in the derived stream.
    mutating func next() -> UInt64 {
        let scale = Double(UInt32.max) + 1
        let high = UInt64(source.nextUniform() * scale)
        let low = UInt64(source.nextUniform() * scale)
        return (high << 32) | low
    }
}
