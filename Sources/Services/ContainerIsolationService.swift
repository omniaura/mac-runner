import Foundation

#if canImport(Containerization)
import Containerization
#endif

/// Service for managing container-based isolation of GitHub Actions runners.
///
/// This service leverages Apple's Containerization framework to run Linux-based
/// GitHub Actions workflows in isolated, lightweight virtual machines.
///
/// ## Requirements
/// - macOS 26.0+
/// - Apple Silicon (arm64)
/// - Linux kernel 6.14.9+ (provided by the framework)
///
/// ## Architecture
/// Each containerized runner runs in its own lightweight VM with:
/// - Dedicated CPU and memory allocation
/// - Isolated network namespace
/// - Mounted workspace directory
/// - GitHub Actions runner environment
@available(macOS 26.0, *)
class ContainerIsolationService {
    #if canImport(Containerization)
    // MARK: - Properties

    /// The container manager responsible for container lifecycle.
    private var containerManager: ContainerManager?

    /// Path to the Linux kernel binary.
    private let kernelPath: URL

    /// Path to the image store for OCI images.
    private let imageStorePath: URL

    /// Active containers mapped by runner ID.
    private var activeContainers: [String: LinuxContainer] = [:]

    // MARK: - Initialization

    /// Creates a new container isolation service.
    ///
    /// - Parameters:
    ///   - kernelPath: Path to the Linux kernel binary (vmlinux).
    ///   - imageStorePath: Path to the directory for storing OCI images.
    init(kernelPath: URL, imageStorePath: URL) {
        self.kernelPath = kernelPath
        self.imageStorePath = imageStorePath
    }

    // MARK: - Lifecycle

    /// Initializes the container manager and networking.
    ///
    /// This must be called before creating any containers.
    ///
    /// - Throws: If initialization fails (e.g., kernel not found, networking unavailable).
    func initialize() async throws {
        // TODO: Phase 3 implementation
        // 1. Load kernel from kernelPath
        // 2. Create ContainerManager with kernel and network
        // 3. Fetch vminit from registry if needed
        fatalError("Not yet implemented - Phase 3")
    }

    /// Creates a new container for a GitHub Actions runner.
    ///
    /// - Parameters:
    ///   - id: Unique identifier for the runner/container.
    ///   - config: Configuration for the runner.
    /// - Returns: A configured `LinuxContainer` ready to start.
    /// - Throws: If container creation fails.
    func createRunnerContainer(
        id: String,
        config: RunnerConfiguration
    ) async throws -> LinuxContainer {
        // TODO: Phase 3 implementation
        // 1. Get container manager (ensure initialized)
        // 2. Determine container image (default or user-specified)
        // 3. Create container with proper configuration
        // 4. Store in activeContainers
        fatalError("Not yet implemented - Phase 3")
    }

    /// Starts a container.
    ///
    /// - Parameter container: The container to start.
    /// - Throws: If the container fails to start.
    func startContainer(_ container: LinuxContainer) async throws {
        // TODO: Phase 3 implementation
        try await container.create()
        try await container.start()
    }

    /// Stops a container.
    ///
    /// - Parameter container: The container to stop.
    /// - Throws: If the container fails to stop.
    func stopContainer(_ container: LinuxContainer) async throws {
        // TODO: Phase 3 implementation
        try await container.stop()
    }

    /// Deletes a container and cleans up resources.
    ///
    /// - Parameter id: The container ID to delete.
    /// - Throws: If cleanup fails.
    func deleteContainer(id: String) async throws {
        // TODO: Phase 3 implementation
        // 1. Stop container if running
        // 2. Remove from activeContainers
        // 3. Clean up container resources via manager
        fatalError("Not yet implemented - Phase 3")
    }

    /// Cleans up all containers and shuts down the service.
    func shutdown() async throws {
        // TODO: Phase 3 implementation
        // 1. Stop all active containers
        // 2. Clean up resources
        // 3. Shut down container manager
        fatalError("Not yet implemented - Phase 3")
    }

    #else
    // Container isolation not available on this platform
    init() {
        fatalError("Container isolation is only available on macOS 26+ with Containerization framework")
    }
    #endif
}

// MARK: - Configuration

/// Configuration for a containerized runner.
struct ContainerRunnerConfiguration {
    /// The OCI image reference for the container (e.g., "docker.io/library/ubuntu:22.04").
    var containerImage: String?

    /// Number of CPU cores to allocate.
    var cpuCount: Int = 2

    /// Memory in bytes to allocate.
    var memoryInBytes: UInt64 = 2 * 1024 * 1024 * 1024  // 2 GiB

    /// Root filesystem size in bytes.
    var diskSizeInBytes: UInt64 = 4 * 1024 * 1024 * 1024  // 4 GiB

    /// Whether to enable nested virtualization.
    var enableNestedVirtualization: Bool = false

    /// Path to the runner workspace on the host.
    var workspaceURL: URL

    /// GitHub repository URL for runner registration.
    var repositoryURL: String

    /// Registration token for the runner.
    var registrationToken: String

    /// Default container image for GitHub Actions runners.
    static let defaultRunnerImage = "ghcr.io/actions/runner:latest"
}

// MARK: - Helper Extensions

extension UInt64 {
    /// Returns the value in gibibytes (GiB).
    static func gib(_ value: Int) -> UInt64 {
        return UInt64(value) * 1024 * 1024 * 1024
    }

    /// Returns the value in mebibytes (MiB).
    static func mib(_ value: Int) -> UInt64 {
        return UInt64(value) * 1024 * 1024
    }
}
