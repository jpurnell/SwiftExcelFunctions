// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SwiftExcelFunctions",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: [
        .library(name: "SwiftExcelFunctions", targets: ["SwiftExcelFunctions"]),
        .library(name: "WorkbookAudit", targets: ["WorkbookAudit"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpurnell/SwiftExcelCore", exact: "0.6.0"),
        .package(url: "https://github.com/jpurnell/BusinessMath", from: "2.11.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3"),
        // Test-only: FormulaParserIntegrationTests needs SwiftXLSX's parser to feed
        // this package's evaluator. 0.13.0 is the release that removed these
        // functions from SwiftXLSX — anything earlier would import a second
        // FormulaEvaluator and make every reference ambiguous.
        .package(url: "https://github.com/jpurnell/SwiftXLSX", exact: "0.23.0")
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
