import XCTest
@testable import SwiftExcelFunctions

final class ScratchDump: XCTestCase {
    func testDumpRegistryNames() throws {
        let groups: [[ExcelFunction]] = [
            BuiltinMathFunctions.all, BuiltinStatsFunctions.all,
            BuiltinFinancialFunctions.all, BuiltinLogicFunctions.all,
            BuiltinTextFunctions.all, BuiltinNavigationFunctions.all,
            BuiltinDateTimeFunctions.all, BuiltinAggregationFunctions.all,
            BuiltinArrayFunctions.all, BuiltinRiskSolverFunctions.all,
            BuiltinBindingFunctions.all,
        ]
        var names: Set<String> = []
        for g in groups { for f in g { names.insert(f.name.uppercased()) } }
        print("REGISTRY " + names.sorted().joined(separator: ","))
    }
}
