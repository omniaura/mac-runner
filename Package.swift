// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacRunner",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MacRunner",
            targets: ["MacRunner"]
        )
    ],
    dependencies: [
        // Keychain access for secure token storage
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "MacRunner",
            dependencies: ["KeychainAccess"],
            path: "Sources"
        ),
        .testTarget(
            name: "MacRunnerTests",
            dependencies: ["MacRunner"],
            path: "Tests"
        )
    ]
)
