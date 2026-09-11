// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftExcelFunctions",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: [
        .library(name: "SwiftExcelFunctions", targets: ["SwiftExcelFunctions"]),
        .library(name: "WorkbookAudit", targets: ["WorkbookAudit"]),
        .executable(name: "workbook-census", targets: ["WorkbookCensus"])
    ],
    dependencies: [
        // The shared vocabulary, and deliberately not `exact:`. SwiftPM must unify the
        // family on one SwiftExcelCore — two versions would mean two `CellValue` types
        // and nothing would typecheck — and `from:` enforces that better than `exact:`,
        // by resolving to the highest version satisfying everyone rather than refusing.
        .package(url: "https://github.com/jpurnell/SwiftExcelCore", from: "0.8.0"),
        // The mathematics. On the 3.0.0 prerelease line, and `.upToNextMinor` rather
        // than `exact:` for two reasons. SwiftPM excludes prereleases from a version
        // range *unless the lower bound is itself a prerelease*, so `from: "2.11.0"`
        // cannot see an alpha at all and a bare `from: "3.0.0-alpha.3"` is the same
        // trap one version up. And an `exact:` pin here would deadlock the moment a
        // second consumer in one build pinned BusinessMath differently — which is
        // precisely what stopped this repo resolving once before.
        //
        // The range admits 3.0.0-alpha.4 and 3.0.0 final without a Package.swift edit,
        // which is what an alpha line wants. Revisit when 3.0.0 ships.
        .package(url: "https://github.com/jpurnell/BusinessMath", .upToNextMinor(from: "3.0.0-alpha.3")),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
        // Test-only: FormulaParserIntegrationTests needs SwiftXLSX's parser to feed
        // this package's evaluator. 0.13.0 is the release that removed these
        // functions from SwiftXLSX — anything earlier would import a second
        // FormulaEvaluator and make every reference ambiguous.
        // `upToNextMinor` rather than `from:`: this family ships breaking changes in
        // minor versions while it is pre-1.0, so a patch should flow freely and a minor
        // should be a deliberate bump.
        .package(url: "https://github.com/jpurnell/SwiftXLSX", .upToNextMinor(from: "0.24.1"))
    ],
    targets: [
        .target(
            name: "SwiftExcelFunctions",
            dependencies: [
                .product(name: "SwiftExcelCore", package: "SwiftExcelCore"),
                .product(name: "BusinessMath", package: "BusinessMath")
            ],
            path: "Sources/SwiftExcelFunctions",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        // Reads files, so it depends on SwiftXLSX where the library above deliberately
        // does not. That separation is the point: `SwiftExcelFunctions` promises to take
        // no dependency on a file format, and an auditor of *files* is a different
        // product with a different promise.
        // A corpus scanner, and an executable rather than a test on purpose. Two earlier
        // attempts at this were XCTestCases and both were abandoned mid-run having
        // produced nothing: a test prints only at the end, cannot resume, and gives no way
        // to tell a working run from a hung one. See `WorkbookCensus/main.swift`.
        .executableTarget(
            name: "WorkbookCensus",
            dependencies: [
                "SwiftExcelFunctions",
                .product(name: "SwiftExcelCore", package: "SwiftExcelCore"),
                .product(name: "SwiftXLSX", package: "SwiftXLSX")
            ],
            path: "Sources/WorkbookCensus",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "WorkbookAudit",
            dependencies: [
                "SwiftExcelFunctions",
                .product(name: "SwiftExcelCore", package: "SwiftExcelCore"),
                .product(name: "SwiftXLSX", package: "SwiftXLSX")
            ],
            path: "Sources/WorkbookAudit",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .testTarget(
            name: "WorkbookAuditTests",
            dependencies: [
                "WorkbookAudit",
                .product(name: "SwiftXLSX", package: "SwiftXLSX")
            ],
            path: "Tests/WorkbookAuditTests"
        ),
        .testTarget(
            name: "SwiftExcelFunctionsTests",
            dependencies: [
                "SwiftExcelFunctions",
                .product(name: "SwiftXLSX", package: "SwiftXLSX")
            ],
            path: "Tests/SwiftExcelFunctionsTests"
        )
    ]
)
