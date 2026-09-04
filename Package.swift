// swift-tools-version: 6.0
import PackageDescription

// SwiftExcelCore is not yet published, so it resolves by path. Both dependencies
// become pinned tags at the first release — see project/master_plan.md.
let package = Package(
    name: "SwiftExcelFunctions",
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: [
        .library(name: "SwiftExcelFunctions", targets: ["SwiftExcelFunctions"])
    ],
    dependencies: [
        .package(path: "../SwiftExcelCore"),
        .package(url: "https://github.com/jpurnell/BusinessMath", exact: "2.9.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.3")
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
        .testTarget(
            name: "SwiftExcelFunctionsTests",
            dependencies: ["SwiftExcelFunctions"],
            path: "Tests/SwiftExcelFunctionsTests"
        )
    ]
)
