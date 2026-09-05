import SwiftExcelCore
/// A copy-on-write registry mapping Excel function names to Swift implementations.
///
/// ``FunctionRegistry`` stores ``ExcelFunction`` definitions indexed by their
/// case-insensitive names, and provides lookup by name. Mutations use
/// copy-on-write semantics: copying a registry is cheap, and the underlying
/// storage is only duplicated on first mutation of a shared instance.
///
/// Use ``builtin`` for a registry pre-loaded with all built-in functions:
/// ```swift
/// let registry = FunctionRegistry.builtin
/// let absFn = registry.function(named: "ABS")
/// ```
///
/// Register custom functions with ``register(_:)`` or ``register(name:function:)``:
/// ```swift
/// var registry = FunctionRegistry()
/// registry.register(ExcelFunction(name: "DOUBLE", minArgs: 1, maxArgs: 1) { args in
///     guard case .number(let n) = args[0] else { return .error(.value) }
///     return .number(n * 2)
/// })
/// ```
public struct FunctionRegistry: Sendable {

    // MARK: - CoW Storage

    // Justification: Storage is CoW — only mutated when uniquely referenced
    private final class Storage: @unchecked Sendable {
        var functions: [String: ExcelFunction]

        init(_ functions: [String: ExcelFunction] = [:]) {
            self.functions = functions
        }

        func copy() -> Storage {
            Storage(functions)
        }
    }

    private var storage: Storage

    /// Ensures the internal storage is uniquely referenced before mutating.
    private mutating func ensureUnique() {
        if !isKnownUniquelyReferenced(&storage) {
            storage = storage.copy()
        }
    }

    // MARK: - Initialization

    /// Creates an empty function registry.
    public init() {
        self.storage = Storage()
    }

    /// Creates a registry pre-populated with the given functions dictionary.
    private init(functions: [String: ExcelFunction]) {
        self.storage = Storage(functions)
    }

    // MARK: - Builtin

    /// The default registry with all built-in functions.
    ///
    /// Contains all functions from ``BuiltinMathFunctions``,
    /// ``BuiltinStatsFunctions``, ``BuiltinFinancialFunctions``,
    /// ``BuiltinLogicFunctions``, ``BuiltinTextFunctions``,
    /// ``BuiltinNavigationFunctions``, ``BuiltinDateTimeFunctions``,
    /// and ``BuiltinAggregationFunctions``.
    public static let builtin: FunctionRegistry = makeBuiltin()

    /// Creates the built-in function registry.
    ///
    /// Registers all known built-in Excel function implementations
    /// across all categories.
    /// Called once to initialize ``builtin``.
    ///
    /// - Returns: A ``FunctionRegistry`` containing all built-in functions.
    public static func makeBuiltin() -> FunctionRegistry {
        var registry = FunctionRegistry()
        let allCategories: [[ExcelFunction]] = [
            BuiltinMathFunctions.all,
            BuiltinStatsFunctions.all,
            BuiltinFinancialFunctions.all,
            BuiltinLogicFunctions.all,
            BuiltinTextFunctions.all,
            BuiltinNavigationFunctions.all,
            BuiltinDateTimeFunctions.all,
            BuiltinAggregationFunctions.all,
            BuiltinArrayFunctions.all,
            BuiltinBindingFunctions.all,
        ]
        for category in allCategories {
            for fn in category {
                registry.register(fn)
            }
        }
        for (modern, legacy) in FunctionRegistry.modernSpellings {
            guard let function = registry.function(named: legacy) else { continue }
            registry.register(ExcelFunction(
                name: modern,
                minArgs: function.minArgs,
                maxArgs: function.maxArgs,
                evaluate: function.evaluate))
        }
        return registry
    }

    /// Names Excel 2010 gave to functions that already existed.
    ///
    /// Both spellings are live. Excel renamed `STDEV` to `STDEV.S` and kept the
    /// old name working, so a workbook saved this decade writes the dotted form
    /// and one saved before it writes the bare one — and the measured corpus
    /// contains both. `STDEV.S` alone is called 86,410 times across 79 workbooks.
    ///
    /// Registered as an alias rather than reimplemented. The pair must never be
    /// able to disagree, and the only way to guarantee that is for them to be the
    /// same function under two names.
    static let modernSpellings: [(modern: String, legacy: String)] = [
        ("STDEV.S", "STDEV"),
        ("STDEV.P", "STDEVP"),
        ("VAR.S", "VAR"),
        ("VAR.P", "VARP"),
        ("PERCENTILE.INC", "PERCENTILE"),
    ]

    // MARK: - Factory

    /// Creates a new registry by extending a base registry with additional functions.
    ///
    /// The base registry is not modified. The returned registry contains all functions
    /// from both the base and the `functions` dictionary. If a name appears in both,
    /// the value from `functions` takes precedence.
    ///
    /// - Parameters:
    ///   - base: The base registry to extend. Defaults to ``builtin``.
    ///   - functions: A dictionary of additional functions keyed by name.
    /// - Returns: A new ``FunctionRegistry`` combining both sets of functions.
    public static func extending(
        _ base: FunctionRegistry = .builtin,
        with functions: [String: ExcelFunction]
    ) -> FunctionRegistry {
        var merged = base.storage.functions
        for (key, value) in functions {
            merged[key.uppercased()] = value
        }
        return FunctionRegistry(functions: merged)
    }

    // MARK: - Mutation

    /// Registers a function using its ``ExcelFunction/name`` property as the key.
    ///
    /// If a function with the same name (case-insensitive) already exists, it is replaced.
    ///
    /// - Parameter function: The ``ExcelFunction`` to register.
    public mutating func register(_ function: ExcelFunction) {
        ensureUnique()
        storage.functions[function.name.uppercased()] = function
    }

    /// Registers a function under an explicit name, replacing any existing function
    /// with the same name (case-insensitive).
    ///
    /// - Parameters:
    ///   - name: The name to register the function under (case-insensitive).
    ///   - function: The ``ExcelFunction`` implementation.
    public mutating func register(name: String, function: ExcelFunction) {
        ensureUnique()
        storage.functions[name.uppercased()] = function
    }

    // MARK: - Lookup

    /// Looks up a function by name (case-insensitive).
    ///
    /// - Parameter named: The function name to look up.
    /// - Returns: The ``ExcelFunction`` if found, or `nil`.
    public func function(named: String) -> ExcelFunction? {
        storage.functions[named.uppercased()]
    }

    // MARK: - Properties

    /// The number of registered functions.
    public var count: Int {
        storage.functions.count
    }
}
