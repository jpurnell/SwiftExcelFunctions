import XCTest
@testable import SwiftExcelFunctions
import SwiftExcelCore

final class FunctionRegistryTests: XCTestCase {

    // MARK: - Empty Registry

    func testEmptyRegistryHasZeroCount() {
        let registry = FunctionRegistry()
        XCTAssertEqual(registry.count, 0)
    }

    func testEmptyRegistryReturnsNilForLookup() {
        let registry = FunctionRegistry()
        XCTAssertNil(registry.function(named: "SUM"))
    }

    // MARK: - Register and Lookup

    func testRegisterAndLookupFunction() throws {
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
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "DOUBLE")

        let result = try XCTUnwrap(found).evaluate([.number(5)])
        XCTAssertEqual(result, .number(10))
    }

    // MARK: - Case-Insensitive Lookup

    func testCaseInsensitiveLookup() {
        var registry = FunctionRegistry()
        let fn = ExcelFunction(
            name: "SUM",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        registry.register(fn)

        XCTAssertNotNil(registry.function(named: "sum"))
        XCTAssertNotNil(registry.function(named: "Sum"))
        XCTAssertNotNil(registry.function(named: "SUM"))
        XCTAssertNotNil(registry.function(named: "sUm"))
    }

    // MARK: - Function Not Found

    func testFunctionNotFoundReturnsNil() {
        var registry = FunctionRegistry()
        let fn = ExcelFunction(
            name: "SUM",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        registry.register(fn)

        XCTAssertNil(registry.function(named: "AVERAGE"))
    }

    // MARK: - Extending

    func testExtendingCreatesNewRegistryWithoutModifyingBase() {
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
        XCTAssertNotNil(extended.function(named: "SUM"))
        XCTAssertNotNil(extended.function(named: "AVERAGE"))
        XCTAssertEqual(extended.count, 2)

        // Base is unchanged
        XCTAssertNotNil(base.function(named: "SUM"))
        XCTAssertNil(base.function(named: "AVERAGE"))
        XCTAssertEqual(base.count, 1)
    }

    // MARK: - CoW Semantics

    func testCopyOnWriteSemantics() {
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
        XCTAssertEqual(original.count, 1)
        XCTAssertNil(original.function(named: "AVERAGE"))

        // Copy has both
        XCTAssertEqual(copy.count, 2)
        XCTAssertNotNil(copy.function(named: "AVERAGE"))
    }

    // MARK: - Argument Count Validation

    func testMinArgsProperty() {
        let fn = ExcelFunction(
            name: "SUM",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        XCTAssertEqual(fn.minArgs, 1)
        XCTAssertNil(fn.maxArgs) // variadic
    }

    func testMaxArgsProperty() {
        let fn = ExcelFunction(
            name: "IF",
            minArgs: 2,
            maxArgs: 3,
            evaluate: { _ in .number(0) }
        )
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 3)
    }

    func testVariadicFunctionHasNilMaxArgs() {
        let fn = ExcelFunction(
            name: "CONCAT",
            minArgs: 0,
            maxArgs: nil,
            evaluate: { _ in .text("") }
        )
        XCTAssertNil(fn.maxArgs)
    }

    // MARK: - Register Overwrites Existing

    func testRegisterOverwritesExistingFunction() throws {
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

        XCTAssertEqual(registry.count, 1)

        let found = try XCTUnwrap(registry.function(named: "DOUBLE"))
        let result = try found.evaluate([.number(5)])
        XCTAssertEqual(result, .number(15)) // v2 triples
    }

    // MARK: - Count Property

    func testCountProperty() {
        var registry = FunctionRegistry()
        XCTAssertEqual(registry.count, 0)

        let fn1 = ExcelFunction(
            name: "SUM",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        registry.register(fn1)
        XCTAssertEqual(registry.count, 1)

        let fn2 = ExcelFunction(
            name: "AVERAGE",
            minArgs: 1,
            maxArgs: nil,
            evaluate: { _ in .number(0) }
        )
        registry.register(fn2)
        XCTAssertEqual(registry.count, 2)
    }

    // MARK: - Builtin Registry

    func testBuiltinRegistryExists() {
        // For now, builtin starts empty; just verify it's accessible
        let builtin = FunctionRegistry.builtin
        XCTAssertGreaterThanOrEqual(builtin.count, 0)
    }

    // MARK: - ExcelFunction Properties

    func testExcelFunctionStoresProperties() {
        let fn = ExcelFunction(
            name: "MYFUNCTION",
            minArgs: 2,
            maxArgs: 5,
            evaluate: { _ in .blank }
        )
        XCTAssertEqual(fn.name, "MYFUNCTION")
        XCTAssertEqual(fn.minArgs, 2)
        XCTAssertEqual(fn.maxArgs, 5)
    }

    // MARK: - Evaluate Closure Works

    func testEvaluateClosureExecutes() throws {
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
        XCTAssertEqual(result, .number(10))
    }

    func testEvaluateClosureCanThrow() {
        let fn = ExcelFunction(
            name: "FAIL",
            minArgs: 0,
            maxArgs: 0,
            evaluate: { _ in throw ExcelFunctionError.invalidArgCount(expected: 1, got: 0) }
        )
        XCTAssertThrowsError(try fn.evaluate([]))
    }

    // MARK: - Extending with Default Base

    func testExtendingWithDefaultBase() {
        let fn = ExcelFunction(
            name: "CUSTOM",
            minArgs: 0,
            maxArgs: nil,
            evaluate: { _ in .text("custom") }
        )
        let registry = FunctionRegistry.extending(with: ["CUSTOM": fn])
        XCTAssertNotNil(registry.function(named: "CUSTOM"))
    }
}
