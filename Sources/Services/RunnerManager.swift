import Foundation
import Combine

@MainActor
class RunnerManager: ObservableObject {
    @Published var runners: [Runner] = []
    @Published var isLoading = false
    @Published var error: String?

    private let configService = ConfigService()
    private let ghService = GHCLIService.shared
    private let isolationService = UserIsolationService.shared
    private var runnerProcesses: [UUID: Process] = [:]
    private(set) var currentSettings: AppSettings = .default
    private var statusPollingTask: Task<Void, Never>?

    init() {
        loadConfiguration()
        reconcileRunnerStates()
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
        currentSettings = settings
        saveConfiguration()
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
        let pidFile = pidFilePath(for: id)
        try? FileManager.default.removeItem(atPath: pidFile)

        // Remove from list
        runners.removeAll(where: { $0.id == id })
        saveConfiguration()
    }

    func startRunner(_ id: UUID) async throws {
        guard let index = runners.firstIndex(where: { $0.id == id }) else {
            throw RunnerError.notFound
        }

        // Check if already running via in-memory process or PID file
        if runnerProcesses[id] != nil || isRunnerProcessAlive(id) {
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
        let pidFile = pidFilePath(for: id)

        switch isolation {
        case .none:
            FileManager.default.createFile(atPath: logFile, contents: nil)
            guard let logHandle = FileHandle(forWritingAtPath: logFile) else {
                throw RunnerError.startFailed
            }
            logHandle.seekToEndOfFile()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "\(runnerDir)/run.sh")
            process.currentDirectoryURL = URL(fileURLWithPath: runnerDir)
            process.standardOutput = logHandle
            process.standardError = logHandle

            try process.run()
            let pid = process.processIdentifier
            try String(pid).write(toFile: pidFile, atomically: true, encoding: .utf8)

        case .dedicatedUser(let username):
            // Create log file as service user
            try RunnerDirectory.createDirectoryWithSudo(
                at: URL(fileURLWithPath: logFile).deletingLastPathComponent().path,
                owner: username
            )

            let process = try isolationService.launchAsUser(
                username: username,
                executable: "\(runnerDir)/run.sh",
                currentDirectory: runnerDir,
                standardOutput: FileHandle.nullDevice,
                standardError: FileHandle.nullDevice
            )
            let pid = process.processIdentifier
            // PID file stays in main user's space
            let pidDir = URL(fileURLWithPath: pidFile).deletingLastPathComponent().path
            try FileManager.default.createDirectory(
                atPath: pidDir,
                withIntermediateDirectories: true
            )
            try String(pid).write(toFile: pidFile, atomically: true, encoding: .utf8)
        }

        runners[index].status = .running
        saveConfiguration()
    }

    func stopRunner(_ id: UUID) async throws {
        guard let index = runners.firstIndex(where: { $0.id == id }) else {
            throw RunnerError.notFound
        }

        let isolation = currentSettings.isolationMode

        // Try in-memory process first (GUI path)
        if let process = runnerProcesses[id] {
            process.terminate()
            process.waitUntilExit()
            runnerProcesses.removeValue(forKey: id)
        } else if let pid = readPID(for: id) {
            switch isolation {
            case .none:
                ProcessTreeUtility.killProcessTree(pid)
            case .dedicatedUser(let username):
                isolationService.killProcessTree(pid: pid, username: username)
            }
        } else {
            throw RunnerError.notRunning
        }

        // Clean up PID file
        let pidFile = pidFilePath(for: id)
        try? FileManager.default.removeItem(atPath: pidFile)

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

    // MARK: - PID Management

    /// PID files are always stored in the main user's Application Support directory
    /// to avoid cross-user permission issues when isolation is enabled.
    private func pidFilePath(for id: UUID) -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let pidsDir = appSupport
            .appendingPathComponent("MacRunner", isDirectory: true)
            .appendingPathComponent("pids", isDirectory: true)
        try? FileManager.default.createDirectory(at: pidsDir, withIntermediateDirectories: true)
        return pidsDir.appendingPathComponent("\(id.uuidString).pid").path
    }

    private func readPID(for id: UUID) -> pid_t? {
        let pidFile = pidFilePath(for: id)
        guard let contents = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }


    private func isRunnerProcessAlive(_ id: UUID) -> Bool {
        guard let pid = readPID(for: id) else { return false }
        return kill(pid, 0) == 0 // signal 0 = just check if process exists
    }

    /// On init, reconcile config status with actual process state
    private func reconcileRunnerStates() {
        var changed = false
        for i in runners.indices {
            if runners[i].status == .running && !isRunnerProcessAlive(runners[i].id) {
                runners[i].status = .stopped
                let pidFile = pidFilePath(for: runners[i].id)
                try? FileManager.default.removeItem(atPath: pidFile)
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

        let pidFile = pidFilePath(for: id)
        try? FileManager.default.removeItem(atPath: pidFile)

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
