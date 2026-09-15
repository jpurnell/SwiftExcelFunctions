import Foundation
import SwiftExcelCore
import XCTest
@testable import SwiftExcelFunctions

/// `INDEX`'s fourth argument, which selects an area of a multi-area reference.
///
/// Found by the oracle: seven cells in real workbooks wrote `INDEX(…, 1, 1, 1)` and this
/// package refused the call on its argument count — a harsher answer than Excel gives to a
/// formula it accepts, and one that says nothing about whether the answer would be right.
final class IndexAreaArgumentTests: XCTestCase {

    private let registry = FunctionRegistry.builtin

    private func index(_ args: CellValue...) throws -> CellValue {
        let function = try XCTUnwrap(registry.function(named: "INDEX"))
        return try function.evaluate(args)
    }

    private var vector: CellValue {
        .array(CellMatrix(row: [.number(10), .number(20), .number(30)]))
    }

    func testTheFourthArgumentIsAccepted() throws {
        XCTAssertEqual(try index(.number(7), .number(1), .number(1), .number(1)), .number(7))
        XCTAssertEqual(try index(vector, .number(1), .number(2), .number(1)), .number(20))
    }

    /// There is only one area to choose, so asking for a second is `#REF!`.
    ///
    /// Answering from the first area regardless would be the plausible wrong answer: a
    /// number of the right shape, from the wrong place.
    func testASecondAreaIsRefused() throws {
        XCTAssertEqual(try index(.number(7), .number(1), .number(1), .number(2)), .error(.ref))
        XCTAssertEqual(try index(vector, .number(1), .number(2), .number(3)), .error(.ref))
    }

    /// The shorter forms keep working — two arguments still means one index.
    func testTheExistingFormsAreUnchanged() throws {
        XCTAssertEqual(try index(vector, .number(2)), .number(20))
        XCTAssertEqual(try index(vector, .number(1), .number(3)), .number(30))
        XCTAssertEqual(try index(vector, .number(4)), .error(.ref))
    }
}
