import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

@Suite struct BuiltinLogicFunctionTests {

    // MARK: - Helpers

    /// Look up a function by name from the built-in logical set.
    private func function(named name: String) -> ExcelFunction {
        guard let fn = BuiltinLogicFunctions.all.first(where: { $0.name == name }) else {
            fatalError("Function \(name) not found in BuiltinLogicFunctions.all")
        }
        return fn
    }

    /// Evaluate a function by name with the given arguments.
    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        try function(named: name).evaluate(args)
    }


    // MARK: - Registration count

    /// The group's inventory, asserted by name rather than only by count.
    ///
    /// A count alone says a function was added but not which, and it fails the
    /// same way whether something arrived or something was lost.
    @Test func allContainsEveryFunctionInTheGroup() {
        #expect(Set(BuiltinLogicFunctions.all.map(\.name)) == ["IF", "AND", "OR", "NOT", "XOR", "IFERROR", "IFNA", "IFS", "SWITCH",
             "ISERROR", "ISERR", "ISNA", "ISBLANK", "ISNUMBER", "ISTEXT", "NA", "ISREF",
             "TRUE", "FALSE"])
    }

    // MARK: - IF

    @Test func ifTrueCondition() throws {
        let result = try eval("IF", .bool(true), .text("yes"), .text("no"))
        #expect(result == .text("yes"))
    }

    @Test func ifFalseCondition() throws {
        let result = try eval("IF", .bool(false), .text("yes"), .text("no"))
        #expect(result == .text("no"))
    }

    @Test func ifNonZeroNumber() throws {
        let result = try eval("IF", .number(42), .text("truthy"), .text("falsy"))
        #expect(result == .text("truthy"))
    }

    @Test func ifZeroNumber() throws {
        let result = try eval("IF", .number(0), .text("truthy"), .text("falsy"))
        #expect(result == .text("falsy"))
    }

    @Test func ifBlankIsFalsy() throws {
        let result = try eval("IF", .blank, .text("truthy"), .text("falsy"))
        #expect(result == .text("falsy"))
    }

    @Test func ifTextReturnsValueError() throws {
        let result = try eval("IF", .text("hello"), .text("yes"), .text("no"))
        #expect(result == .error(.value))
    }

    @Test func ifErrorPropagation() throws {
        let result = try eval("IF", .error(.ref), .text("yes"), .text("no"))
        #expect(result == .error(.ref))
    }

    @Test func ifTwoArgs() throws {
        // IF with only 2 args: if false, return FALSE
        let result = try eval("IF", .bool(false), .text("yes"))
        #expect(result == .bool(false))
    }

    @Test func ifTwoArgsTrue() throws {
        let result = try eval("IF", .bool(true), .number(10))
        #expect(result == .number(10))
    }

    // MARK: - AND

    @Test func andAllTrue() throws {
        let result = try eval("AND", .bool(true), .bool(true), .bool(true))
        #expect(result == .bool(true))
    }

    @Test func andOneFalse() throws {
        let result = try eval("AND", .bool(true), .bool(false), .bool(true))
        #expect(result == .bool(false))
    }

    @Test func andWithNumbers() throws {
        let result = try eval("AND", .number(1), .number(5), .number(-3))
        #expect(result == .bool(true))
    }

    @Test func andWithZero() throws {
        let result = try eval("AND", .number(1), .number(0))
        #expect(result == .bool(false))
    }

    @Test func andFlattensArrays() throws {
        let result = try eval("AND", .array(CellMatrix(row: [.bool(true), .bool(true)])), .bool(true))
        #expect(result == .bool(true))
    }

    @Test func andFlattensArraysWithFalse() throws {
        let result = try eval("AND", .array(CellMatrix(row: [.bool(true), .bool(false)])))
        #expect(result == .bool(false))
    }

    @Test func andErrorPropagation() throws {
        let result = try eval("AND", .bool(true), .error(.na))
        #expect(result == .error(.na))
    }

    // MARK: - OR

    @Test func orAllFalse() throws {
        let result = try eval("OR", .bool(false), .bool(false))
        #expect(result == .bool(false))
    }

    @Test func orOneTrue() throws {
        let result = try eval("OR", .bool(false), .bool(true), .bool(false))
        #expect(result == .bool(true))
    }

    @Test func orWithNumbers() throws {
        let result = try eval("OR", .number(0), .number(5))
        #expect(result == .bool(true))
    }

    @Test func orAllZeros() throws {
        let result = try eval("OR", .number(0), .number(0))
        #expect(result == .bool(false))
    }

    @Test func orFlattensArrays() throws {
        let result = try eval("OR", .array(CellMatrix(row: [.bool(false), .bool(true)])))
        #expect(result == .bool(true))
    }

    @Test func orErrorPropagation() throws {
        let result = try eval("OR", .error(.div0), .bool(true))
        #expect(result == .error(.div0))
    }

    // MARK: - NOT

    @Test func notTrue() throws {
        let result = try eval("NOT", .bool(true))
        #expect(result == .bool(false))
    }

    @Test func notFalse() throws {
        let result = try eval("NOT", .bool(false))
        #expect(result == .bool(true))
    }

    @Test func notNumber() throws {
        let result = try eval("NOT", .number(0))
        #expect(result == .bool(true))
    }

    @Test func notNonZero() throws {
        let result = try eval("NOT", .number(1))
        #expect(result == .bool(false))
    }

    @Test func notTextReturnsValueError() throws {
        let result = try eval("NOT", .text("hello"))
        #expect(result == .error(.value))
    }

    @Test func notErrorPropagation() throws {
        let result = try eval("NOT", .error(.num))
        #expect(result == .error(.num))
    }

    // MARK: - IFERROR

    @Test func iferrorWithError() throws {
        let result = try eval("IFERROR", .error(.div0), .number(0))
        #expect(result == .number(0))
    }

    @Test func iferrorWithoutError() throws {
        let result = try eval("IFERROR", .number(42), .number(0))
        #expect(result == .number(42))
    }

    @Test func iferrorWithNAError() throws {
        let result = try eval("IFERROR", .error(.na), .text("not found"))
        #expect(result == .text("not found"))
    }

    @Test func iferrorWithBlank() throws {
        let result = try eval("IFERROR", .blank, .number(0))
        #expect(result == .blank)
    }

    @Test func iferrorWithText() throws {
        let result = try eval("IFERROR", .text("hello"), .number(0))
        #expect(result == .text("hello"))
    }

    // MARK: - IFNA

    @Test func ifnaWithNAError() throws {
        let result = try eval("IFNA", .error(.na), .text("not found"))
        #expect(result == .text("not found"))
    }

    @Test func ifnaWithOtherError() throws {
        // Non-NA errors pass through
        let result = try eval("IFNA", .error(.div0), .text("not found"))
        #expect(result == .error(.div0))
    }

    @Test func ifnaWithValue() throws {
        let result = try eval("IFNA", .number(42), .text("not found"))
        #expect(result == .number(42))
    }

    @Test func ifnaWithBlank() throws {
        let result = try eval("IFNA", .blank, .text("not found"))
        #expect(result == .blank)
    }

    // MARK: - Metadata

    @Test func ifMetadata() {
        let fn = function(named: "IF")
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == 3)
    }

    @Test func andMetadata() {
        let fn = function(named: "AND")
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == nil)
    }

    @Test func orMetadata() {
        let fn = function(named: "OR")
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == nil)
    }

    @Test func notMetadata() {
        let fn = function(named: "NOT")
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == 1)
    }

    @Test func iferrorMetadata() {
        let fn = function(named: "IFERROR")
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == 2)
    }

    @Test func ifnaMetadata() {
        let fn = function(named: "IFNA")
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == 2)
    }
}
