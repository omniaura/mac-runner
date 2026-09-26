import AppKit
import Foundation
import Combine
import ServiceManagement

#if canImport(Containerization)
import Containerization
#endif

@MainActor
class RunnerManager: ObservableObject {
    enum LoginItemAction: Equatable {
        case register
        case unregister
        case none
    }

    private enum UpdateStatusMessages {
        static let defaultAutomaticChecks = "Checks GitHub releases on launch and once per day."
        static let alreadyChecking = "Update check already in progress."
        static let checking = "Checking for updates..."
        static let alreadyInstalling = "Update install already in progress."
    }

    @Published var runners: [Runner] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published private(set) var availableUpdate: AvailableUpdate?
    @Published private(set) var isCheckingForUpdates = false
    @Published private(set) var isInstallingUpdate = false
    @Published private(set) var updateStatusMessage = UpdateStatusMessages.defaultAutomaticChecks
    @Published private(set) var gitHubAuthIssue: String?
    /// Internal battery state; nil on Macs without a battery.
    @Published private(set) var powerState: PowerState?
    /// Jobs seen on each runner since the app launched, newest first.
    @Published private(set) var recentJobs: [UUID: [RecentJob]] = [:]
    /// Latest CPU/memory/disk sample per running runner.
    @Published private(set) var resourceUsage: [UUID: RunnerResourceUsage] = [:]
    /// Busy runners that will pause as soon as their current job finishes.
    @Published private(set) var pendingAutoPauses: [UUID: AutoPauseReason] = [:]

    private let configService = ConfigService()
    private let ghService = GHCLIService.shared
    private let isolationService = UserIsolationService.shared
    private let toolProvisioningService = ToolProvisioningService()
    private let jobNotificationService = JobNotificationService.shared
    private let processManager = ProcessManager()
    private let pidManager = PIDFileManager()
    private let updateChecker = UpdateChecker()
    private let updateInstaller = UpdateInstaller()
    private let diskCleanupService = DiskCleanupService()
    #if canImport(Containerization)
    private var _containerService: Any?  // ContainerIsolationService, but untyped for availability
    #endif
    private var containerServiceInitializationTask: Task<Void, Never>?
    private var containerServiceInitializationError: Error?

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
    private var activeWorkflowJobs: [UUID: WorkflowJobSummary] = [:]
    /// Names reserved by in-flight addRunner calls to prevent duplicate naming race conditions.
    private var pendingRunnerNames: Set<String> = []
    private var manualStopRequests: Set<UUID> = []
    /// Runners whose startRunner is still running (container starts take a while).
    private var startingRunnerIDs: Set<UUID> = []
    private var restartAttemptHistory: [UUID: [Date]] = [:]
    private var scheduledRestarts: [UUID: Task<Void, Never>] = [:]
    private var launchTokens: [UUID: UUID] = [:]
    private let restartWindowSeconds: TimeInterval = 600
    private let restartBaseDelaySeconds = 5
    private let restartMaxDelaySeconds = 60
    private var installedUpdateVersion: String?
    private var lastAutomaticDiskCleanupCheck: Date?
    private var lastLogMaintenance: Date?
    private var lastDiskMeasurement: Date?
    private var workspaceSizes: [UUID: ResourceMonitor.DiskMeasurement] = [:]
    private var containerCPUSamples: [UUID: (instance: ObjectIdentifier, usec: UInt64, at: Date)] = [:]
    private var activeResourceAlerts: Set<ResourceAlertSettings.Limit> = []
    private var isSamplingResources = false
    private var isMeasuringDisk = false
    private let powerMonitor = PowerSourceMonitor()
    /// Only the menu bar app pauses/resumes runners automatically; one-shot CLI
    /// commands also construct a RunnerManager and must not.
    private var automationEnabled = false
    private var isEvaluatingAutoPause = false
    private var lastConfigModificationDate: Date?
    /// The config as last read from or written to disk: the common ancestor
    /// when reconciling our changes with another process's (the CLI's).
    private var lastPersistedConfig: RunnerConfig?
    private var powerSourceObserver: NSObjectProtocol?

    /// Initialize the RunnerManager and restore runtime state.
    ///
    /// Loads configuration, initializes container isolation service if available (macOS 26+),
    /// identifies runners that need auto-restart, reconciles process states, synchronizes
    /// login item registration, and starts status polling.
    init() {
        loadConfiguration()
        availableUpdate = currentSettings.autoCheckForUpdates
            ? updateChecker.storedAvailableUpdate(
                currentVersion: CLIHandler.version,
                bundlePath: Bundle.main.bundlePath
            )
            : nil
        refreshUpdateStatusMessage()
        initializeContainerService()
        Task { await refreshGitHubAuthStatus() }

        // Before reconciling, capture runners that were running but whose
        // processes are no longer alive — these need auto-restart after launch.
        for runner in runners where runner.status == .running {
            if !processManager.isProcessAlive(for: runner.id) {
                runnersToAutoRestart.insert(runner.id)
            }
        }

        for runner in runners where runner.busy {
            Task { [weak self] in
                await self?.restoreActiveJobState(for: runner)
            }
        }

        reconcileRunnerStates()
        reconcileLoginItemSetting()
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
            let imageStorePath = macRunnerDir.appendingPathComponent("images")

            guard let kernelPath = Self.preferredKernelPath(
                bundleResourceURL: Bundle.main.resourceURL,
                applicationSupportURL: macRunnerDir
            ) else {
                containerServiceInitializationError = ContainerIsolationError.kernelNotFound(
                    macRunnerDir.appendingPathComponent("vmlinux")
                )
                return
            }

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
                        self.containerServiceInitializationError = nil
                    }
                } catch {
                    await MainActor.run {
                        self.containerServiceInitializationError = error
                    }
                }
            }
        }
        #endif
    }

    #if canImport(Containerization)
    nonisolated static func preferredKernelPath(
        bundleResourceURL: URL?,
        applicationSupportURL: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        let candidates = [
            bundleResourceURL?.appendingPathComponent("vmlinux"),
            applicationSupportURL.appendingPathComponent("vmlinux")
        ].compactMap { $0 }

        return candidates.first { fileExists($0.path) }
    }
    #endif

    deinit {
        statusPollingTask?.cancel()
        for task in scheduledRestarts.values {
            task.cancel()
        }
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
            lastConfigModificationDate = configService.modificationDate()
            lastPersistedConfig = config
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
            // Fold in anything another process wrote since we last read, so
            // this save can't overwrite it.
            reloadExternalConfigChanges()
            let config = RunnerConfig(runners: runners, settings: currentSettings)
            try configService.saveConfig(config)
            lastConfigModificationDate = configService.modificationDate()
            lastPersistedConfig = config
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
        let autoRestartDisabled = currentSettings.autoRestartEnabled && !settings.autoRestartEnabled
        objectWillChange.send()
        currentSettings = settings
        if autoRestartDisabled {
            cancelScheduledRestarts(clearHistory: false)
        }
        if !settings.autoCheckForUpdates {
            availableUpdate = nil
        }
        saveConfiguration()
        refreshUpdateStatusMessage()
        if loginChanged {
            syncLoginItem()
        }
    }

    func checkForUpdates(force: Bool = false) async {
        guard !isCheckingForUpdates else {
            updateStatusMessage = UpdateStatusMessages.alreadyChecking
            return
        }

        if !force && !currentSettings.autoCheckForUpdates {
            availableUpdate = nil
            refreshUpdateStatusMessage()
            return
        }

        isCheckingForUpdates = true
        updateStatusMessage = UpdateStatusMessages.checking
        defer { isCheckingForUpdates = false }

        do {
            let result = try await updateChecker.checkForUpdates(
                currentVersion: CLIHandler.version,
                bundlePath: Bundle.main.bundlePath,
                allowsAutomaticChecks: currentSettings.autoCheckForUpdates,
                force: force
            )

            switch result {
            case .skipped(let cachedUpdate):
                availableUpdate = cachedUpdate
                if cachedUpdate != nil {
                    updateStatusMessage = "Showing the last known available update."
                } else {
                    updateStatusMessage = "Already checked within the last 24 hours."
                }
            case .upToDate:
                installedUpdateVersion = nil
                availableUpdate = nil
                updateStatusMessage = "Mac Runner is up to date."
            case .updateAvailable(let update):
                if installedUpdateVersion == update.latestVersion {
                    availableUpdate = nil
                    updateStatusMessage = "Updated to \(update.latestVersion). Quit and reopen Mac Runner to use it."
                    return
                }

                availableUpdate = update
                updateStatusMessage = "Version \(update.latestVersion) is available."
            }
        } catch {
            if availableUpdate != nil {
                updateStatusMessage = "Update check failed. Showing the last known release."
            } else {
                updateStatusMessage = "Update check failed: \(error.localizedDescription)"
            }
        }
    }

    func refreshGitHubAuthStatus() async {
        let authState = await ghService.validateAuth()
        gitHubAuthIssue = authState.isAuthenticated ? nil : authState.recoveryMessage
    }

    func openUpdate() {
        guard let availableUpdate else { return }
        NSWorkspace.shared.open(availableUpdate.releaseURL)
    }

    func performAvailableUpdate() async {
        guard let availableUpdate else { return }

        switch availableUpdate.installSource {
        case .homebrewFormula, .homebrewCask:
            await installAvailableUpdate(availableUpdate)
        case .directDownload:
            openUpdate()
        }
    }

    private func installAvailableUpdate(_ update: AvailableUpdate) async {
        guard !isInstallingUpdate else {
            updateStatusMessage = UpdateStatusMessages.alreadyInstalling
            return
        }

        isInstallingUpdate = true
        updateStatusMessage = "Installing \(update.latestVersion) via Homebrew..."
        defer { isInstallingUpdate = false }

        do {
            try await updateInstaller.install(update)
            installedUpdateVersion = update.latestVersion
            availableUpdate = nil
            updateStatusMessage = "Updated to \(update.latestVersion). Quit and reopen Mac Runner to use it."
        } catch {
            updateStatusMessage = "Update failed: \(error.localizedDescription)"
        }
    }

    func currentWorkflowJob(for runnerID: UUID) -> WorkflowJobSummary? {
        activeWorkflowJobs[runnerID]
    }

    func openCurrentWorkflowRun(for runnerID: UUID) {
        guard let runURL = Self.currentWorkflowRunURL(from: activeWorkflowJobs[runnerID]) else {
            return
        }

        NSWorkspace.shared.open(runURL)
    }

    nonisolated static func currentWorkflowRunURL(from job: WorkflowJobSummary?) -> URL? {
        job?.run.htmlURL
    }

    nonisolated static func currentWorkflowDisplayName(from job: WorkflowJobSummary?) -> String? {
        guard let job else { return nil }
        return job.run.name.isEmpty ? job.name : job.run.name
    }

    private func refreshUpdateStatusMessage() {
        if let availableUpdate {
            updateStatusMessage = "Version \(availableUpdate.latestVersion) is available."
        } else if currentSettings.autoCheckForUpdates {
            updateStatusMessage = UpdateStatusMessages.defaultAutomaticChecks
        } else {
            updateStatusMessage = "Automatic update checks are off."
        }
    }

    // MARK: - Login Item

    /// Reconcile the persisted setting with the current macOS login item state.
    ///
    /// This is intentionally only performed during initialization. A user change in
    /// Mac Runner must be applied to macOS before the system state can be trusted;
    /// otherwise enabling the toggle is immediately overwritten by the old state.
    private func reconcileLoginItemSetting() {
        let osEnabled = SMAppService.mainApp.status == .enabled
        guard currentSettings.startOnLogin != osEnabled else { return }

        currentSettings.startOnLogin = osEnabled
        saveConfiguration()
    }

    /// Apply the current setting to the macOS login item registration.
    private func syncLoginItem() {
        let service = SMAppService.mainApp

        do {
            switch Self.loginItemAction(
                startOnLogin: currentSettings.startOnLogin,
                isRegistered: service.status == .enabled
            ) {
            case .register:
                try service.register()
            case .unregister:
                try service.unregister()
            case .none:
                break
            }
        } catch {
            let loginItemError = "Failed to update login item: \(error.localizedDescription)"
            currentSettings.startOnLogin = service.status == .enabled
            saveConfiguration()
            self.error = loginItemError
        }
    }

    nonisolated static func loginItemAction(
        startOnLogin: Bool,
        isRegistered: Bool
    ) -> LoginItemAction {
        switch (startOnLogin, isRegistered) {
        case (true, false): return .register
        case (false, true): return .unregister
        default: return .none
        }
    }

    // MARK: - Auto-Restart

    /// Automatically restart runners that were running before app launch.
    ///
    /// Called after initialization to restart runners that were marked as running
    /// but whose processes are no longer alive (e.g., after app restart or crash).
    /// Only restarts runners that were in the auto-restart set.
    func autoRestartRunners() async {
        if runnersToAutoRestart.isEmpty {
            await restartRunnersWithStalePathSnapshots()
            return
        }

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

        await restartRunnersWithStalePathSnapshots()
    }

    // MARK: - Runner Management

    /// Add a new GitHub Actions runner to the configuration.
    ///
    /// Downloads and configures a new GitHub Actions runner, then adds it to the runners list.
    /// The runner can optionally specify an isolation mode override, otherwise uses the global setting.
    ///
    /// - Parameters:
    ///   - name: Unique name for the runner
    ///   - repo: Target identifier — "owner/repo" for `.repo` scope, "org" for `.org` scope
    ///   - scope: Repository (default) or organization-level runner
    ///   - labels: Labels to assign to the runner for workflow targeting
    ///   - isolationMode: Optional isolation mode override (nil uses global setting)
    ///   - enableGUI: Whether to enable GUI access for this runner (default: false, headless)
    ///   - openFileLimit: Optional max open file override (nil uses global setting)
    /// - Throws: RunnerError if validation or setup fails
    func addRunner(
        name: String,
        repo: String,
        scope: RunnerScope = .repo,
        labels: [String],
        isolationMode: IsolationMode? = nil,
        enableGUI: Bool = false,
        openFileLimit: Int? = nil,
        containerImage: String? = nil
    ) async throws {
        isLoading = true
        defer { isLoading = false }

        var runner = Runner(
            name: name,
            repo: repo,
            scope: scope,
            labels: labels,
            enabled: true,
            status: .stopped,
            isolationMode: isolationMode,
            enableGUI: enableGUI,
            openFileLimit: openFileLimit
        )

        let effectiveIsolation = runner.effectiveIsolationMode(global: currentSettings.isolationMode)
        let target = runner.target
        if effectiveIsolation == .container {
            runner.containerImage = containerImage.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }

        try await toolProvisioningService.ensureGitHubCLI(isolation: effectiveIsolation)

        try await validateGitHubAuth(for: runner, operation: "add runner")

        // Validate target access via gh CLI
        guard try await ghService.validateTarget(target) else {
            throw RunnerError.invalidRepo
        }

        // Tool provisioning currently inspects repository contents to detect ecosystems
        // (Node, Python, etc.). Org-level runners have no single repo to inspect, so we
        // skip the per-repo discovery step and rely on the global extraPackages list.
        if scope == .repo {
            try await toolProvisioningService.provisionTools(
                for: repo,
                settings: currentSettings.tools,
                isolation: effectiveIsolation
            )
        }

        if effectiveIsolation == .container {
            // The Linux runner registers from inside its container when it starts;
            // decide now which tools that container installs.
            runner.containerTools = await toolProvisioningService.containerToolPlan(
                for: scope == .repo ? repo : nil,
                settings: currentSettings.tools
            )
        } else {
            // Get registration token from GitHub via gh CLI
            let registrationToken = try await ghService.getRegistrationToken(for: target)

            // Download, configure, and install runner
            try await RunnerInstaller.shared.setupRunner(
                target: target,
                registrationToken: registrationToken,
                name: name,
                labels: labels,
                runnerId: runner.id,
                isolation: effectiveIsolation
            )
        }

        // Look up the GitHub-assigned runner ID so we can delete it later
        var registeredRunner = runner
        if let remoteRunners = try? await ghService.listRemoteRunners(for: target),
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
            do {
                try await stopRunner(id)
            } catch RunnerError.containerHostedElsewhere(let pid) {
                // Its VM is still running elsewhere; keep its registration and records.
                throw RunnerError.containerHostedElsewhere(pid: pid)
            } catch {
                // Not running after all; carry on removing it.
            }
        }

        // Remove from GitHub via gh CLI. Container runners register from inside
        // their container; their ID is recorded once they come online. Without
        // one, only an offline registration with this name is removed, so a live
        // runner we can't tie to this one is never touched.
        if let runner = runners.first(where: { $0.id == id }) {
            var githubRunnerId = runner.githubRunnerId
            if githubRunnerId == nil,
               let remote = try? await ghService.listRemoteRunners(for: runner.target) {
                githubRunnerId = Self.offlineRegistration(named: runner.name, in: remote)?.id
            }
            if let ghId = githubRunnerId {
                try? await ghService.deleteRunner(target: runner.target, githubRunnerId: ghId)
            }
        }

        // Delete the on-disk workspace. A configured runner holds the extracted
        // runner release plus its _work checkout, which is easily >1 GB, so leaving
        // it behind strands storage that nothing will ever reference again.
        if let runner = runners.first(where: { $0.id == id }) {
            let isolation = runner.effectiveIsolationMode(global: currentSettings.isolationMode)
            do {
                try RunnerDirectory.remove(for: id, isolation: isolation)
            } catch {
                // Deliberately not logRunnerEvent: it resolves the log path with
                // RunnerDirectory.path(for:), which recreates the directory as a side
                // effect - here that would resurrect the workspace that just failed
                // to delete, and re-run sudo mkdir/chown for a dedicated service user.
                print("[Runner \(runner.name)] Failed to delete workspace: \(error.localizedDescription)")
            }
        }

        // Clean up PID file
        pidManager.removePID(for: id)
        manualStopRequests.remove(id)
        launchTokens.removeValue(forKey: id)
        scheduledRestarts[id]?.cancel()
        scheduledRestarts.removeValue(forKey: id)
        restartAttemptHistory.removeValue(forKey: id)
        pendingAutoPauses.removeValue(forKey: id)
        recentJobs.removeValue(forKey: id)

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

        startingRunnerIDs.insert(id)
        defer { startingRunnerIDs.remove(id) }
        scheduledRestarts[id]?.cancel()
        scheduledRestarts.removeValue(forKey: id)
        // A stop followed by a start (restart) leaves the stop's marker behind:
        // the old process's termination is ignored once its launch token is
        // gone, so clear it here or the new process's crashes look manual.
        manualStopRequests.remove(id)
        let launchToken = UUID()

        let runner = runners[index]
        // Use per-runner isolation mode if specified, otherwise use global setting
        let isolation = runner.effectiveIsolationMode(global: currentSettings.isolationMode)

        // Get runner directory
        let runnerDir = try RunnerDirectory.path(for: id, isolation: isolation)
        // Container runners install and register inside their container.
        let needsRunnerSetup = isolation != .container && !FileManager.default.fileExists(atPath: "\(runnerDir)/run.sh")

        // Ensure runner binary is downloaded and configured
        if needsRunnerSetup {
            try await validateGitHubAuth(for: runner, operation: "start runner")
            let registrationToken = try await ghService.getRegistrationToken(for: runner.target)
            try await RunnerInstaller.shared.setupRunner(
                target: runner.target,
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
            try await validateGitHubAuth(for: runner, operation: "start runner")
            // Container-based isolation (macOS 26+)
            #if canImport(Containerization)
            if #available(macOS 26.0, *) {
                // Wait for container service initialization to complete if still in progress
                if let initTask = containerServiceInitializationTask {
                    _ = await initTask.value
                }

                guard let containerService = containerService else {
                    if let initializationError = containerServiceInitializationError {
                        throw initializationError
                    }
                    throw RunnerError.containerServiceNotAvailable
                }

                // Get registration token for container configuration
                let registrationToken = try await ghService.getRegistrationToken(for: runner.target)

                // Create container configuration. `repositoryURL` is the value passed to
                // `config.sh --url` inside the container, so it must point at the org or
                // repo depending on the runner's scope.
                let runnerVersion = await RunnerInstaller.shared.resolveRunnerVersion()
                let containerConfig = ContainerRunnerConfiguration(
                    containerImage: runner.containerImage,
                    cpuCount: 2,
                    memoryInBytes: 4 * 1024 * 1024 * 1024,  // 4 GiB
                    diskSizeInBytes: 16 * 1024 * 1024 * 1024,  // 16 GiB (sparse)
                    enableNestedVirtualization: false,
                    // Mount only _work and _diag, so runner.log and diagnostics sit
                    // in the runner directory like other modes and stay out of jobs' view.
                    workspaceURL: try Self.makeDirectory(runnerDir, "_work"),
                    diagnosticsURL: try Self.makeDirectory(runnerDir, "_diag"),
                    repositoryURL: runner.target.registrationURL,
                    registrationToken: registrationToken,
                    runnerName: runner.name,
                    labels: runner.labels,
                    tools: runner.containerTools ?? [],
                    enableGUI: runner.enableGUI,
                    runnerDownloadURL: RunnerInstaller.linuxDownloadURL(version: runnerVersion),
                    openFileLimit: runner.effectiveOpenFileLimit(global: currentSettings.openFileLimit),
                    logWriter: try {
                        RunnerLogs.rotateIfNeeded(logFile)
                        RunnerLogs.pruneDiagnostics(runnerDirectory: runnerDir)
                        // Fail the start rather than run a container whose output goes nowhere.
                        return try FileLogWriter(path: logFile)
                    }()
                )

                // Create and start container
                let container = try await containerService.createRunnerContainer(
                    id: id.uuidString,
                    config: containerConfig
                )
                try await containerService.startContainer(container)

                // Store container reference
                runnerContainers[id] = container
                launchTokens[id] = launchToken
                // The VM lives in this process; record it so other Mac Runner
                // processes see the runner as running rather than stale.
                try? pidManager.writePID(ProcessInfo.processInfo.processIdentifier, for: id)
                recordGitHubRunnerIDOnceOnline(id)

                // Monitor container in background
                Task {
                    do {
                        #if canImport(Containerization)
                        if let linuxContainer = container as? LinuxContainer {
                            let exitStatus = try await linuxContainer.wait()
                            print("Container \(id.uuidString) exited with code: \(exitStatus.exitCode)")
                            await MainActor.run {
                                handleRunnerTermination(id, launchToken: launchToken, cause: .containerExit(status: Int(exitStatus.exitCode)))
                            }
                        } else {
                            await MainActor.run {
                                handleRunnerTermination(id, launchToken: launchToken, cause: .monitoringError(message: "Container handle unavailable"))
                            }
                        }
                        #endif
                    } catch {
                        await MainActor.run {
                            handleRunnerTermination(id, launchToken: launchToken, cause: .monitoringError(message: error.localizedDescription))
                        }
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
                isolation: isolation,
                enableGUI: runner.enableGUI,
                openFileLimit: runner.effectiveOpenFileLimit(global: currentSettings.openFileLimit)
            )

            // Store process reference for in-memory tracking (GUI)
            runnerProcesses[id] = process
            launchTokens[id] = launchToken

            process.terminationHandler = { [weak self] terminatedProcess in
                Task { @MainActor [weak self] in
                    self?.handleRunnerTermination(
                        id,
                        launchToken: launchToken,
                        cause: .process(
                            reason: terminatedProcess.terminationReason,
                            status: terminatedProcess.terminationStatus
                        )
                    )
                }
            }
        }

        // The runner list can be replaced while we awaited (e.g. a config
        // reload after the CLI removed another runner), so look it up again.
        guard let index = runners.firstIndex(where: { $0.id == id }) else { return }

        // A freshly started runner hasn't picked up a job yet.
        runners[index].busy = false
        if let reason = runners[index].autoPauseReason {
            // Started by hand while auto-paused: keep it running until this
            // condition clears instead of pausing it again next tick.
            runners[index].autoPauseOverride = reason
            runners[index].autoPauseReason = nil
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
        manualStopRequests.insert(id)
        activeWorkflowJobs.removeValue(forKey: id)

        // Check if this is a container-based runner
        do {
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
                        pidManager.removePID(for: id)
                    } else if let host = pidManager.readPID(for: id),
                              host != ProcessInfo.processInfo.processIdentifier,
                              pidManager.isProcessAlive(host) {
                        throw RunnerError.containerHostedElsewhere(pid: host)
                    } else {
                        pidManager.removePID(for: id)
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
        } catch {
            manualStopRequests.remove(id)
            throw error
        }

        scheduledRestarts[id]?.cancel()
        scheduledRestarts.removeValue(forKey: id)
        restartAttemptHistory.removeValue(forKey: id)
        launchTokens.removeValue(forKey: id)

        // Look the runner up again: the list can be replaced during the awaits above.
        guard let index = runners.firstIndex(where: { $0.id == id }) else { return }
        runners[index].status = .stopped
        runners[index].autoPauseOverride = nil
        // A stopped runner isn't executing anything; don't let a stale flag
        // show job activity after it restarts.
        runners[index].busy = false
        runners[index].lastRestartEvent = nil
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

    // MARK: - Auto-Pause

    /// Start pausing and resuming runners for low battery and quiet hours.
    /// Called by the menu bar app; evaluation then runs on every status poll
    /// and whenever the power source changes.
    func startAutomation() {
        guard !automationEnabled else { return }
        automationEnabled = true
        powerMonitor.startObserving()
        powerSourceObserver = NotificationCenter.default.addObserver(
            forName: .powerSourceDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.evaluateAutoPause()
            }
        }
        Task { await evaluateAutoPause() }
    }

    /// Pause runners whose auto-pause condition applies and resume the ones
    /// Mac Runner paused once it no longer does. Busy runners finish their
    /// current job first.
    func evaluateAutoPause(now: Date = Date()) async {
        guard !isEvaluatingAutoPause else { return }
        isEvaluatingAutoPause = true
        defer { isEvaluatingAutoPause = false }

        powerState = powerMonitor.currentState()
        var paused: [AutoPauseReason: [String]] = [:]
        var resumed: [String] = []

        for id in runners.map(\.id) {
            guard let runner = runners.first(where: { $0.id == id }) else { continue }
            let reason = AutoPausePolicy.reason(for: runner, settings: currentSettings, power: powerState, now: now)

            guard let reason else {
                pendingAutoPauses.removeValue(forKey: id)
                if runner.autoPauseOverride != nil, let index = runners.firstIndex(where: { $0.id == id }) {
                    runners[index].autoPauseOverride = nil
                    saveConfiguration()
                }
                guard runner.status == .paused, runner.autoPauseReason != nil else { continue }
                if await resumeAutoPausedRunner(id) {
                    resumed.append(runner.name)
                }
                continue
            }

            // A manual start overrides only the condition it was paused for;
            // a different one (e.g. low battery during quiet hours) still applies.
            if let override = runner.autoPauseOverride, override != reason,
               let index = runners.firstIndex(where: { $0.id == id }) {
                runners[index].autoPauseOverride = nil
                saveConfiguration()
            }

            if runners.first(where: { $0.id == id })?.autoPauseOverride == reason || runner.status != .running {
                pendingAutoPauses.removeValue(forKey: id)
                if runner.status == .paused, let current = runner.autoPauseReason, current != reason,
                   let index = runners.firstIndex(where: { $0.id == id }) {
                    runners[index].autoPauseReason = reason
                    saveConfiguration()
                }
                continue
            }

            if runner.busy {
                if pendingAutoPauses[id] == nil {
                    logRunnerEvent(for: runner, message: "Will pause for \(reason.displayName) after the current job.")
                }
                pendingAutoPauses[id] = reason
                continue
            }

            if await autoPauseRunner(id, reason: reason) {
                paused[reason, default: []].append(runner.name)
            }
        }

        await notifyAutoPauseChanges(paused: paused, resumed: resumed)
    }

    private func autoPauseRunner(_ id: UUID, reason: AutoPauseReason) async -> Bool {
        do {
            try await stopRunner(id)
        } catch {
            if let runner = runners.first(where: { $0.id == id }) {
                logRunnerEvent(for: runner, message: "Auto-pause for \(reason.displayName) failed: \(error.localizedDescription)")
            }
            return false
        }

        pendingAutoPauses.removeValue(forKey: id)
        guard let index = runners.firstIndex(where: { $0.id == id }) else { return false }
        runners[index].status = .paused
        runners[index].autoPauseReason = reason
        saveConfiguration()
        logRunnerEvent(for: runners[index], message: "Paused for \(reason.displayName).")
        return true
    }

    private func resumeAutoPausedRunner(_ id: UUID) async -> Bool {
        guard let index = runners.firstIndex(where: { $0.id == id }) else { return false }
        // Clear first so startRunner doesn't treat this as a manual override.
        runners[index].autoPauseReason = nil

        do {
            try await startRunner(id)
            if let runner = runners.first(where: { $0.id == id }) {
                logRunnerEvent(for: runner, message: "Resumed after auto-pause.")
            }
            return true
        } catch {
            if let refreshedIndex = runners.firstIndex(where: { $0.id == id }) {
                runners[refreshedIndex].status = .error
                runners[refreshedIndex].lastRestartEvent = "Auto-resume failed: \(error.localizedDescription)"
                logRunnerEvent(for: runners[refreshedIndex], message: runners[refreshedIndex].lastRestartEvent ?? "")
                saveConfiguration()
            }
            return false
        }
    }

    private func notifyAutoPauseChanges(paused: [AutoPauseReason: [String]], resumed: [String]) async {
        guard currentSettings.notificationsEnabled else { return }

        for (reason, names) in paused.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let detail: String
            switch reason {
            case .lowBattery:
                let level = powerState.map { "\($0.batteryLevel)%" } ?? "low"
                detail = "Battery at \(level). They resume when charging or above \(currentSettings.batteryPauseThreshold)%."
            case .quietHours:
                detail = "Quiet hours are active. They resume when the window ends."
            }
            await jobNotificationService.notifyStatus(
                identifier: "auto-pause-\(reason.rawValue)",
                title: Self.runnerCountTitle(verb: "Paused", names: names),
                body: detail
            )
        }

        if !resumed.isEmpty {
            await jobNotificationService.notifyStatus(
                identifier: "auto-resume",
                title: Self.runnerCountTitle(verb: "Resumed", names: resumed),
                body: resumed.sorted().joined(separator: ", ")
            )
        }
    }

    nonisolated static func runnerCountTitle(verb: String, names: [String]) -> String {
        names.count == 1 ? "\(verb) \(names[0])" : "\(verb) \(names.count) runners"
    }

    /// Short status for a runner's auto-pause state, for the runner list.
    func autoPauseStatus(for runner: Runner, now: Date = Date()) -> String? {
        if runner.status == .paused, let reason = runner.autoPauseReason {
            switch reason {
            case .lowBattery:
                return "Paused: battery below \(currentSettings.batteryPauseThreshold)%"
            case .quietHours:
                let end = runner.effectiveQuietHours(global: currentSettings.quietHours)?.end
                return end.map { "Paused for quiet hours until \($0)" } ?? "Paused for quiet hours"
            }
        }
        if let reason = pendingAutoPauses[runner.id] {
            return "Pausing for \(reason.displayName) after the current job"
        }
        if runner.status == .running, let override = runner.autoPauseOverride {
            return "Running during \(override.displayName) (started manually)"
        }
        return nil
    }

    /// Global auto-pause status for the menu header, or nil when nothing is configured.
    func autoPauseSummary(now: Date = Date()) -> (text: String, isActive: Bool)? {
        if AutoPausePolicy.isBatteryLow(settings: currentSettings, power: powerState), let powerState {
            return ("On battery at \(powerState.batteryLevel)% — runners paused until charging", true)
        }
        if let quietHours = currentSettings.quietHours, quietHours.enabled, quietHours.isValid {
            if quietHours.contains(now) {
                return ("Quiet hours active until \(quietHours.end)", true)
            }
            return ("Quiet hours \(quietHours.displayRange)", false)
        }
        return nil
    }

    /// Set or clear a runner's own pause schedule (nil = use the global one).
    func setQuietHours(_ quietHours: QuietHours?, for id: UUID) {
        guard let index = runners.firstIndex(where: { $0.id == id }) else { return }
        runners[index].quietHours = quietHours
        saveConfiguration()
        if automationEnabled {
            Task { await evaluateAutoPause() }
        }
    }

    // MARK: - Resource Usage

    var totalResourceUsage: RunnerResourceUsage {
        RunnerResourceUsage.total(Array(resourceUsage.values))
    }

    /// Sample CPU and memory for every running runner, and workspace size every
    /// few minutes (or when `measureDisk` is set, which also waits for it).
    /// Sampling runs off the main actor with timeouts; the status poll doesn't wait for it.
    func refreshResourceUsage(now: Date = Date(), measureDisk: Bool = false) async {
        guard !isSamplingResources else { return }
        isSamplingResources = true
        defer { isSamplingResources = false }

        struct Target: Sendable {
            let id: UUID
            let pid: pid_t?
            let directory: String
        }
        var containerIDs: Set<UUID> = []
        let targets: [Target] = runners.filter { $0.status == .running }.map { runner in
            let isolation = runner.effectiveIsolationMode(global: currentSettings.isolationMode)
            let directory = RunnerDirectory.directoryURL(for: runner.id, isolation: isolation).path
            if isolation == .container {
                containerIDs.insert(runner.id)
                return Target(id: runner.id, pid: nil, directory: directory)
            }
            let pid = runnerProcesses[runner.id]?.processIdentifier ?? pidManager.readPID(for: runner.id)
            return Target(id: runner.id, pid: pid, directory: directory)
        }

        let wantsDisk = measureDisk || lastDiskMeasurement.map { now.timeIntervalSince($0) >= 300 } ?? true
        if wantsDisk && !isMeasuringDisk {
            lastDiskMeasurement = now
            isMeasuringDisk = true
            let measure = Task { [weak self] in
                let sizes = await Task.detached(priority: .background) {
                    targets.map { ($0.id, ResourceMonitor.directorySize($0.directory)) }
                }.value
                await MainActor.run {
                    guard let self else { return }
                    for (id, size) in sizes {
                        if let size { self.workspaceSizes[id] = size }
                    }
                    self.isMeasuringDisk = false
                    self.applyWorkspaceSizes()
                }
            }
            if measureDisk {
                await measure.value
            }
        }

        let sampled: [(UUID, RunnerResourceUsage)] = await Task.detached(priority: .utility) {
            targets.map { target in
                (target.id, target.pid.map { ResourceMonitor.usage(ofProcessTree: $0) } ?? .zero)
            }
        }.value

        var usage: [UUID: RunnerResourceUsage] = [:]
        for (id, sample) in sampled {
            var entry = sample
            if containerIDs.contains(id) {
                // Nil when the container runs in another process: shown without numbers.
                guard let containerSample = await containerUsage(for: id, now: now) else { continue }
                entry = containerSample
            }
            usage[id] = entry
        }

        let active = Set(targets.map(\.id))
        workspaceSizes = workspaceSizes.filter { active.contains($0.key) }
        containerCPUSamples = containerCPUSamples.filter { active.contains($0.key) }
        resourceUsage = usage
        applyWorkspaceSizes()
        await checkResourceAlerts()
    }

    private func applyWorkspaceSizes() {
        for id in resourceUsage.keys {
            let size = workspaceSizes[id]
            resourceUsage[id]?.diskBytes = size?.bytes
            resourceUsage[id]?.diskIsPartial = size.map { !$0.isComplete } ?? false
        }
    }

    private func containerUsage(for id: UUID, now: Date) async -> RunnerResourceUsage? {
        #if canImport(Containerization)
        guard #available(macOS 26.0, *),
              let container = runnerContainers[id] as? LinuxContainer,
              let stats = try? await container.statistics(categories: [.memory, .cpu, .process]) else {
            return nil
        }
        let instance = ObjectIdentifier(container)
        var cpu = 0.0
        if let usec = stats.cpu?.usageUsec {
            // A restarted container has a new counter; only diff samples from the same one.
            if let previous = containerCPUSamples[id], previous.instance == instance {
                cpu = ResourceMonitor.cpuPercent(previousUsec: previous.usec, currentUsec: usec, elapsed: now.timeIntervalSince(previous.at))
            }
            containerCPUSamples[id] = (instance, usec, now)
        }
        return RunnerResourceUsage(
            cpuPercent: cpu,
            memoryBytes: stats.memory?.usageBytes ?? 0,
            processCount: Int(stats.process?.current ?? 0),
            diskBytes: nil
        )
        #else
        return nil
        #endif
    }

    /// Notify when total usage newly crosses a limit; each limit re-arms once
    /// usage drops back under it.
    private func checkResourceAlerts() async {
        let over = currentSettings.resourceAlerts.exceeded(by: totalResourceUsage)
        let newlyCrossed = Set(over.keys).subtracting(activeResourceAlerts)
        activeResourceAlerts = Set(over.keys)
        guard !newlyCrossed.isEmpty else { return }

        let reasons = ResourceAlertSettings.Limit.allCases.compactMap { newlyCrossed.contains($0) ? over[$0] : nil }
        await jobNotificationService.notifyStatus(
            identifier: "resource-alert",
            title: "Runners are using a lot of resources",
            body: "Total " + reasons.joined(separator: ", ") + "."
        )
    }

    // MARK: - External Config Changes

    /// Fold in edits another process (the CLI) wrote to the config file since
    /// we last read or wrote it, keeping our own unsaved changes.
    func reloadExternalConfigChanges() {
        guard let modified = configService.modificationDate(),
              modified != lastConfigModificationDate,
              let disk = try? configService.loadConfig() else {
            return
        }
        lastConfigModificationDate = modified

        let memory = RunnerConfig(runners: runners, settings: currentSettings)
        let merged = Self.reconcile(
            disk: disk,
            memory: memory,
            base: lastPersistedConfig,
            ownedRuntimeIDs: Set(runnerProcesses.keys).union(runnerContainers.keys)
        )
        lastPersistedConfig = disk

        if merged.settings != currentSettings {
            objectWillChange.send()
            currentSettings = merged.settings
        }
        if merged.runners != runners {
            runners = merged.runners
        }
    }

    /// Three-way merge of the config on disk with ours, using `base` (the last
    /// config we persisted) to tell which side changed what. Our changes win
    /// where we made them; everything else comes from disk. Runners added or
    /// removed on either side stay added or removed.
    nonisolated static func reconcile(
        disk: RunnerConfig,
        memory: RunnerConfig,
        base: RunnerConfig?,
        ownedRuntimeIDs: Set<UUID>
    ) -> RunnerConfig {
        let settings = (base.map { memory.settings != $0.settings } ?? false) ? memory.settings : disk.settings

        let baseByID = Dictionary(base?.runners.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let memoryByID = Dictionary(memory.runners.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let diskIDs = Set(disk.runners.map(\.id))

        var runners: [Runner] = []
        for diskRunner in disk.runners {
            if let memoryRunner = memoryByID[diskRunner.id] {
                runners.append(mergeRunner(
                    disk: diskRunner,
                    memory: memoryRunner,
                    base: baseByID[diskRunner.id],
                    ownsRuntime: ownedRuntimeIDs.contains(diskRunner.id)
                ))
            } else if baseByID[diskRunner.id] == nil {
                runners.append(diskRunner)  // added by the other process
            }
            // Otherwise we removed it since our last save: keep it removed.
        }
        for memoryRunner in memory.runners where !diskIDs.contains(memoryRunner.id) && baseByID[memoryRunner.id] == nil {
            runners.append(memoryRunner)  // added by us, not saved yet
        }
        // Runners in base and memory but gone from disk were removed elsewhere.

        return RunnerConfig(runners: runners, settings: settings)
    }

    nonisolated static func mergeRunner(disk: Runner, memory: Runner, base: Runner?, ownsRuntime: Bool) -> Runner {
        var merged = memory
        if base.map({ memory.configuration == $0.configuration }) ?? true {
            merged.configuration = disk.configuration
        }
        let changedStateLocally = base.map { memory.persistedState != $0.persistedState } ?? false
        if !ownsRuntime && !changedStateLocally {
            merged.persistedState = disk.persistedState
        }
        return merged
    }

    // MARK: - Declarative Config

    enum ApplyOutcome {
        case applied(note: String?)
        case failed(Error)
    }

    /// Carry out a plan from `ConfigPlanner`, reporting each change's outcome.
    /// Returns the number of failed changes.
    ///
    /// Order matters: registrations to be added are checked first so a runner
    /// isn't torn down for a replacement that can't be created; removals run
    /// before any settings change, using the isolation the runner was started
    /// with; additions and updates come last, under the new settings.
    @discardableResult
    func apply(
        _ changes: [ConfigChange],
        settings: AppSettings,
        onStep: (ConfigChange, ApplyOutcome) -> Void = { _, _ in }
    ) async -> Int {
        var failed = Set<Int>()
        func fail(_ index: Int, _ error: Error) {
            failed.insert(index)
            onStep(changes[index], .failed(error))
        }

        // 1. Check that every runner to be (re)registered can be.
        for (index, change) in changes.enumerated() {
            let desired: DesiredRunner
            switch change {
            case .add(let want), .recreate(_, let want, _): desired = want
            default: continue
            }
            do {
                try await preflightRegistration(desired)
            } catch {
                fail(index, error)
            }
        }

        // 2. Tear down with the current settings.
        for (index, change) in changes.enumerated() where !failed.contains(index) {
            switch change {
            case .remove(let runner):
                do {
                    try await removeRunner(runner.id)
                    onStep(change, .applied(note: nil))
                } catch {
                    fail(index, error)
                }
            case .recreate(let runner, _, _):
                do {
                    try await removeRunner(runner.id)
                } catch {
                    fail(index, error)
                }
            default:
                continue
            }
        }

        // 3. Settings.
        for (index, change) in changes.enumerated() where !failed.contains(index) {
            if case .settings = change {
                updateSettings(settings)
                onStep(change, .applied(note: nil))
            }
        }

        // 4. Add and update under the new settings.
        for (index, change) in changes.enumerated() where !failed.contains(index) {
            do {
                switch change {
                case .add(let desired):
                    try await addRunner(desired)
                    onStep(change, .applied(note: nil))
                case .recreate(_, let desired, _):
                    do {
                        try await addRunner(desired)
                    } catch {
                        throw ConfigApplyError.reregistrationFailed(name: desired.name, underlying: error)
                    }
                    onStep(change, .applied(note: nil))
                case .update(let runner, let desired, _, let restart):
                    onStep(change, .applied(note: try await update(runner, to: desired, restart: restart)))
                default:
                    continue
                }
            } catch {
                fail(index, error)
            }
        }
        return failed.count
    }

    /// Apply an in-place update; returns a note when a restart was deferred.
    private func update(_ runner: Runner, to desired: DesiredRunner, restart: Bool) async throws -> String? {
        guard let index = runners.firstIndex(where: { $0.id == runner.id }) else { throw RunnerError.notFound }
        runners[index].isolationMode = desired.isolation
        runners[index].enableGUI = desired.enableGUI
        runners[index].openFileLimit = desired.openFileLimit
        runners[index].quietHours = desired.quietHours
        runners[index].containerImage = desired.containerImage
        saveConfiguration()
        guard restart else { return nil }

        // Don't interrupt a job; the change applies the next time the runner starts.
        if let remote = try? await ghService.listRemoteRunners(for: runner.target),
           remote.first(where: { $0.name == runner.name })?.busy == true {
            return "restart deferred: a job is running (takes effect when the runner next starts)"
        }
        try await stopRunner(runner.id)
        try await startRunner(runner.id)
        return nil
    }

    /// Fail early, before anything is removed, if a runner couldn't be registered.
    private func preflightRegistration(_ desired: DesiredRunner) async throws {
        let auth = await ghService.validateAuth()
        guard auth.isAuthenticated else { throw GHError.authFailed(auth.recoveryMessage) }
        guard try await ghService.validateTarget(desired.target) else { throw RunnerError.invalidRepo }
    }

    private func addRunner(_ desired: DesiredRunner) async throws {
        try await addRunner(
            name: desired.name,
            repo: desired.target.identifier,
            scope: desired.target.scope,
            labels: desired.labels,
            isolationMode: desired.isolation,
            enableGUI: desired.enableGUI,
            openFileLimit: desired.openFileLimit,
            containerImage: desired.containerImage
        )
        if let quietHours = desired.quietHours, let runner = runner(named: desired.name) {
            setQuietHours(quietHours, for: runner.id)
        }
    }

    // MARK: - Container Runners

    /// Container runners whose VM runs in this process.
    var hostedContainerRunnerIDs: [UUID] {
        Array(runnerContainers.keys)
    }

    /// Whether a crash restart is scheduled or a start is in progress.
    func hasPendingRestart(_ id: UUID) -> Bool {
        scheduledRestarts[id] != nil || startingRunnerIDs.contains(id)
    }

    nonisolated static func offlineRegistration(named name: String, in remote: [RemoteRunner]) -> RemoteRunner? {
        remote.first { $0.name == name && $0.status == "offline" }
    }

    /// A container runner registers from inside its VM; remember its GitHub ID
    /// once it's online so removal can deregister exactly that runner.
    private func recordGitHubRunnerIDOnceOnline(_ id: UUID) {
        Task { [weak self] in
            for _ in 0..<24 {
                try? await Task.sleep(for: .seconds(5))
                guard let self,
                      let runner = self.runners.first(where: { $0.id == id }),
                      runner.status == .running,
                      self.runnerContainers[id] != nil else { return }
                if let remote = try? await self.ghService.listRemoteRunners(for: runner.target),
                   let match = remote.first(where: { $0.name == runner.name && $0.status == "online" }),
                   let index = self.runners.firstIndex(where: { $0.id == id }) {
                    if self.runners[index].githubRunnerId != match.id {
                        self.runners[index].githubRunnerId = match.id
                        self.saveConfiguration()
                    }
                    return
                }
            }
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
                runners[i].busy = false
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
        // Group runners by target (scope + identifier) to minimize API calls. We can't
        // group purely by `repo` string: an org-level runner and a repo-level runner can
        // share an identifier prefix, and the GitHub API endpoints differ by scope.
        let runnersByTarget = Dictionary(grouping: runners) { $0.target }
        var becameIdleRunnerIDs = Set<UUID>()

        for (target, runnersInTarget) in runnersByTarget {
            // Only check runners that are currently running
            let runningRunners = runnersInTarget.filter { $0.status == .running }
            guard !runningRunners.isEmpty else { continue }

            // Fetch remote runner status from GitHub
            guard let remoteRunners = try? await ghService.listRemoteRunners(for: target) else {
                continue
            }

            // Update busy status for each runner
            var changed = false
            for runner in runningRunners {
                if let index = runners.firstIndex(where: { $0.id == runner.id }),
                   let remoteRunner = remoteRunners.first(where: { $0.name == runner.name }) {
                    if runners[index].busy != remoteRunner.busy {
                        let becameBusy = remoteRunner.busy
                        runners[index].busy = remoteRunner.busy
                        changed = true

                        if becameBusy {
                            await handleJobStarted(for: runners[index])
                        } else {
                            await handleJobCompleted(for: runners[index])
                            becameIdleRunnerIDs.insert(runner.id)
                        }
                    }
                }
            }

            if changed {
                // Don't save config for transient busy state changes
                objectWillChange.send()
            }
        }

        if !becameIdleRunnerIDs.isEmpty {
            await restartRunnersWithStalePathSnapshots(candidateIDs: becameIdleRunnerIDs)
        }

        runAutomaticDiskCleanupIfNeeded()
        maintainRunnerLogsIfNeeded()

        if automationEnabled {
            reloadExternalConfigChanges()
            await evaluateAutoPause()
            // Sampled in the background so a slow ps/du never delays the next poll.
            Task { [weak self] in await self?.refreshResourceUsage() }
        }
    }

    nonisolated static func makeDirectory(_ parent: String, _ name: String) throws -> URL {
        let url = URL(fileURLWithPath: parent).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Path of a runner's log for `source`, without creating anything.
    func logPath(for runner: Runner, source: RunnerLogs.Source) -> String? {
        let isolation = runner.effectiveIsolationMode(global: currentSettings.isolationMode)
        let directory = RunnerDirectory.directoryURL(for: runner.id, isolation: isolation).path
        return RunnerLogs.path(for: source, runnerDirectory: directory)
    }

    /// Hourly log upkeep for runners that stay up for a long time (starting a
    /// runner already rotates and prunes). Old `_diag` files are pruned by
    /// modification time, so files still being written are never touched.
    /// `runner.log` is only rotated while the runner is idle: the listener
    /// writes a line or two per job, so no output can land between the copy
    /// and the truncate.
    private func maintainRunnerLogsIfNeeded(now: Date = Date()) {
        if let lastCheck = lastLogMaintenance, now.timeIntervalSince(lastCheck) < 3600 {
            return
        }
        lastLogMaintenance = now

        for runner in runners where runner.status == .running {
            let isolation = runner.effectiveIsolationMode(global: currentSettings.isolationMode)
            let directory = RunnerDirectory.directoryURL(for: runner.id, isolation: isolation).path
            var serviceUser: String?
            if case .dedicatedUser(let username) = isolation { serviceUser = username }

            RunnerLogs.pruneDiagnostics(runnerDirectory: directory, serviceUser: serviceUser)
            if !runner.busy {
                RunnerLogs.rotateIfNeeded(RunnerLogs.outputLogPath(runnerDirectory: directory), serviceUser: serviceUser)
            }
        }
    }

    private func runAutomaticDiskCleanupIfNeeded(now: Date = Date()) {
        guard currentSettings.automaticDiskCleanupEnabled else { return }
        if let lastCheck = lastAutomaticDiskCleanupCheck,
           now.timeIntervalSince(lastCheck) < 3600 {
            return
        }
        lastAutomaticDiskCleanupCheck = now

        let threshold = Int64(currentSettings.minimumFreeDiskSpaceGB) * 1_000_000_000
        guard let available = diskCleanupService.availableDiskBytes(), available < threshold else { return }

        do {
            let report = try diskCleanupService.cleanup(
                runners: runners,
                globalIsolationMode: currentSettings.isolationMode,
                includeSharedCaches: true,
                dryRun: false
            )
            if report.reclaimedBytes > 0 {
                print("Automatic disk cleanup reclaimed \(ByteCountFormatter.string(fromByteCount: report.reclaimedBytes, countStyle: .file)).")
            }
        } catch {
            print("Automatic disk cleanup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Duplicate Runner

    /// Strip a trailing `-N` numeric suffix from a runner name to get the base name.
    ///
    /// Examples:
    /// - `"my-runner-2"` → `"my-runner"`
    /// - `"my-runner"` → `"my-runner"`
    /// - `"my-runner-2-3"` → `"my-runner-2"`
    static func baseName(from name: String) -> String {
        guard let dashRange = name.range(of: "-", options: .backwards) else {
            return name
        }
        let suffix = String(name[dashRange.upperBound...])
        if suffix.allSatisfy(\.isNumber), !suffix.isEmpty {
            return String(name[..<dashRange.lowerBound])
        }
        return name
    }

    /// Generate a unique runner name by incrementing a numeric suffix.
    ///
    /// Checks both the existing `runners` array and `pendingRunnerNames`
    /// to avoid race conditions when multiple duplications or bulk creations
    /// are in flight concurrently.
    ///
    /// - Parameter base: The base name without numeric suffix
    /// - Returns: A unique name like `"base-2"`, `"base-3"`, etc.
    func generateUniqueRunnerName(base: String) -> String {
        let allNames = Set(runners.map(\.name)).union(pendingRunnerNames)
        var counter = 2
        var candidate = "\(base)-\(counter)"
        while allNames.contains(candidate) {
            counter += 1
            candidate = "\(base)-\(counter)"
        }
        return candidate
    }

    /// Create a duplicate of an existing runner with a new name.
    ///
    /// Strips any trailing numeric suffix from the original name to determine
    /// the base, then generates the next available incremented name. The name
    /// is reserved in `pendingRunnerNames` before the async `addRunner` call
    /// to prevent race conditions when duplicating rapidly.
    func duplicateRunner(_ id: UUID) async throws {
        guard let originalRunner = runners.first(where: { $0.id == id }) else {
            throw RunnerError.notFound
        }

        // Strip trailing -N suffix so duplicating "runner-2" yields "runner-3" not "runner-2-2"
        let base = Self.baseName(from: originalRunner.name)
        let newName = generateUniqueRunnerName(base: base)

        // Reserve the name before async work to prevent duplicates
        pendingRunnerNames.insert(newName)
        defer { pendingRunnerNames.remove(newName) }

        // Create duplicate with same settings, preserving scope, isolation mode, GUI access, and resource limits
        try await addRunner(
            name: newName,
            repo: originalRunner.repo,
            scope: originalRunner.scope,
            labels: originalRunner.labels,
            isolationMode: originalRunner.isolationMode,
            enableGUI: originalRunner.enableGUI,
            openFileLimit: originalRunner.openFileLimit,
            containerImage: originalRunner.containerImage
        )
    }

    // MARK: - Bulk Runner Creation

    /// Create multiple runner instances with auto-numbered names.
    ///
    /// When `count` is 1, creates a single runner with the exact `baseName` (current behavior).
    /// When `count` > 1, creates runners named `baseName-1`, `baseName-2`, etc.
    /// Names are reserved upfront in `pendingRunnerNames` to prevent collisions,
    /// then runners are registered sequentially.
    ///
    /// - Parameters:
    ///   - baseName: The base name for the runners
    ///   - repo: GitHub repository in "owner/repo" format
    ///   - labels: Labels to assign to each runner
    ///   - count: Number of instances to create (must be >= 1)
    ///   - isolationMode: Optional isolation mode override
    ///   - enableGUI: Whether to enable GUI access
    ///   - openFileLimit: Optional max open file override
    ///   - onProgress: Called after each runner is created with (completed, total)
    /// - Throws: RunnerError if validation or setup fails for any runner
    func addRunners(
        baseName: String,
        repo: String,
        scope: RunnerScope = .repo,
        labels: [String],
        count: Int,
        isolationMode: IsolationMode? = nil,
        enableGUI: Bool = false,
        openFileLimit: Int? = nil,
        containerImage: String? = nil,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws {
        guard count >= 1 else { return }

        // Single runner: use exact name (current behavior)
        if count == 1 {
            try await addRunner(
                name: baseName,
                repo: repo,
                scope: scope,
                labels: labels,
                isolationMode: isolationMode,
                enableGUI: enableGUI,
                openFileLimit: openFileLimit,
                containerImage: containerImage
            )
            onProgress?(1, 1)
            return
        }

        // Multiple runners: generate numbered names and reserve them upfront
        var names: [String] = []
        for i in 1...count {
            let candidate = "\(baseName)-\(i)"
            let allNames = Set(runners.map(\.name)).union(pendingRunnerNames)
            if allNames.contains(candidate) {
                // If the numbered name collides, find the next available
                let name = generateUniqueRunnerName(base: baseName)
                names.append(name)
                pendingRunnerNames.insert(name)
            } else {
                names.append(candidate)
                pendingRunnerNames.insert(candidate)
            }
        }

        // Register runners sequentially, releasing pending names as we go
        var errors: [(name: String, error: Error)] = []
        for (index, name) in names.enumerated() {
            do {
                try await addRunner(
                    name: name,
                    repo: repo,
                    scope: scope,
                    labels: labels,
                    isolationMode: isolationMode,
                    enableGUI: enableGUI,
                    openFileLimit: openFileLimit,
                    containerImage: containerImage
                )
            } catch {
                errors.append((name: name, error: error))
            }
            pendingRunnerNames.remove(name)
            onProgress?(index + 1, count)
        }

        if !errors.isEmpty {
            let message = errors.map { "\($0.name): \($0.error.localizedDescription)" }.joined(separator: "; ")
            throw RunnerError.bulkCreationPartialFailure(succeeded: count - errors.count, failed: errors.count, details: message)
        }
    }

    // MARK: - Private Helpers

    private enum RunnerTerminationCause {
        case process(reason: Process.TerminationReason, status: Int32)
        case containerExit(status: Int)
        case monitoringError(message: String)

        var isUnexpected: Bool {
            switch self {
            case .process(let reason, let status):
                return reason != .exit || status != 0
            case .containerExit(let status):
                return status != 0
            case .monitoringError:
                return true
            }
        }

        var description: String {
            switch self {
            case .process(let reason, let status):
                let reasonText = reason == .exit ? "exit" : "signal"
                return "process \(reasonText), code \(status)"
            case .containerExit(let status):
                return "container exit code \(status)"
            case .monitoringError(let message):
                return "monitoring error: \(message)"
            }
        }
    }

    /// Handle cleanup when a runner process/container terminates.
    private func handleRunnerTermination(_ id: UUID, launchToken: UUID, cause: RunnerTerminationCause) {
        guard launchTokens[id] == launchToken else { return }

        launchTokens.removeValue(forKey: id)
        runnerProcesses.removeValue(forKey: id)
        runnerContainers.removeValue(forKey: id)
        pidManager.removePID(for: id)

        let wasManualStop = manualStopRequests.remove(id) != nil
        activeWorkflowJobs.removeValue(forKey: id)

        if let index = runners.firstIndex(where: { $0.id == id }) {
            runners[index].busy = false
            if cause.isUnexpected && !wasManualStop {
                if scheduleAutoRestart(for: id, cause: cause, runnerIndex: index) {
                    saveConfiguration()
                    return
                }
                runners[index].status = .error
            } else {
                runners[index].status = .stopped
                if wasManualStop {
                    runners[index].lastRestartEvent = nil
                }
            }
            saveConfiguration()
        }
    }

    private func scheduleAutoRestart(for id: UUID, cause: RunnerTerminationCause, runnerIndex: Int) -> Bool {
        guard currentSettings.autoRestartEnabled else {
            scheduledRestarts[id]?.cancel()
            scheduledRestarts.removeValue(forKey: id)
            runners[runnerIndex].lastRestartEvent = "Runner crashed (\(cause.description)); auto-restart disabled."
            logRunnerEvent(for: runners[runnerIndex], message: runners[runnerIndex].lastRestartEvent ?? "")
            return false
        }

        let now = Date()
        var attempts = filteredRestartAttempts(for: id, now: now)
        let maxRetries = max(1, currentSettings.autoRestartMaxRetries)

        guard attempts.count < maxRetries else {
            restartAttemptHistory[id] = attempts
            runners[runnerIndex].lastRestartEvent = "Runner crashed (\(cause.description)); reached max retries (\(maxRetries)) in 10m."
            logRunnerEvent(for: runners[runnerIndex], message: runners[runnerIndex].lastRestartEvent ?? "")
            return false
        }

        attempts.append(now)
        restartAttemptHistory[id] = attempts

        let attemptNumber = attempts.count
        let delay = restartDelaySeconds(forAttempt: attemptNumber)
        runners[runnerIndex].status = .stopped
        runners[runnerIndex].lastRestartEvent = "Runner crashed (\(cause.description)); restarting in \(delay)s (attempt \(attemptNumber)/\(maxRetries))."
        logRunnerEvent(for: runners[runnerIndex], message: runners[runnerIndex].lastRestartEvent ?? "")

        scheduledRestarts[id]?.cancel()
        scheduledRestarts[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.performScheduledRestart(for: id)
        }

        return true
    }

    private func restartDelaySeconds(forAttempt attempt: Int) -> Int {
        guard attempt > 0 else { return restartBaseDelaySeconds }
        let exponentialDelay = restartBaseDelaySeconds * (1 << (attempt - 1))
        return min(exponentialDelay, restartMaxDelaySeconds)
    }

    private func performScheduledRestart(for id: UUID) async {
        // This runs inside the scheduled task: drop it from the table first, or
        // startRunner cancels it (and itself) and the restart fails at its next await.
        scheduledRestarts.removeValue(forKey: id)

        guard let runnerIndex = runners.firstIndex(where: { $0.id == id }) else { return }
        guard currentSettings.autoRestartEnabled else { return }
        guard runners[runnerIndex].status != .running else { return }

        let attempts = filteredRestartAttempts(for: id, now: Date())
        guard attempts.count <= max(1, currentSettings.autoRestartMaxRetries) else {
            runners[runnerIndex].status = .error
            runners[runnerIndex].lastRestartEvent = "Runner crashed; pending auto-restart cancelled after settings changed."
            logRunnerEvent(for: runners[runnerIndex], message: runners[runnerIndex].lastRestartEvent ?? "")
            saveConfiguration()
            return
        }

        do {
            try await startRunner(id)
            if let refreshedIndex = runners.firstIndex(where: { $0.id == id }) {
                runners[refreshedIndex].lastRestartEvent = "Runner auto-restarted successfully."
                logRunnerEvent(for: runners[refreshedIndex], message: runners[refreshedIndex].lastRestartEvent ?? "")
                saveConfiguration()
            }
        } catch {
            if let refreshedIndex = runners.firstIndex(where: { $0.id == id }) {
                runners[refreshedIndex].status = .error
                runners[refreshedIndex].lastRestartEvent = "Auto-restart failed: \(error.localizedDescription)"
                logRunnerEvent(for: runners[refreshedIndex], message: runners[refreshedIndex].lastRestartEvent ?? "")
                saveConfiguration()
            }
        }
    }

    private func filteredRestartAttempts(for id: UUID, now: Date) -> [Date] {
        let cutoff = now.addingTimeInterval(-restartWindowSeconds)
        let attempts = restartAttemptHistory[id, default: []].filter { $0 >= cutoff }
        restartAttemptHistory[id] = attempts
        return attempts
    }

    private func validateGitHubAuth(for runner: Runner, operation: String) async throws {
        let authState = await ghService.validateAuth()
        guard authState.isAuthenticated else {
            gitHubAuthIssue = authState.recoveryMessage
            error = authState.recoveryMessage
            logRunnerEvent(
                for: runner,
                message: "GitHub auth check failed during \(operation): \(authState.recoveryMessage)"
            )
            throw GHError.authFailed(authState.recoveryMessage)
        }

        gitHubAuthIssue = nil
    }

    private func restoreActiveJobState(for runner: Runner) async {
        guard activeWorkflowJobs[runner.id] == nil else { return }
        // Workflow runs are scoped to a specific repository in the GitHub API.
        // Org-level runners would require scanning every repo in the org, which
        // we don't do here — leave the active job indicator empty.
        guard runner.scope == .repo else { return }
        activeWorkflowJobs[runner.id] = try? await ghService.currentJob(for: runner.repo, runnerName: runner.name)
    }

    private func handleJobStarted(for runner: Runner) async {
        guard activeWorkflowJobs[runner.id] == nil else { return }
        guard runner.scope == .repo else { return }
        guard let job = try? await ghService.currentJob(for: runner.repo, runnerName: runner.name) else {
            return
        }

        activeWorkflowJobs[runner.id] = job
        recordJob(job, for: runner.id)
        if currentSettings.notificationsEnabled {
            await jobNotificationService.notify(event: .started, runner: runner, job: job)
        }
    }

    private func handleJobCompleted(for runner: Runner) async {
        guard let activeJob = activeWorkflowJobs[runner.id] else { return }
        defer { activeWorkflowJobs.removeValue(forKey: runner.id) }

        // Look up this exact job; its run may still be going (other jobs) and
        // GitHub can take a moment to record the result.
        var completedJob: WorkflowJobSummary?
        if runner.scope == .repo,
           let job = try? await ghService.job(for: runner.repo, id: activeJob.id, run: activeJob.run),
           job.status == "completed" {
            completedJob = job
        }

        recordJob(completedJob ?? activeJob, for: runner.id, finishedAt: Date())
        if completedJob == nil && runner.scope == .repo {
            refreshJobResultLater(activeJob, repo: runner.repo, runnerID: runner.id)
        }

        if currentSettings.notificationsEnabled {
            await jobNotificationService.notify(
                event: .completed,
                runner: runner,
                job: completedJob ?? activeJob
            )
        }
    }

    nonisolated static let recentJobLimit = 20

    /// Fill in a finished job's result once GitHub reports it.
    private func refreshJobResultLater(_ job: WorkflowJobSummary, repo: String, runnerID: UUID) {
        Task { [weak self] in
            for delay in [20, 60, 180] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                if let finished = try? await self.ghService.job(for: repo, id: job.id, run: job.run),
                   finished.status == "completed" {
                    self.recordJob(finished, for: runnerID)
                    return
                }
            }
        }
    }

    private func recordJob(_ job: WorkflowJobSummary, for runnerID: UUID, finishedAt: Date? = nil) {
        recentJobs[runnerID] = Self.updatedJobHistory(
            recentJobs[runnerID] ?? [],
            with: job,
            finishedAt: finishedAt,
            now: Date()
        )
    }

    /// Insert or update `job` (matched by id) at the front of `history`, capped at `recentJobLimit`.
    nonisolated static func updatedJobHistory(
        _ history: [RecentJob],
        with job: WorkflowJobSummary,
        finishedAt: Date?,
        now: Date
    ) -> [RecentJob] {
        var history = history
        var entry = RecentJob(job: job, startedAt: now, finishedAt: finishedAt)
        if let index = history.firstIndex(where: { $0.job.id == job.id }) {
            entry.startedAt = history[index].startedAt
            entry.finishedAt = finishedAt ?? history[index].finishedAt
            history.remove(at: index)
        }
        history.insert(entry, at: 0)
        return Array(history.prefix(recentJobLimit))
    }

    private func cancelScheduledRestarts(clearHistory: Bool) {
        for (id, task) in scheduledRestarts {
            task.cancel()
            if clearHistory {
                restartAttemptHistory.removeValue(forKey: id)
            }
        }
        scheduledRestarts.removeAll()
    }

    private func restartRunnersWithStalePathSnapshots(candidateIDs: Set<UUID>? = nil) async {
        var staleRunnerIDs: [UUID] = []
        let runnerSnapshot = runners

        for runner in runnerSnapshot {
            guard runner.status == .running else { continue }
            guard !runner.busy else { continue }
            if let candidateIDs {
                guard candidateIDs.contains(runner.id) else { continue }
            }

            let isolation = runner.effectiveIsolationMode(global: currentSettings.isolationMode)
            guard isolation != .container else { continue }
            guard processManager.isProcessAlive(for: runner.id) else { continue }
            guard let runnerDir = try? RunnerDirectory.path(for: runner.id, isolation: isolation) else { continue }
            guard RunnerEnvironment.pathSnapshotNeedsRefresh(in: runnerDir) else { continue }
            guard await runnerIsConfirmedIdle(runner) else { continue }

            staleRunnerIDs.append(runner.id)
        }

        for id in staleRunnerIDs {
            await restartRunnerForPathSnapshotRefresh(id)
        }
    }

    private func runnerIsConfirmedIdle(_ runner: Runner) async -> Bool {
        guard let remoteRunners = try? await ghService.listRemoteRunners(for: runner.target),
              let remoteRunner = remoteRunners.first(where: { $0.name == runner.name }) else {
            return false
        }

        if let index = runners.firstIndex(where: { $0.id == runner.id }) {
            runners[index].busy = remoteRunner.busy
        }

        return !remoteRunner.busy
    }

    private func restartRunnerForPathSnapshotRefresh(_ id: UUID) async {
        guard let index = runners.firstIndex(where: { $0.id == id }) else { return }
        guard runners[index].status == .running else { return }
        guard !runners[index].busy else { return }

        let runner = runners[index]
        guard await runnerIsConfirmedIdle(runner) else { return }

        logRunnerEvent(
            for: runner,
            message: "Runner PATH snapshot is stale; restarting to apply current Homebrew tool paths."
        )

        do {
            try await stopRunner(id)
            try await startRunner(id)

            if let refreshedIndex = runners.firstIndex(where: { $0.id == id }) {
                runners[refreshedIndex].lastRestartEvent = "Runner restarted to apply current Homebrew tool paths."
                logRunnerEvent(for: runners[refreshedIndex], message: runners[refreshedIndex].lastRestartEvent ?? "")
                saveConfiguration()
            }
        } catch {
            if let refreshedIndex = runners.firstIndex(where: { $0.id == id }) {
                runners[refreshedIndex].status = .error
                runners[refreshedIndex].lastRestartEvent = "Failed to refresh runner PATH: \(error.localizedDescription)"
                logRunnerEvent(for: runners[refreshedIndex], message: runners[refreshedIndex].lastRestartEvent ?? "")
                saveConfiguration()
            }
        }
    }

    private func logRunnerEvent(for runner: Runner, message: String) {
        guard !message.isEmpty else { return }

        let isolation = runner.effectiveIsolationMode(global: currentSettings.isolationMode)
        guard let runnerDir = try? RunnerDirectory.path(for: runner.id, isolation: isolation) else {
            print("[Runner \(runner.name)] \(message)")
            return
        }

        let logPath = "\(runnerDir)/runner.log"
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [mac-runner] \(message)\n"

        if let handle = try? RunnerLogs.openForAppending(logPath) {
            handle.write(Data(line.utf8))
            try? handle.close()
        }

        print("[Runner \(runner.name)] \(message)")
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
    case bulkCreationPartialFailure(succeeded: Int, failed: Int, details: String)
    case containerHostedElsewhere(pid: pid_t)

    var errorDescription: String? {
        switch self {
        case .notFound: return "Runner not found"
        case .alreadyRunning: return "Runner is already running"
        case .notRunning: return "Runner is not running"
        case .invalidRepo: return "Invalid repository or no access"
        case .startFailed: return "Failed to start runner process"
        case .containerServiceNotAvailable:
            return "Container isolation requires macOS 26.0+ and is not available on this system"
        case .bulkCreationPartialFailure(let succeeded, let failed, let details):
            return "Bulk creation: \(succeeded) succeeded, \(failed) failed (\(details))"
        case .containerHostedElsewhere(let pid):
            return "This container runner's VM runs inside another Mac Runner process (pid \(pid)). Stop it there: Ctrl-C in that terminal, or the menu bar app."
        }
    }
}
