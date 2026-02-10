// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacRunner",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "mac-runner",
            targets: ["MacRunner"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "MacRunner",
            dependencies: [],
            path: "Sources"
        ),
        .testTarget(
            name: "MacRunnerTests",
            dependencies: ["MacRunner"],
            path: "Tests"
        )
    ]
)
