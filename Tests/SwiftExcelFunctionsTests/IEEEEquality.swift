extension Array where Element == Double {
    /// Whether the two arrays have the same count and each element is IEEE 754 equal to its
    /// partner.
    ///
    /// That is exactly what `==` on `[Double]` decides. The name is the point: these tests
    /// assert spreadsheet results that are whole numbers or exact by construction — a column
    /// count, a broadcast of small integers — so exact comparison is the claim being made,
    /// and naming it says so rather than leaving a reader to wonder whether a tolerance was
    /// forgotten.
    func isElementwiseEqual(to other: [Double]) -> Bool {
        count == other.count && zip(self, other).allSatisfy { $0.isEqual(to: $1) }
    }
}
