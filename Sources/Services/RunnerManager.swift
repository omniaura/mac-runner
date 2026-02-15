import Foundation
import Combine
import ServiceManagement

#if canImport(Containerization)
import Containerization
#endif

@MainActor
class RunnerManager: ObservableObject {
    @Published var runners: [Runner] = []
    @Published var isLoading = false
    @Published var error: String?

    private let configService = ConfigService()
    private let ghService = GHCLIService.shared
    private let isolationService = UserIsolationService.shared
    private let processManager = ProcessManager()
    private let pidManager = PIDFileManager()
    #if canImport(Containerization)
    private var _containerService: Any?  // ContainerIsolationService, but untyped for availability
    #endif
    private var containerServiceInitializationTask: Task<Void, Never>?

    #if canImport(Containerization)
    @available(macOS 26, *)
    private var containerService: ContainerIsolationService? {
        get { _containerService as? ContainerIsolationService }
        set { _containerService = newValue }
    }
    #endif
    private var runnerProcesses: [UUID: Process] = [:]
    private var runnerContainers: [UUID: Any] = [:]  // [UUID: LinuxContainer] but untyped for compatibility
    private(set) var currentSettings: AppSettings = .default
    private var statusPollingTask: Task<Void, Never>?
    private var runnersToAutoRestart: Set<UUID> = []

    /// Initialize the RunnerManager and restore runtime state.
    ///
    /// Loads configuration, initializes container isolation service if available (macOS 26+),
    /// identifies runners that need auto-restart, reconciles process states, synchronizes
    /// login item registration, and starts status polling.
    init() {
        loadConfiguration()
        initializeContainerService()

        // Before reconciling, capture runners that were running but whose
        // processes are no longer alive — these need auto-restart after launch.
        for runner in runners where runner.status == .running {
            if !processManager.isProcessAlive(for: runner.id) {
                runnersToAutoRestart.insert(runner.id)
            }
        }

        reconcileRunnerStates()
        syncLoginItem()
        startStatusPolling()
    }

    /// Initialize container isolation service if available (macOS 26+)
    private func initializeContainerService() {
        #if canImport(Containerization)
        if #available(macOS 26.0, *) {
            // Setup paths for container service
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                print("Container isolation not available: Could not find Application Support directory")
                return
            }
            let macRunnerDir = appSupport.appendingPathComponent("MacRunner", isDirectory: true)

            // Kernel path (will need to be provided/downloaded)
            // For now, use a placeholder - this will be implemented in Phase 5
            let kernelPath = macRunnerDir.appendingPathComponent("vmlinux")
            let imageStorePath = macRunnerDir.appendingPathComponent("images")

            let service = ContainerIsolationService(
                kernelPath: kernelPath,
                imageStorePath: imageStorePath
            )

            // Initialize asynchronously in the background and track initialization state
            containerServiceInitializationTask = Task {
                do {
                    try await service.initialize()
                    await MainActor.run {
                        self.containerService = service
                    }
                } catch {
                    print("Container isolation not available: \(error.localizedDescription)")
                }
            }
        }
        #endif
    }

    deinit {
        statusPollingTask?.cancel()
    }

    // MARK: - Configuration

    /// Load runner configuration and settings from disk.
    ///
    /// Reads the saved configuration file and populates the runners array and settings.
    /// If loading fails, sets the error property with details.
    func loadConfiguration() {
        do {
            let config = try configService.loadConfig()
            runners = config.runners
            currentSettings = config.settings
        } catch {
            self.error = "Failed to load config: \(error.localizedDescription)"
        }
    }

    /// Save current runner configuration and settings to disk.
    ///
    /// Persists the runners array and settings to the configuration file.
    /// If saving fails, sets the error property with details.
    func saveConfiguration() {
        do {
            let config = RunnerConfig(runners: runners, settings: currentSettings)
            try configService.saveConfig(config)
        } catch {
            self.error = "Failed to save config: \(error.localizedDescription)"
        }
    }

    /// Update application settings and synchronize system state.
    ///
    /// Updates settings and persists them to disk. If the "start on login" setting changed,
    /// also updates the macOS login item registration.
    ///
    /// - Parameter settings: New application settings to apply
    func updateSettings(_ settings: AppSettings) {
        let loginChanged = settings.startOnLogin != currentSettings.startOnLogin
        currentSettings = settings
        saveConfiguration()
        if loginChanged {
            syncLoginItem()
        }
    }

    // MARK: - Login Item

    /// Synchronize the macOS login item registration with current settings.
    ///
    /// Registers or unregisters the app as a login item based on the startOnLogin setting.
    private func syncLoginItem() {
        let service = SMAppService.mainApp
        do {
            if currentSettings.startOnLogin {
                if service.status != .enabled {
                    try service.register()
                }
            } else {
                if service.status == .enabled {
                    try service.unregister()
                }
            }
        } catch {
            self.error = "Failed to update login item: \(error.localizedDescription)"
        }
    }

    // MARK: - Auto-Restart

    /// Automatically restart runners that were running before app launch.
    ///
    /// Called after initialization to restart runners that were marked as running
    /// but whose processes are no longer alive (e.g., after app restart or crash).
    /// Only restarts runners that were in the auto-restart set.
    func autoRestartRunners() async {
        guard !runnersToAutoRestart.isEmpty else { return }
        let ids = runnersToAutoRestart
        runnersToAutoRestart.removeAll()

        for id in ids {
            do {
                try await startRunner(id)
            } catch {
                if let index = runners.firstIndex(where: { $0.id == id }) {
                    runners[index].status = .error
                    saveConfiguration()
                }
            }
        }
    }

    // MARK: - Runner Management

    /// Add a new GitHub Actions runner to the configuration.
    ///
    /// Downloads and configures a new GitHub Actions runner, then adds it to the runners list.
    /// The runner can optionally specify an isolation mode override, otherwise uses the global setting.
    ///
    /// - Parameters:
    ///   - name: Unique name for the runner
    ///   - repo: GitHub repository in "owner/repo" format
    ///   - labels: Labels to assign to the runner for workflow targeting
    ///   - isolationMode: Optional isolation mode override (nil uses global setting)
    /// - Throws: RunnerError if validation or setup fails
    func addRunner(name: String, repo: String, labels: [String], isolationMode: IsolationMode? = nil) async throws {
        isLoading = true
        defer { isLoading = false }

        // Validate repo access via gh CLI
        guard try await ghService.validateRepo(repo) else {
            throw RunnerError.invalidRepo
        }

        // Get registration token from GitHub via gh CLI
        let registrationToken = try await ghService.getRegistrationToken(for: repo)

        // Create runner with optional isolation mode override
        let runner = Runner(
            name: name,
            repo: repo,
            labels: labels,
            enabled: true,
            status: .stopped,
            isolationMode: isolationMode
        )

        // Use per-runner isolation mode if specified, otherwise use global setting
        let effectiveIsolation = runner.effectiveIsolationMode(global: currentSettings.isolationMode)

        // Download, configure, and install runner
        try await RunnerInstaller.shared.setupRunner(
            repo: repo,
            registrationToken: registrationToken,
            name: name,
            labels: labels,
            runnerId: runner.id,
            isolation: effectiveIsolation
        )

        // Look up the GitHub-assigned runner ID so we can delete it later
        var registeredRunner = runner
        if let remoteRunners = try? await ghService.listRemoteRunners(for: repo),
           let match = remoteRunners.first(where: { $0.name == name }) {
            registeredRunner.githubRunnerId = match.id
        }

        // Add to list
        runners.append(registeredRunner)
        saveConfiguration()

        // Start runner
        try await startRunner(registeredRunner.id)
    }

    /// Remove a runner from the configuration and GitHub.
    ///
    /// Stops the runner if currently running, removes it from GitHub's runner list,
    /// cleans up local files, and removes it from the configuration.
    ///
    /// - Parameter id: UUID of the runner to remove
    /// - Throws: RunnerError if removal fails
    func removeRunner(_ id: UUID) async throws {
        // Stop runner if it's running (in-memory or via PID file)
        if let index = runners.firstIndex(where: { $0.id == id }), runners[index].status == .running {
            try? await stopRunner(id)
        }

        // Remove from GitHub via gh CLI
        if let runner = runners.first(where: { $0.id == id }) {
            if let ghId = runner.githubRunnerId {
                try? await ghService.deleteRunner(repo: runner.repo, githubRunnerId: ghId)
            }
        }

        // Clean up PID file
        pidManager.removePID(for: id)

        // Remove from list
        runners.removeAll(where: { $0.id == id })
        saveConfiguration()
    }

    /// Start a runner and begin accepting GitHub Actions workflow jobs.
    ///
    /// Launches the runner using the appropriate isolation mode (none, dedicated user, or container).
    /// For container isolation, creates and starts a Linux container. For process-based isolation,
    /// launches the runner as a background process. Updates the runner's status to running.
    ///
    /// - Parameter id: UUID of the runner to start
    /// - Throws: RunnerError if the runner is not found, already running, or if startup fails
    func startRunner(_ id: UUID) async throws {
        guard let index = runners.firstIndex(where: { $0.id == id }) else {
            throw RunnerError.notFound
        }

        // Check if already running via in-memory process or PID file
        if runnerProcesses[id] != nil || processManager.isProcessAlive(for: id) {
            throw RunnerError.alreadyRunning
        }

        let runner = runners[index]
        // Use per-runner isolation mode if specified, otherwise use global setting
        let isolation = runner.effectiveIsolationMode(global: currentSettings.isolationMode)

        // Get runner directory
        let runnerDir = try RunnerDirectory.path(for: id, isolation: isolation)

        // Ensure runner binary is downloaded and configured
        if !FileManager.default.fileExists(atPath: "\(runnerDir)/run.sh") {
            let registrationToken = try await ghService.getRegistrationToken(for: runner.repo)
            try await RunnerInstaller.shared.setupRunner(
                repo: runner.repo,
                registrationToken: registrationToken,
                name: runner.name,
                labels: runner.labels,
                runnerId: id,
                isolation: isolation
            )
        }

        // Launch runner as a background process that survives the parent (CLI) exiting.
        let logFile = "\(runnerDir)/runner.log"

        // Container isolation requires special handling
        if case .container = isolation {
            // Container-based isolation (macOS 26+)
            #if canImport(Containerization)
            if #available(macOS 26.0, *) {
                // Wait for container service initialization to complete if still in progress
                if let initTask = containerServiceInitializationTask {
                    _ = await initTask.value
                }

                guard let containerService = containerService else {
                    throw RunnerError.containerServiceNotAvailable
                }

                // Get registration token for container configuration
                let registrationToken = try await ghService.getRegistrationToken(for: runner.repo)

                // Create container configuration
                let containerConfig = ContainerRunnerConfiguration(
                    containerImage: nil,  // Use default GitHub Actions runner image
                    cpuCount: 2,
                    memoryInBytes: 2 * 1024 * 1024 * 1024,  // 2 GiB
                    diskSizeInBytes: 4 * 1024 * 1024 * 1024,  // 4 GiB
                    enableNestedVirtualization: false,
                    workspaceURL: URL(fileURLWithPath: runnerDir),
                    repositoryURL: runner.repo,
                    registrationToken: registrationToken
                )

                // Create and start container
                let container = try await containerService.createRunnerContainer(
                    id: id.uuidString,
                    config: containerConfig
                )
                try await containerService.startContainer(container)

                // Store container reference
                runnerContainers[id] = container

                // Monitor container in background
                Task {
                    do {
                        #if canImport(Containerization)
                        if let linuxContainer = container as? LinuxContainer {
                            let exitCode = try await linuxContainer.wait()
                            print("Container \(id.uuidString) exited with code: \(exitCode)")
                        }
                        #endif
                        await MainActor.run {
                            handleRunnerTermination(id)
                        }
                    } catch {
                        print("Container monitoring error: \(error)")
                    }
                }
            } else {
                throw RunnerError.containerServiceNotAvailable
            }
            #else
            throw RunnerError.containerServiceNotAvailable
            #endif
        } else {
            // Standard process-based isolation (.none or .dedicatedUser)
            let process = try processManager.startProcess(
                for: id,
                executable: "\(runnerDir)/run.sh",
                workingDirectory: runnerDir,
                logFile: logFile,
                isolation: isolation
            )

            // Store process reference for in-memory tracking (GUI)
            runnerProcesses[id] = process
        }

        runners[index].status = .running
        saveConfiguration()
    }

    /// Stop a running runner and terminate all its processes.
    ///
    /// For container-based runners, stops and deletes the container. For process-based runners,
    /// terminates the process tree using the appropriate method for the isolation mode.
    /// Updates the runner's status to stopped.
    ///
    /// - Parameter id: UUID of the runner to stop
    /// - Throws: RunnerError if the runner is not found, not running, or if stopping fails
    func stopRunner(_ id: UUID) async throws {
        guard let index = runners.firstIndex(where: { $0.id == id }) else {
            throw RunnerError.notFound
        }

        let runner = runners[index]
        // Use per-runner isolation mode if specified, otherwise use global setting
        let isolation = runner.effectiveIsolationMode(global: currentSettings.isolationMode)

        // Check if this is a container-based runner
        if case .container = isolation {
            #if canImport(Containerization)
            if #available(macOS 26.0, *) {
                if let container = runnerContainers[id] {
                    guard let containerService = containerService else {
                        throw RunnerError.containerServiceNotAvailable
                    }

                    // Stop and clean up container
                    if let linuxContainer = container as? LinuxContainer {
                        try await containerService.stopContainer(linuxContainer)
                    }
                    try await containerService.deleteContainer(id: id.uuidString)
                    runnerContainers.removeValue(forKey: id)
                } else {
                    throw RunnerError.notRunning
                }
            }
            #endif
        } else {
            // Standard process-based isolation - use ProcessManager
            let inMemoryProcess = runnerProcesses[id]
            try processManager.stopProcess(for: id, isolation: isolation, inMemoryProcess: inMemoryProcess)

            if inMemoryProcess != nil {
                runnerProcesses.removeValue(forKey: id)
            }
        }

        runners[index].status = .stopped
        saveConfiguration()
    }

    /// Pause all currently running runners.
    ///
    /// Stops all runners that are currently running and marks them as paused instead of stopped.
    /// Paused runners can be resumed later with `resumeAll()`.
    ///
    /// - Throws: RunnerError if stopping any runner fails
    func pauseAll() async throws {
        for runner in runners where runner.status == .running {
            try await stopRunner(runner.id)
            if let index = runners.firstIndex(where: { $0.id == runner.id }) {
                runners[index].status = .paused
            }
        }
        saveConfiguration()
    }

    /// Resume all paused runners.
    ///
    /// Starts all runners that were previously paused with `pauseAll()`.
    ///
    /// - Throws: RunnerError if starting any runner fails
    func resumeAll() async throws {
        for runner in runners where runner.status == .paused {
            try await startRunner(runner.id)
        }
    }

    // MARK: - Lookup

    /// Find a runner by name.
    ///
    /// - Parameter name: The name of the runner to find
    /// - Returns: The runner with the given name, or nil if not found
    func runner(named name: String) -> Runner? {
        runners.first(where: { $0.name == name })
    }

    // MARK: - Process State

    /// On init, reconcile config status with actual process state
    private func reconcileRunnerStates() {
        var changed = false
        for i in runners.indices {
            if runners[i].status == .running && !processManager.isProcessAlive(for: runners[i].id) {
                runners[i].status = .stopped
                pidManager.removePID(for: runners[i].id)
                changed = true
            }
        }
        if changed { saveConfiguration() }
    }

    // MARK: - Status Polling

    /// Poll GitHub API every 10 seconds to update runner busy state
    private func startStatusPolling() {
        statusPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.updateRunnerStatuses()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Update runner busy/idle status by querying the GitHub API.
    ///
    /// Groups runners by repository to minimize API calls, then updates the isBusy flag
    /// for each running runner based on whether it's currently executing a workflow.
    private func updateRunnerStatuses() async {
        // Group runners by repo to minimize API calls
        let runnersByRepo = Dictionary(grouping: runners) { $0.repo }

        for (repo, runnersInRepo) in runnersByRepo {
            // Only check runners that are currently running
            let runningRunners = runnersInRepo.filter { $0.status == .running }
            guard !runningRunners.isEmpty else { continue }

            // Fetch remote runner status from GitHub
            guard let remoteRunners = try? await ghService.listRemoteRunners(for: repo) else {
                continue
            }

            // Update busy status for each runner
            var changed = false
            for runner in runningRunners {
                if let index = runners.firstIndex(where: { $0.id == runner.id }),
                   let remoteRunner = remoteRunners.first(where: { $0.name == runner.name }) {
                    if runners[index].busy != remoteRunner.busy {
                        runners[index].busy = remoteRunner.busy
                        changed = true
                    }
                }
            }

            if changed {
                // Don't save config for transient busy state changes
                objectWillChange.send()
            }
        }
    }

    // MARK: - Duplicate Runner

    /// Create a duplicate of an existing runner with a new name
    func duplicateRunner(_ id: UUID) async throws {
        guard let originalRunner = runners.first(where: { $0.id == id }) else {
            throw RunnerError.notFound
        }

        // Generate new name with incrementing suffix
        var newName = "\(originalRunner.name)-2"
        var counter = 2
        while runners.contains(where: { $0.name == newName }) {
            counter += 1
            newName = "\(originalRunner.name)-\(counter)"
        }

        // Create duplicate with same settings, preserving isolation mode
        try await addRunner(
            name: newName,
            repo: originalRunner.repo,
            labels: originalRunner.labels,
            isolationMode: originalRunner.isolationMode
        )
    }

    // MARK: - Private Helpers

    /// Handle cleanup when a runner process terminates unexpectedly.
    ///
    /// Removes process references, cleans up PID files, and updates the runner status to stopped.
    ///
    /// - Parameter id: UUID of the terminated runner
    private func handleRunnerTermination(_ id: UUID) {
        runnerProcesses.removeValue(forKey: id)
        pidManager.removePID(for: id)

        if let index = runners.firstIndex(where: { $0.id == id }) {
            runners[index].status = .stopped
            saveConfiguration()
        }
    }
}

// MARK: - Errors

enum RunnerError: LocalizedError {
    case notFound
    case alreadyRunning
    case notRunning
    case invalidRepo
    case startFailed
    case containerServiceNotAvailable

    var errorDescription: String? {
        switch self {
        case .notFound: return "Runner not found"
        case .alreadyRunning: return "Runner is already running"
        case .notRunning: return "Runner is not running"
        case .invalidRepo: return "Invalid repository or no access"
        case .startFailed: return "Failed to start runner process"
        case .containerServiceNotAvailable:
            return "Container isolation requires macOS 26.0+ and is not available on this system"
        }
    }
}
