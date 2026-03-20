// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacRunner",
    platforms: [
        .macOS(.v15)  // Required by Containerization package
        // Note: Container isolation runtime requires macOS 26+ (checked at runtime)
    ],
    products: [
        .executable(
            name: "mac-runner",
            targets: ["MacRunner"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", from: "0.25.1")
    ],
    targets: [
        .target(
            name: "CHelpers",
            path: "Sources/CHelpers"
        ),
        .executableTarget(
            name: "MacRunner",
            dependencies: [
                .product(name: "Containerization", package: "containerization", condition: .when(platforms: [.macOS])),
                "CHelpers"
            ],
            path: "Sources",
            exclude: ["CHelpers"]
        ),
        .testTarget(
            name: "MacRunnerTests",
            dependencies: ["MacRunner"],
            path: "Tests"
        )
    ]
)
