// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacRunner",
    platforms: [
        .macOS(.v13)  // Base platform support
        // Note: Container isolation requires macOS 26+
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
        .executableTarget(
            name: "MacRunner",
            dependencies: [
                .product(name: "Containerization", package: "containerization", condition: .when(platforms: [.macOS]))
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "MacRunnerTests",
            dependencies: ["MacRunner"],
            path: "Tests"
        )
    ]
)
