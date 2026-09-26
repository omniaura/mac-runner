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
        // Exact: the guest init image (ContainerIsolationService.initfsReference) must
        // match this version, or the VM's agent can't decode the host's requests.
        .package(url: "https://github.com/apple/containerization.git", exact: "0.47.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0")
    ],
    targets: [
        .executableTarget(
            name: "MacRunner",
            dependencies: [
                .product(name: "Containerization", package: "containerization", condition: .when(platforms: [.macOS])),
                .product(name: "Yams", package: "Yams")
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
