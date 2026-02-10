import Foundation
import Combine

@MainActor
class RunnerManager: ObservableObject {
    @Published var runners: [Runner] = []
    @Published var isLoading = false
    @Published var error: String?

    private let configService = ConfigService()
    private let githubService = GitHubService()
    private var runnerProcesses: [UUID: Process] = [:]

    init() {
        loadConfiguration()
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

    func addRunner(name: String, repo: String, token: String, labels: [String]) async throws {
        isLoading = true
        defer { isLoading = false }

        // Validate GitHub token and repo access
        try await githubService.validateAccess(repo: repo, token: token)

        // Create runner
        let runner = Runner(
            name: name,
            repo: repo,
            labels: labels,
            enabled: true,
            status: .stopped
        )

        // Store token securely
        try TokenStorage.shared.saveToken(token, for: runner.id)

        // Add to list
        runners.append(runner)
        saveConfiguration()

        // Start runner
        try await startRunner(runner.id)
    }

    func removeRunner(_ id: UUID) async throws {
        // Stop runner if running
        if runnerProcesses[id] != nil {
            try await stopRunner(id)
        }

        // Remove from GitHub
        if let runner = runners.first(where: { $0.id == id }) {
            if let token = try? TokenStorage.shared.getToken(for: id) {
                try await githubService.unregisterRunner(repo: runner.repo, token: token, runnerId: id)
            }
        }

        // Remove from list
        runners.removeAll(where: { $0.id == id })

        // Clean up token
        try? TokenStorage.shared.deleteToken(for: id)

        saveConfiguration()
    }

    func startRunner(_ id: UUID) async throws {
        guard let index = runners.firstIndex(where: { $0.id == id }) else {
            throw RunnerError.notFound
        }

        guard runnerProcesses[id] == nil else {
            throw RunnerError.alreadyRunning
        }

        let runner = runners[index]
        guard let token = try? TokenStorage.shared.getToken(for: id) else {
            throw RunnerError.tokenNotFound
        }

        // Get runner directory
        let runnerDir = try RunnerDirectory.path(for: id)

        // Ensure runner binary is downloaded
        if !FileManager.default.fileExists(atPath: "\(runnerDir)/run.sh") {
            try await downloadRunner(to: runnerDir)
            try await configureRunner(at: runnerDir, repo: runner.repo, token: token, labels: runner.labels)
        }

        // Start runner process
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(runnerDir)/run.sh")
        process.currentDirectoryURL = URL(fileURLWithPath: runnerDir)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.handleRunnerTermination(id)
            }
        }

        try process.run()
        runnerProcesses[id] = process

        runners[index].status = .running
        saveConfiguration()
    }

    func stopRunner(_ id: UUID) async throws {
        guard let index = runners.firstIndex(where: { $0.id == id }) else {
            throw RunnerError.notFound
        }

        guard let process = runnerProcesses[id] else {
            throw RunnerError.notRunning
        }

        // Graceful shutdown
        process.terminate()
        process.waitUntilExit()

        runnerProcesses.removeValue(forKey: id)
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

    // MARK: - Private Helpers

    private func handleRunnerTermination(_ id: UUID) {
        runnerProcesses.removeValue(forKey: id)

        if let index = runners.firstIndex(where: { $0.id == id }) {
            runners[index].status = .stopped
            saveConfiguration()
        }
    }

    private func downloadRunner(to directory: String) async throws {
        // Download GitHub Actions runner binary
        // Implementation: curl GitHub releases, extract tar.gz
        // For MVP, assume runner binary is pre-downloaded
        throw RunnerError.notImplemented
    }

    private func configureRunner(at directory: String, repo: String, token: String, labels: [String]) async throws {
        // Run ./config.sh with registration token
        // Implementation: get registration token from GitHub, run config.sh
        throw RunnerError.notImplemented
    }
}

// MARK: - Errors

enum RunnerError: LocalizedError {
    case notFound
    case alreadyRunning
    case notRunning
    case tokenNotFound
    case notImplemented

    var errorDescription: String? {
        switch self {
        case .notFound: return "Runner not found"
        case .alreadyRunning: return "Runner is already running"
        case .notRunning: return "Runner is not running"
        case .tokenNotFound: return "GitHub token not found"
        case .notImplemented: return "Feature not yet implemented"
        }
    }
}
