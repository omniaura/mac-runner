import Foundation
import Combine

@MainActor
class RunnerManager: ObservableObject {
    @Published var runners: [Runner] = []
    @Published var isLoading = false
    @Published var error: String?

    private let configService = ConfigService()
    private let ghService = GHCLIService.shared
    private var runnerProcesses: [UUID: Process] = [:]

    init() {
        loadConfiguration()
        reconcileRunnerStates()
    }

    // MARK: - Configuration

    func loadConfiguration() {
        do {
            let config = try configService.loadConfig()
            runners = config.runners
        } catch {
            self.error = "Failed to load config: \(error.localizedDescription)"
        }
    }

    func saveConfiguration() {
        do {
            let config = RunnerConfig(runners: runners, settings: .default)
            try configService.saveConfig(config)
        } catch {
            self.error = "Failed to save config: \(error.localizedDescription)"
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
            runnerId: runner.id
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
        if let dir = try? RunnerDirectory.path(for: id) {
            try? FileManager.default.removeItem(atPath: "\(dir)/runner.pid")
        }

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

        // Get runner directory
        let runnerDir = try RunnerDirectory.path(for: id)

        // Ensure runner binary is downloaded and configured
        if !FileManager.default.fileExists(atPath: "\(runnerDir)/run.sh") {
            let registrationToken = try await ghService.getRegistrationToken(for: runner.repo)
            try await RunnerInstaller.shared.setupRunner(
                repo: runner.repo,
                registrationToken: registrationToken,
                name: runner.name,
                labels: runner.labels,
                runnerId: id
            )
        }

        // Launch runner as a background process that survives the parent (CLI) exiting.
        // We redirect stdout/stderr to a log file (not a pipe) so there's no parent
        // dependency, and the child gets reparented to launchd when the parent exits.
        let logFile = "\(runnerDir)/runner.log"
        let pidFile = "\(runnerDir)/runner.pid"

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

        // Write PID file so other CLI invocations can find and stop this runner
        try String(pid).write(toFile: pidFile, atomically: true, encoding: .utf8)

        runners[index].status = .running
        saveConfiguration()
    }

    func stopRunner(_ id: UUID) async throws {
        guard let index = runners.firstIndex(where: { $0.id == id }) else {
            throw RunnerError.notFound
        }

        // Try in-memory process first (GUI path)
        if let process = runnerProcesses[id] {
            process.terminate()
            process.waitUntilExit()
            runnerProcesses.removeValue(forKey: id)
        } else if let pid = readPID(for: id) {
            // Kill the entire process group so child processes (Runner.Listener) also die.
            // The run.sh script and its children share a process group.
            killProcessTree(pid)
        } else {
            throw RunnerError.notRunning
        }

        // Clean up PID file
        if let dir = try? RunnerDirectory.path(for: id) {
            try? FileManager.default.removeItem(atPath: "\(dir)/runner.pid")
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

    // MARK: - PID Management

    private func readPID(for id: UUID) -> pid_t? {
        guard let dir = try? RunnerDirectory.path(for: id),
              let contents = try? String(contentsOfFile: "\(dir)/runner.pid", encoding: .utf8),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    /// Recursively find all descendant PIDs and kill the entire tree.
    /// The runner spawns run.sh → run-helper.sh → Runner.Listener,
    /// so we must walk the full tree, not just direct children.
    private func killProcessTree(_ pid: pid_t) {
        let allPids = findDescendants(of: pid) + [pid]
        // Kill deepest children first
        for p in allPids.reversed() {
            kill(p, SIGTERM)
        }
    }

    private func findDescendants(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let children = output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }

        // Recurse into each child
        return children + children.flatMap { findDescendants(of: $0) }
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
                // Clean up stale PID file
                if let dir = try? RunnerDirectory.path(for: runners[i].id) {
                    try? FileManager.default.removeItem(atPath: "\(dir)/runner.pid")
                }
                changed = true
            }
        }
        if changed { saveConfiguration() }
    }

    // MARK: - Private Helpers

    private func handleRunnerTermination(_ id: UUID) {
        runnerProcesses.removeValue(forKey: id)

        if let dir = try? RunnerDirectory.path(for: id) {
            try? FileManager.default.removeItem(atPath: "\(dir)/runner.pid")
        }

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
