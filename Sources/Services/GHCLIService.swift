import Foundation

struct RemoteRunner: Sendable {
    let id: Int
    let name: String
    let status: String
    let busy: Bool
    let labels: [String]
}

struct ProcessResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

final class GHCLIService: Sendable {
    static let shared = GHCLIService()

    private let ghPath: String

    init(ghPath: String = "/opt/homebrew/bin/gh") {
        self.ghPath = ghPath
    }

    // MARK: - Private Helpers

    private func runGH(_ arguments: [String]) async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: self.ghPath)
                process.arguments = arguments

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    process.waitUntilExit()

                    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    let result = ProcessResult(
                        exitCode: process.terminationStatus,
                        stdout: String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                        stderr: String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: GHError.processLaunchFailed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Auth

    func checkAuth() async -> Bool {
        guard let result = try? await runGH(["auth", "status"]) else {
            return false
        }
        return result.exitCode == 0
    }

    func openLogin() async throws {
        let result = try await runGH(["auth", "login", "--web"])
        guard result.exitCode == 0 else {
            throw GHError.authFailed(result.stderr)
        }
    }

    func authStatus() async -> String {
        guard let result = try? await runGH(["auth", "status"]) else {
            return "gh CLI not found or not authenticated"
        }
        // gh auth status prints to stderr
        return result.exitCode == 0
            ? (result.stderr.isEmpty ? result.stdout : result.stderr)
            : "Not authenticated. Run: gh auth login"
    }

    // MARK: - Repos

    func listRepos() async throws -> [String] {
        let result = try await runGH(["repo", "list", "--json", "nameWithOwner", "--limit", "50"])
        guard result.exitCode == 0 else {
            throw GHError.apiFailed("Failed to list repos: \(result.stderr)")
        }

        struct RepoEntry: Decodable {
            let nameWithOwner: String
        }

        let data = Data(result.stdout.utf8)
        let repos = try JSONDecoder().decode([RepoEntry].self, from: data)
        return repos.map(\.nameWithOwner)
    }

    func validateRepo(_ repo: String) async throws -> Bool {
        let result = try await runGH(["api", "repos/\(repo)"])
        return result.exitCode == 0
    }

    // MARK: - Runners

    func getRegistrationToken(for repo: String) async throws -> String {
        let result = try await runGH([
            "api", "-X", "POST",
            "repos/\(repo)/actions/runners/registration-token",
            "--jq", ".token"
        ])
        guard result.exitCode == 0, !result.stdout.isEmpty else {
            throw GHError.apiFailed("Failed to get registration token: \(result.stderr)")
        }
        return result.stdout
    }

    func listRemoteRunners(for repo: String) async throws -> [RemoteRunner] {
        let result = try await runGH([
            "api", "repos/\(repo)/actions/runners",
            "--jq", ".runners"
        ])
        guard result.exitCode == 0 else {
            throw GHError.apiFailed("Failed to list runners: \(result.stderr)")
        }

        guard !result.stdout.isEmpty else {
            return []
        }

        struct RunnerLabel: Decodable {
            let name: String
        }
        struct APIRunner: Decodable {
            let id: Int
            let name: String
            let status: String
            let busy: Bool
            let labels: [RunnerLabel]
        }

        let data = Data(result.stdout.utf8)
        let apiRunners = try JSONDecoder().decode([APIRunner].self, from: data)
        return apiRunners.map { r in
            RemoteRunner(
                id: r.id,
                name: r.name,
                status: r.status,
                busy: r.busy,
                labels: r.labels.map(\.name)
            )
        }
    }

    func deleteRunner(repo: String, githubRunnerId: Int) async throws {
        let result = try await runGH([
            "api", "-X", "DELETE",
            "repos/\(repo)/actions/runners/\(githubRunnerId)"
        ])
        guard result.exitCode == 0 else {
            throw GHError.apiFailed("Failed to delete runner: \(result.stderr)")
        }
    }
}

enum GHError: LocalizedError {
    case processLaunchFailed(String)
    case authFailed(String)
    case apiFailed(String)

    var errorDescription: String? {
        switch self {
        case .processLaunchFailed(let msg):
            return "Failed to launch gh CLI: \(msg)"
        case .authFailed(let msg):
            return "GitHub authentication failed: \(msg)"
        case .apiFailed(let msg):
            return msg
        }
    }
}
