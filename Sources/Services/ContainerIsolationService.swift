import Foundation

#if canImport(Containerization)
@preconcurrency import Containerization
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
@MainActor
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
    /// Guest init image; its version must match the containerization package
    /// pinned in Package.swift.
    static let initfsReference = "ghcr.io/apple/containerization/vminit:0.47.0"

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
        let network = try VmnetNetwork()

        // containerization reuses an existing initfs.ext4 whatever vminit built it;
        // rebuild it when our pinned vminit changes, or the guest agent won't match.
        let storeRoot = Self.defaultStoreRoot()
        Self.discardStaleInitFilesystem(storeRoot: storeRoot, reference: Self.initfsReference)

        // Initialize container manager with kernel and network
        // vminit will be fetched automatically from registry on first use
        self.containerManager = try await ContainerManager(
            kernel: kernel,
            initfsReference: Self.initfsReference,
            network: network
        )
        Self.recordInitFilesystem(storeRoot: storeRoot, reference: Self.initfsReference)
    }

    /// containerization's default store: ~/Library/Application Support/com.apple.containerization
    static func defaultStoreRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.apple.containerization", isDirectory: true)
    }

    private static let initFilesystemMarker = "mac-runner-initfs-reference"

    /// Delete initfs.ext4 unless it was built from `reference`.
    static func discardStaleInitFilesystem(storeRoot: URL, reference: String) {
        let marker = storeRoot.appendingPathComponent(initFilesystemMarker)
        let builtFrom = try? String(contentsOf: marker, encoding: .utf8)
        guard builtFrom?.trimmingCharacters(in: .whitespacesAndNewlines) != reference else { return }
        try? FileManager.default.removeItem(at: storeRoot.appendingPathComponent("initfs.ext4"))
    }

    static func recordInitFilesystem(storeRoot: URL, reference: String) {
        try? (reference + "\n").write(
            to: storeRoot.appendingPathComponent(initFilesystemMarker),
            atomically: true,
            encoding: .utf8
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

        let configuration: @Sendable (inout LinuxContainer.Configuration) -> Void = { containerConfig in
            // Resource allocation
            containerConfig.cpus = config.cpuCount
            containerConfig.memoryInBytes = config.memoryInBytes

            // Job workspaces and diagnostics live on the host.
            containerConfig.mounts.append(
                .share(source: config.workspaceURL.path, destination: ContainerRunnerScript.workMount)
            )
            if let diagnosticsURL = config.diagnosticsURL {
                containerConfig.mounts.append(
                    .share(source: diagnosticsURL.path, destination: ContainerRunnerScript.diagnosticsMount)
                )
            }

            // A resolvable hostname named after the runner (sudo warns otherwise).
            let hostname = ContainerRunnerScript.hostname(for: config.runnerName)
            containerConfig.hostname = hostname
            var hosts = Hosts.default
            hosts.entries.append(Hosts.Entry(ipAddress: "127.0.1.1", hostnames: [hostname]))
            containerConfig.hosts = hosts

            containerConfig.process.arguments = ["/bin/bash", "-c", ContainerRunnerScript.script]
            containerConfig.process.workingDirectory = "/"
            containerConfig.process.environmentVariables.append(
                contentsOf: ContainerRunnerScript.environment(for: config)
            )

            if let logWriter = config.logWriter {
                containerConfig.process.stdout = logWriter
                containerConfig.process.stderr = logWriter
            }

            if config.enableNestedVirtualization {
                // Reserved for framework support.
            }
        }

        // A crash or failed start can leave this runner's previous container
        // behind, and create() refuses to reuse the id.
        if activeContainers[id] == nil {
            try? manager.delete(id)
        }

        // Create container with specified configuration
        let container = try await manager.create(
            id,
            reference: imageReference,
            rootfsSizeInBytes: config.diskSizeInBytes,
            configuration: configuration
        )

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
            return "Container isolation needs a Linux kernel at \(path.path). Download kata-static-*-arm64.tar.xz from https://github.com/kata-containers/kata-containers/releases and copy opt/kata/share/kata-containers/vmlinux.container there as vmlinux."
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

// MARK: - Logging

/// Appends data to a log file. Shared by a process's stdout and stderr, so
/// writes are serialized and `close()` is idempotent.
final class FileLogWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var isClosed = false

    init(path: String) throws {
        handle = try RunnerLogs.openForAppending(path)
    }

    func write(_ data: Data) throws {
        try lock.withLock {
            guard !isClosed else { return }
            try handle.write(contentsOf: data)
        }
    }

    func close() throws {
        try lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            try handle.close()
        }
    }
}

#if canImport(Containerization)
extension FileLogWriter: Writer {}
#endif

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

    /// Path to the runner workspace on the host (mounted as the runner's work directory).
    var workspaceURL: URL

    /// Host directory mounted for the runner's diagnostics logs.
    var diagnosticsURL: URL?

    /// GitHub repository URL for runner registration.
    var repositoryURL: String

    /// Registration token for the runner.
    var registrationToken: String

    /// Name and labels the runner registers with.
    var runnerName: String
    var labels: [String]

    /// Tools to install when the container starts (see `ToolProvisioningService.plan`).
    var tools: [String] = []

    /// Linux runner tarball, used only when the image doesn't include the runner.
    var runnerDownloadURL: String

    /// Maximum open file limit to set before starting the runner.
    var openFileLimit: Int = ResourceLimits.defaultOpenFileLimit

    /// Receives the container process's stdout and stderr (the runner's
    /// `runner.log` on the host), so logs work the same as other modes.
    var logWriter: FileLogWriter?

    /// Default container image: GitHub's official runner image, which ships the
    /// Actions runner in /home/runner. (`ghcr.io/actions/runner` doesn't exist.)
    static let defaultRunnerImage = "ghcr.io/actions/actions-runner:latest"
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
