import Foundation
import Combine
import ServiceManagement

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
    private var runnerProcesses: [UUID: Process] = [:]
    private(set) var currentSettings: AppSettings = .default
    private var statusPollingTask: Task<Void, Never>?
    private var runnersToAutoRestart: Set<UUID> = []

    init() {
        loadConfiguration()

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

    deinit {
        statusPollingTask?.cancel()
    }

    // MARK: - Configuration

    func loadConfiguration() {
        do {
            let config = try configService.loadConfig()
            runners = config.runners
            currentSettings = config.settings
        } catch {
            self.error = "Failed to load config: \(error.localizedDescription)"
        }
    }

    func saveConfiguration() {
        do {
            let config = RunnerConfig(runners: runners, settings: currentSettings)
            try configService.saveConfig(config)
        } catch {
            self.error = "Failed to save config: \(error.localizedDescription)"
        }
    }

    func updateSettings(_ settings: AppSettings) {
        let loginChanged = settings.startOnLogin != currentSettings.startOnLogin
        currentSettings = settings
        saveConfiguration()
        if loginChanged {
            syncLoginItem()
        }
    }

    // MARK: - Login Item

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

    func addRunner(name: String, repo: String, labels: [String]) async throws {
        isLoading = true
        defer { isLoading = false }

        // Validate repo access via gh CLI
        guard try await ghService.validateRepo(repo) else {
            throw RunnerError.invalidRepo
        }

        // Get registration token from GitHub via gh CLI
        let registrationToken = try await ghService.getRegistrationToken(for: repo)

        // Create runner
        let runner = Runner(
            name: name,
            repo: repo,
            labels: labels,
            enabled: true,
            status: .stopped
        )

        // Download, configure, and install runner
        try await RunnerInstaller.shared.setupRunner(
            repo: repo,
            registrationToken: registrationToken,
            name: name,
            labels: labels,
            runnerId: runner.id,
            isolation: currentSettings.isolationMode
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

    func startRunner(_ id: UUID) async throws {
        guard let index = runners.firstIndex(where: { $0.id == id }) else {
            throw RunnerError.notFound
        }

        // Check if already running via in-memory process or PID file
        if runnerProcesses[id] != nil || processManager.isProcessAlive(for: id) {
            throw RunnerError.alreadyRunning
        }

        let runner = runners[index]
        let isolation = currentSettings.isolationMode

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
        let process = try processManager.startProcess(
            for: id,
            executable: "\(runnerDir)/run.sh",
            workingDirectory: runnerDir,
            logFile: logFile,
            isolation: isolation
        )

        // Store process reference for in-memory tracking (GUI)
        runnerProcesses[id] = process

        runners[index].status = .running
        saveConfiguration()
    }

    func stopRunner(_ id: UUID) async throws {
        guard let index = runners.firstIndex(where: { $0.id == id }) else {
            throw RunnerError.notFound
        }

        let isolation = currentSettings.isolationMode

        // Stop process and clean up PID file
        let inMemoryProcess = runnerProcesses[id]
        try processManager.stopProcess(for: id, isolation: isolation, inMemoryProcess: inMemoryProcess)

        if inMemoryProcess != nil {
            runnerProcesses.removeValue(forKey: id)
        }

        runners[index].status = .stopped
        saveConfiguration()
    }

    func pauseAll() async throws {
        for runner in runners where runner.status == .running {
            try await stopRunner(runner.id)
            if let index = runners.firstIndex(where: { $0.id == runner.id }) {
                runners[index].status = .paused
            }
        }
        saveConfiguration()
    }

    func resumeAll() async throws {
        for runner in runners where runner.status == .paused {
            try await startRunner(runner.id)
        }
    }

    // MARK: - Lookup

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

        // Create duplicate with same settings
        try await addRunner(
            name: newName,
            repo: originalRunner.repo,
            labels: originalRunner.labels
        )
    }

    // MARK: - Private Helpers

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

    var errorDescription: String? {
        switch self {
        case .notFound: return "Runner not found"
        case .alreadyRunning: return "Runner is already running"
        case .notRunning: return "Runner is not running"
        case .invalidRepo: return "Invalid repository or no access"
        case .startFailed: return "Failed to start runner process"
        }
    }
}
