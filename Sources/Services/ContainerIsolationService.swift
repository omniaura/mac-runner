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
/// - Linux kernel 6.14.9+ (supplied by Mac Runner via a bundled or local `vmlinux`)
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
    ///   - kernelPath: Path to the Linux kernel binary (`vmlinux`) that Mac Runner resolved.
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
        // Verify kernel exists
        guard FileManager.default.fileExists(atPath: kernelPath.path) else {
            throw ContainerIsolationError.kernelNotFound(kernelPath)
        }

        // Create image store directory if needed
        try FileManager.default.createDirectory(
            at: imageStorePath,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Load the Linux kernel
        let kernel = Kernel(path: kernelPath, platform: .linuxArm)

        // Create network configuration (vmnet shared mode)
        let network = try ContainerManager.VmnetNetwork()

        // Initialize container manager with kernel and network
        // vminit will be fetched automatically from registry on first use
        self.containerManager = try await ContainerManager(
            kernel: kernel,
            initfsReference: "ghcr.io/apple/containerization/vminit:0.13.0",
            network: network
        )
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
        config: ContainerRunnerConfiguration
    ) async throws -> LinuxContainer {
        // Ensure container manager is initialized
        guard var manager = containerManager else {
            throw ContainerIsolationError.notInitialized
        }

        // Determine which container image to use
        let imageReference = config.containerImage ?? ContainerRunnerConfiguration.defaultRunnerImage

        // Create container with specified configuration
        let container = try await manager.create(
            id,
            reference: imageReference,
            rootfsSizeInBytes: config.diskSizeInBytes
        ) { containerConfig in
            // Resource allocation
            containerConfig.cpus = config.cpuCount
            containerConfig.memoryInBytes = config.memoryInBytes

            // Mount runner workspace into container
            containerConfig.mounts.append(
                .share(
                    source: config.workspaceURL.path,
                    destination: "/runner/_work"
                )
            )

            // Configure the runner process
            containerConfig.process.arguments = [
                "/bin/bash",
                "-c",
                """
                # Install GitHub Actions runner if not present
                if [ ! -f /runner/run.sh ]; then
                    cd /runner
                    curl -o actions-runner-linux-arm64.tar.gz -L https://github.com/actions/runner/releases/latest/download/actions-runner-linux-arm64.tar.gz
                    tar xzf actions-runner-linux-arm64.tar.gz
                    rm actions-runner-linux-arm64.tar.gz
                fi

                # Configure and start runner
                cd /runner
                ./config.sh --unattended --url \(config.repositoryURL) --token \(config.registrationToken)
                ./run.sh
                """
            ]
            containerConfig.process.workingDirectory = "/runner"

            // Set environment variables
            containerConfig.process.environmentVariables.append("RUNNER_ALLOW_RUNASROOT=1")

            // Enable nested virtualization if requested
            if config.enableNestedVirtualization {
                // Note: This may not be supported in all versions of the framework
                // containerConfig.enableNestedVirtualization = true
            }
        }

        // Store mutated manager back
        self.containerManager = manager

        // Store in active containers map
        activeContainers[id] = container

        return container
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
        guard var manager = containerManager else {
            throw ContainerIsolationError.notInitialized
        }

        // Stop container if it's still running
        if let container = activeContainers[id] {
            do {
                try await stopContainer(container)
            } catch {
                // Log error but continue with deletion
                print("Warning: Failed to stop container \(id): \(error)")
            }
        }

        // Remove from active containers
        activeContainers.removeValue(forKey: id)

        // Clean up container resources via manager
        try manager.delete(id)
        self.containerManager = manager
    }

    /// Cleans up all containers and shuts down the service.
    func shutdown() async throws {
        // Stop all active containers
        for (id, container) in activeContainers {
            do {
                try await stopContainer(container)
            } catch {
                print("Warning: Failed to stop container \(id) during shutdown: \(error)")
            }
        }

        // Clear active containers map
        activeContainers.removeAll()

        // Container manager will be deallocated naturally
        containerManager = nil
    }

    // MARK: - Status & Monitoring

    /// Returns the container for a given runner ID, if it exists.
    ///
    /// - Parameter id: The runner/container ID.
    /// - Returns: The active container, or nil if not found.
    func getContainer(id: String) -> LinuxContainer? {
        return activeContainers[id]
    }

    /// Returns the number of active containers.
    var activeContainerCount: Int {
        return activeContainers.count
    }

    /// Returns whether the service is initialized.
    var isInitialized: Bool {
        return containerManager != nil
    }

    #else
    // Container isolation not available on this platform
    init() {
        fatalError("Container isolation is only available on macOS 26+ with Containerization framework")
    }
    #endif
}

// MARK: - Errors

/// Errors that can occur during container isolation operations.
enum ContainerIsolationError: Error, LocalizedError {
    case notInitialized
    case kernelNotFound(URL)
    case containerNotFound(String)
    case creationFailed(String)
    case startFailed(String)
    case stopFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Container isolation service not initialized. Call initialize() first."
        case .kernelNotFound(let path):
            return "Linux kernel not found at path: \(path.path)"
        case .containerNotFound(let id):
            return "Container not found: \(id)"
        case .creationFailed(let message):
            return "Failed to create container: \(message)"
        case .startFailed(let message):
            return "Failed to start container: \(message)"
        case .stopFailed(let message):
            return "Failed to stop container: \(message)"
        }
    }
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
