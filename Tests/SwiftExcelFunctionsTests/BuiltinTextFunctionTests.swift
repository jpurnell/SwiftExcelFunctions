import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

@Suite struct BuiltinTextFunctionTests {

    // MARK: - Helpers

    private func function(named name: String) -> ExcelFunction {
        guard let fn = BuiltinTextFunctions.all.first(where: { $0.name == name }) else {
            fatalError("Function \(name) not found in BuiltinTextFunctions.all")
        }
        return fn
    }

    private func eval(_ name: String, _ args: CellValue...) throws -> CellValue {
        try function(named: name).evaluate(args)
    }


    // MARK: - Registration

    /// The group's inventory, by name rather than by count — a count says something
    /// changed without saying what, and fails the same way whether a function
    /// arrived or went missing.
    @Test func allContainsEveryFunctionInTheGroup() {
        #expect(Set(BuiltinTextFunctions.all.map(\.name)) == ["LEN", "LEFT", "RIGHT", "MID", "TRIM", "UPPER", "LOWER", "CONCATENATE",
             "TEXT", "FIND", "SEARCH", "SUBSTITUTE", "PROPER", "CLEAN", "NUMBERVALUE",
             "UNICODE", "UNICHAR"])
    }

    // MARK: - LEN

    @Test func lenBasic() throws {
        let result = try eval("LEN", .text("Hello"))
        #expect(result == .number(5))
    }

    @Test func lenEmpty() throws {
        let result = try eval("LEN", .text(""))
        #expect(result == .number(0))
    }

    @Test func lenBlank() throws {
        let result = try eval("LEN", .blank)
        #expect(result == .number(0))
    }

    @Test func lenNumber() throws {
        let result = try eval("LEN", .number(123))
        #expect(result == .number(3))
    }

    @Test func lenBool() throws {
        let result = try eval("LEN", .bool(true))
        #expect(result == .number(4)) // "TRUE" = 4 chars
    }

    @Test func lenErrorPropagation() throws {
        let result = try eval("LEN", .error(.ref))
        #expect(result == .error(.ref))
    }

    // MARK: - LEFT

    @Test func leftDefault() throws {
        let result = try eval("LEFT", .text("Hello"))
        #expect(result == .text("H"))
    }

    @Test func leftWithCount() throws {
        let result = try eval("LEFT", .text("Hello"), .number(3))
        #expect(result == .text("Hel"))
    }

    @Test func leftExceedsLength() throws {
        let result = try eval("LEFT", .text("Hi"), .number(10))
        #expect(result == .text("Hi"))
    }

    @Test func leftZero() throws {
        let result = try eval("LEFT", .text("Hello"), .number(0))
        #expect(result == .text(""))
    }

    @Test func leftNegativeReturnsError() throws {
        let result = try eval("LEFT", .text("Hello"), .number(-1))
        #expect(result == .error(.num))
    }

    // MARK: - RIGHT

    @Test func rightDefault() throws {
        let result = try eval("RIGHT", .text("Hello"))
        #expect(result == .text("o"))
    }

    @Test func rightWithCount() throws {
        let result = try eval("RIGHT", .text("Hello"), .number(3))
        #expect(result == .text("llo"))
    }

    @Test func rightExceedsLength() throws {
        let result = try eval("RIGHT", .text("Hi"), .number(10))
        #expect(result == .text("Hi"))
    }

    @Test func rightZero() throws {
        let result = try eval("RIGHT", .text("Hello"), .number(0))
        #expect(result == .text(""))
    }

    // MARK: - MID

    @Test func midBasic() throws {
        let result = try eval("MID", .text("Hello World"), .number(7), .number(5))
        #expect(result == .text("World"))
    }

    @Test func midFromStart() throws {
        let result = try eval("MID", .text("Hello"), .number(1), .number(3))
        #expect(result == .text("Hel"))
    }

    @Test func midExceedsLength() throws {
        let result = try eval("MID", .text("Hi"), .number(1), .number(10))
        #expect(result == .text("Hi"))
    }

    @Test func midStartBeyondEnd() throws {
        let result = try eval("MID", .text("Hi"), .number(10), .number(1))
        #expect(result == .text(""))
    }

    @Test func midStartZeroReturnsError() throws {
        let result = try eval("MID", .text("Hello"), .number(0), .number(1))
        #expect(result == .error(.num))
    }

    // MARK: - TRIM

    @Test func trimLeadingTrailing() throws {
        let result = try eval("TRIM", .text("  Hello  "))
        #expect(result == .text("Hello"))
    }

    @Test func trimInternalSpaces() throws {
        let result = try eval("TRIM", .text("  Hello   World  "))
        #expect(result == .text("Hello World"))
    }

    @Test func trimNoSpaces() throws {
        let result = try eval("TRIM", .text("Hello"))
        #expect(result == .text("Hello"))
    }

    @Test func trimBlank() throws {
        let result = try eval("TRIM", .blank)
        #expect(result == .text(""))
    }

    // MARK: - UPPER

    @Test func upperBasic() throws {
        let result = try eval("UPPER", .text("hello"))
        #expect(result == .text("HELLO"))
    }

    @Test func upperMixed() throws {
        let result = try eval("UPPER", .text("Hello World"))
        #expect(result == .text("HELLO WORLD"))
    }

    @Test func upperNumber() throws {
        let result = try eval("UPPER", .number(42))
        #expect(result == .text("42"))
    }

    // MARK: - LOWER

    @Test func lowerBasic() throws {
        let result = try eval("LOWER", .text("HELLO"))
        #expect(result == .text("hello"))
    }

    @Test func lowerMixed() throws {
        let result = try eval("LOWER", .text("Hello World"))
        #expect(result == .text("hello world"))
    }

    // MARK: - CONCATENATE

    @Test func concatenateBasic() throws {
        let result = try eval("CONCATENATE", .text("Hello"), .text(" "), .text("World"))
        #expect(result == .text("Hello World"))
    }

    @Test func concatenateMixedTypes() throws {
        let result = try eval("CONCATENATE", .text("Value: "), .number(42))
        #expect(result == .text("Value: 42"))
    }

    @Test func concatenateBool() throws {
        let result = try eval("CONCATENATE", .text("Is: "), .bool(true))
        #expect(result == .text("Is: TRUE"))
    }

    @Test func concatenateBlank() throws {
        let result = try eval("CONCATENATE", .text("Hello"), .blank, .text("World"))
        #expect(result == .text("HelloWorld"))
    }

    @Test func concatenateSingle() throws {
        let result = try eval("CONCATENATE", .text("Solo"))
        #expect(result == .text("Solo"))
    }

    @Test func concatenateErrorPropagation() throws {
        let result = try eval("CONCATENATE", .text("Hello"), .error(.na))
        #expect(result == .error(.na))
    }

    // MARK: - TEXT

    @Test func textInteger() throws {
        let result = try eval("TEXT", .number(1234.7), .text("0"))
        #expect(result == .text("1235"))
    }

    @Test func textTwoDecimals() throws {
        let result = try eval("TEXT", .number(1234.5), .text("0.00"))
        #expect(result == .text("1234.50"))
    }

    @Test func textThousands() throws {
        let result = try eval("TEXT", .number(1234567), .text("#,##0"))
        #expect(result == .text("1,234,567"))
    }

    @Test func textThousandsWithDecimals() throws {
        let result = try eval("TEXT", .number(1234.5), .text("#,##0.00"))
        #expect(result == .text("1,234.50"))
    }

    @Test func textPercent() throws {
        let result = try eval("TEXT", .number(0.126), .text("0%"))
        #expect(result == .text("13%"))
    }

    @Test func textPercentWithDecimals() throws {
        let result = try eval("TEXT", .number(0.125), .text("0.00%"))
        #expect(result == .text("12.50%"))
    }

    @Test func textErrorPropagation() throws {
        let result = try eval("TEXT", .error(.value), .text("0.00"))
        #expect(result == .error(.value))
    }

    // MARK: - Metadata

    @Test func lenMetadata() {
        let fn = function(named: "LEN")
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == 1)
    }

    @Test func leftMetadata() {
        let fn = function(named: "LEFT")
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == 2)
    }

    @Test func midMetadata() {
        let fn = function(named: "MID")
        #expect(fn.minArgs == 3)
        #expect(fn.maxArgs == 3)
    }

    @Test func concatenateMetadata() {
        let fn = function(named: "CONCATENATE")
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == nil)
    }

    @Test func textMetadata() {
        let fn = function(named: "TEXT")
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == 2)
    }
}
