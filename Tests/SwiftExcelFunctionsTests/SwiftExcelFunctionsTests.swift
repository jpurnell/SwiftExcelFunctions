import Testing
@testable import SwiftExcelFunctions

/// The package is reachable, and so is the vocabulary it computes over.
///
/// A placeholder until the 73 functions are extracted from SwiftXLSX. It does
/// assert one thing worth asserting now: that this package can see
/// `SwiftExcelCore`, which is the seam the whole family is built on.
@Test func theModuleIsImportable() {
    #expect(!SwiftExcelFunctions.version.isEmpty)
}
