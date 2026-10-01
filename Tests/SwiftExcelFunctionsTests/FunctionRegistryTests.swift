import Foundation
import Testing
@testable import SwiftExcelFunctions
import SwiftExcelCore

@Suite struct FunctionRegistryTests {

    // MARK: - Empty Registry

    @Test func emptyRegistryHasZeroCount() {
        let registry = FunctionRegistry()
        #expect(registry.count == 0)
    }

    @Test func emptyRegistryReturnsNilForLookup() {
        let registry = FunctionRegistry()
        #expect(registry.function(named: "SUM") == nil)
    }

    // MARK: - Register and Lookup

    @Test func registerAndLookupFunction() throws {
        var registry = FunctionRegistry()
        let fn = ExcelFunction(
            name: "DOUBLE",
            minArgs: 1,
            maxArgs: 1,
            evaluate: { args in
                guard case .number(let n) = args[0] else { return .error(.value) }
                return .number(n * 2)
            }
        )
        registry.register(fn)

        let found = registry.function(named: "DOUBLE")
        #expect(found?.name == "DOUBLE")

        let result = try #require(found).evaluate([.number(5)])
        #expect(result == .number(10))
    }

    // MARK: - Case-Insensitive Lookup

    @Test func caseInsensitiveLookup() {
        var registry = FunctionRegistry()
        let fn = ExcelFunction(
            name: "SUM",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        registry.register(fn)

        #expect(registry.resolvedName("sum") == "SUM")
        #expect(registry.resolvedName("Sum") == "SUM")
        #expect(registry.resolvedName("SUM") == "SUM")
        #expect(registry.resolvedName("sUm") == "SUM")
    }

    // MARK: - Function Not Found

    @Test func functionNotFoundReturnsNil() {
        var registry = FunctionRegistry()
        let fn = ExcelFunction(
            name: "SUM",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        registry.register(fn)

        #expect(registry.function(named: "AVERAGE") == nil)
    }

    // MARK: - Extending

    @Test func extendingCreatesNewRegistryWithoutModifyingBase() {
        var base = FunctionRegistry()
        let sumFn = ExcelFunction(
            name: "SUM",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        base.register(sumFn)

        let avgFn = ExcelFunction(
            name: "AVERAGE",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )

        let extended = FunctionRegistry.extending(base, with: ["AVERAGE": avgFn])

        // Extended has both
        #expect(extended.resolvedName("SUM") == "SUM")
        #expect(extended.resolvedName("AVERAGE") == "AVERAGE")
        #expect(extended.count == 2)

        // Base is unchanged
        #expect(base.resolvedName("SUM") == "SUM")
        #expect(base.function(named: "AVERAGE") == nil)
        #expect(base.count == 1)
    }

    // MARK: - CoW Semantics

    @Test func copyOnWriteSemantics() {
        var original = FunctionRegistry()
        let fn = ExcelFunction(
            name: "SUM",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        original.register(fn)

        // Copy the registry
        var copy = original

        // Mutate the copy
        let avgFn = ExcelFunction(
            name: "AVERAGE",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        copy.register(avgFn)

        // Original is unchanged
        #expect(original.count == 1)
        #expect(original.function(named: "AVERAGE") == nil)

        // Copy has both
        #expect(copy.count == 2)
        #expect(copy.resolvedName("AVERAGE") == "AVERAGE")
    }

    // MARK: - Argument Count Validation

    @Test func minArgsProperty() {
        let fn = ExcelFunction(
            name: "SUM",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        #expect(fn.minArgs == 1)
        #expect(fn.maxArgs == nil) // variadic
    }

    @Test func maxArgsProperty() {
        let fn = ExcelFunction(
            name: "IF",
            minArgs: 2,
            maxArgs: 3,
            evaluate: { _ in .number(0) }
        )
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == 3)
    }

    @Test func variadicFunctionHasNilMaxArgs() {
        let fn = ExcelFunction(
            name: "CONCAT",
            minArgs: 0,
            maxArgs: nil,
            evaluate: { _ in .text("") }
        )
        #expect(fn.maxArgs == nil)
    }

    // MARK: - Register Overwrites Existing

    @Test func registerOverwritesExistingFunction() throws {
        var registry = FunctionRegistry()

        let v1 = ExcelFunction(
            name: "DOUBLE",
            minArgs: 1,
            maxArgs: 1,
            evaluate: { args in
                guard case .number(let n) = args[0] else { return .error(.value) }
                return .number(n * 2)
            }
        )
        registry.register(v1)

        let v2 = ExcelFunction(
            name: "DOUBLE",
            minArgs: 1,
            maxArgs: 1,
            evaluate: { args in
                guard case .number(let n) = args[0] else { return .error(.value) }
                return .number(n * 3)
            }
        )
        registry.register(v2)

        #expect(registry.count == 1)

        let found = try #require(registry.function(named: "DOUBLE"))
        let result = try found.evaluate([.number(5)])
        #expect(result == .number(15)) // v2 triples
    }

    // MARK: - Count Property

    @Test func countProperty() {
        var registry = FunctionRegistry()
        #expect(registry.count == 0)

        let fn1 = ExcelFunction(
            name: "SUM",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        registry.register(fn1)
        #expect(registry.count == 1)

        let fn2 = ExcelFunction(
            name: "AVERAGE",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        registry.register(fn2)
        #expect(registry.count == 2)
    }

    // MARK: - Builtin Registry

    @Test func builtinRegistryExists() {
        // For now, builtin starts empty; just verify it's accessible
        let builtin = FunctionRegistry.builtin
        #expect(builtin.count >= 0)
    }

    // MARK: - ExcelFunction Properties

    @Test func excelFunctionStoresProperties() {
        let fn = ExcelFunction(
            name: "MYFUNCTION",
            minArgs: 2,
            maxArgs: 5,
            evaluate: { _ in .blank }
        )
        #expect(fn.name == "MYFUNCTION")
        #expect(fn.minArgs == 2)
        #expect(fn.maxArgs == 5)
    }

    // MARK: - Evaluate Closure Works

    @Test func evaluateClosureExecutes() throws {
        let fn = ExcelFunction(
            name: "ADD",
            minArgs: 2,
            maxArgs: 2,
            evaluate: { args in
                guard case .number(let a) = args[0],
                      case .number(let b) = args[1] else {
                    return .error(.value)
                }
                return .number(a + b)
            }
        )
        let result = try fn.evaluate([.number(3), .number(7)])
        #expect(result == .number(10))
    }

    @Test func evaluateClosureCanThrow() {
        let fn = ExcelFunction(
            name: "FAIL",
            minArgs: 0,
            maxArgs: 0,
            evaluate: { _ in throw ExcelFunctionError.invalidArgCount(expected: 1, got: 0) }
        )
        #expect(throws: (any Error).self) { try fn.evaluate([]) }
    }

    // MARK: - Extending with Default Base

    @Test func extendingWithDefaultBase() {
        let fn = ExcelFunction(
            name: "CUSTOM",
            minArgs: 0,
            maxArgs: nil,
            evaluate: { _ in .text("custom") }
        )
        let registry = FunctionRegistry.extending(with: ["CUSTOM": fn])
        #expect(registry.resolvedName("CUSTOM") == "CUSTOM")
    }
}
