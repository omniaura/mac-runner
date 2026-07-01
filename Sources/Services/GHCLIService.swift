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

struct GitHubAuthState: Sendable, Equatable {
    let isAuthenticated: Bool
    let statusMessage: String
    let recoveryMessage: String

    static func fromProcessResult(exitCode: Int32, stdout: String, stderr: String) -> GitHubAuthState {
        let detail = stderr.isEmpty ? stdout : stderr
        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)

        if exitCode == 0 {
            return GitHubAuthState(
                isAuthenticated: true,
                statusMessage: trimmedDetail.isEmpty ? "Authenticated with GitHub CLI." : trimmedDetail,
                recoveryMessage: ""
            )
        }

        let recoveryPrefix = "GitHub authentication expired or is invalid. Run: gh auth login"
        let recoveryMessage = trimmedDetail.isEmpty
            ? recoveryPrefix
            : "\(recoveryPrefix)\n\(trimmedDetail)"

        return GitHubAuthState(
            isAuthenticated: false,
            statusMessage: trimmedDetail.isEmpty ? "gh CLI not found or not authenticated" : trimmedDetail,
            recoveryMessage: recoveryMessage
        )
    }
}

struct GitHubAuthRecovery: Sendable, Equatable {
    static let adminOrgScope = "admin:org"
    static let adminOrgRefreshCommand = "gh auth refresh -h github.com -s admin:org"
}

final class GHCLIService: Sendable {
    static let shared = GHCLIService()

    private let ghPath: String

    init(
        ghPath: String? = nil,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.ghPath = ghPath ?? Self.detectExecutablePath(fileExists: fileExists)
    }

    static func detectExecutablePath(
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh"
        ]

        return candidates.first(where: fileExists) ?? "/opt/homebrew/bin/gh"
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

    func validateAuth() async -> GitHubAuthState {
        guard let result = try? await runGH(["auth", "status"]) else {
            return GitHubAuthState(
                isAuthenticated: false,
                statusMessage: "gh CLI not found or not authenticated",
                recoveryMessage: "GitHub authentication expired or is invalid. Run: gh auth login"
            )
        }

        return GitHubAuthState.fromProcessResult(
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    func checkAuth() async -> Bool {
        await validateAuth().isAuthenticated
    }

    func openLogin() async throws {
        let result = try await runGH(["auth", "login", "--web"])
        guard result.exitCode == 0 else {
            throw GHError.authFailed(result.stderr)
        }
    }

    func openAdminOrgReauth() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = [
            "auth", "refresh",
            "-h", "github.com",
            "-s", GitHubAuthRecovery.adminOrgScope,
            "--clipboard"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func authStatus() async -> String {
        let state = await validateAuth()
        return state.isAuthenticated ? state.statusMessage : state.recoveryMessage
    }

    // MARK: - Repos

    func listRepos(owner: String? = nil) async throws -> [String] {
        var args = ["repo", "list"]
        if let owner {
            args.append(owner)
        }
        args += ["--json", "nameWithOwner", "--limit", "100"]

        let result = try await runGH(args)
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

    func listOrgs() async throws -> [String] {
        let result = try await runGH(["api", "/user/orgs", "--jq", ".[].login"])
        guard result.exitCode == 0 else {
            throw GHError.apiFailed("Failed to list orgs: \(result.stderr)")
        }
        guard !result.stdout.isEmpty else { return [] }
        return result.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    func listAllRepos() async throws -> (personal: [String], orgRepos: [(org: String, repos: [String])]) {
        async let personalRepos = listRepos()
        async let orgs = listOrgs()

        let fetchedOrgs = try await orgs
        let fetchedPersonal = try await personalRepos

        let orgResults = try await withThrowingTaskGroup(of: (String, [String]).self) { group in
            for org in fetchedOrgs {
                group.addTask {
                    let repos = try await self.listRepos(owner: org)
                    return (org, repos)
                }
            }
            var results: [(String, [String])] = []
            for try await result in group {
                results.append(result)
            }
            return results.sorted { $0.0.lowercased() < $1.0.lowercased() }
        }

        return (personal: fetchedPersonal, orgRepos: orgResults)
    }

    func validateRepo(_ repo: String) async throws -> Bool {
        let result = try await runGH(["api", "repos/\(repo)"])
        return result.exitCode == 0
    }

    /// Verify that the authenticated `gh` user can access the given runner target.
    ///
    /// For repository targets this falls through to `validateRepo`. For
    /// organization targets we probe `orgs/{org}` — this requires the user
    /// to be a member of the org, but does NOT verify admin access. The
    /// registration-token POST below will fail loudly if the user lacks
    /// the org admin permission needed to register runners.
    func validateTarget(_ target: RunnerTarget) async throws -> Bool {
        switch target.scope {
        case .repo:
            return try await validateRepo(target.identifier)
        case .org:
            let result = try await runGH(["api", "orgs/\(target.identifier)"])
            return result.exitCode == 0
        }
    }

    func repositoryRootEntries(for repo: String) async throws -> Set<String> {
        let result = try await runGH([
            "api", "repos/\(repo)/contents",
            "--jq", ".[].name"
        ])
        guard result.exitCode == 0 else {
            throw GHError.apiFailed("Failed to inspect repository contents: \(result.stderr)")
        }

        let entries = result.stdout
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Set(entries)
    }

    func currentJob(for repo: String, runnerName: String) async throws -> WorkflowJobSummary? {
        let runs = try await listWorkflowRuns(for: repo, status: "in_progress")

        for run in runs {
            let jobs = try await listJobs(for: repo, runID: run.id, run: run)
            if let job = jobs.first(where: {
                $0.runnerName == runnerName && $0.status != "completed"
            }) {
                return job
            }
        }

        return nil
    }

    func completedJob(for repo: String, runnerName: String, runID: Int) async throws -> WorkflowJobSummary? {
        let runs = try await listWorkflowRuns(for: repo, status: "completed")

        guard let run = runs.first(where: { $0.id == runID }) else {
            return nil
        }

        let jobs = try await listJobs(for: repo, runID: run.id, run: run)
        return jobs.first(where: {
            $0.runnerName == runnerName && $0.status == "completed"
        })
    }

    // MARK: - Runners

    func getRegistrationToken(for repo: String) async throws -> String {
        try await getRegistrationToken(for: RunnerTarget(scope: .repo, identifier: repo))
    }

    func getRegistrationToken(for target: RunnerTarget) async throws -> String {
        let result = try await runGH([
            "api", "-X", "POST",
            "\(target.apiPath)/actions/runners/registration-token",
            "--jq", ".token"
        ])
        guard result.exitCode == 0, !result.stdout.isEmpty else {
            let detail = Self.registrationTokenFailureMessage(from: result.stderr)
            throw GHError.apiFailed("Failed to get registration token: \(detail)")
        }
        return result.stdout
    }

    static func registrationTokenFailureMessage(from stderr: String) -> String {
        guard requiresAdminOrgScope(stderr) else {
            return stderr
        }

        return """
        \(stderr)

        To request the missing scope, run:
        \(GitHubAuthRecovery.adminOrgRefreshCommand)
        """
    }

    static func requiresAdminOrgScope(_ message: String) -> Bool {
        let lowercased = message.lowercased()
        return lowercased.contains(GitHubAuthRecovery.adminOrgScope)
            || lowercased.contains("runners and runner groups")
    }

    func listRemoteRunners(for repo: String) async throws -> [RemoteRunner] {
        try await listRemoteRunners(for: RunnerTarget(scope: .repo, identifier: repo))
    }

    func listRemoteRunners(for target: RunnerTarget) async throws -> [RemoteRunner] {
        let result = try await runGH([
            "api", "\(target.apiPath)/actions/runners",
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
        try await deleteRunner(
            target: RunnerTarget(scope: .repo, identifier: repo),
            githubRunnerId: githubRunnerId
        )
    }

    func deleteRunner(target: RunnerTarget, githubRunnerId: Int) async throws {
        let result = try await runGH([
            "api", "-X", "DELETE",
            "\(target.apiPath)/actions/runners/\(githubRunnerId)"
        ])
        guard result.exitCode == 0 else {
            throw GHError.apiFailed("Failed to delete runner: \(result.stderr)")
        }
    }

    private func listWorkflowRuns(for repo: String, status: String) async throws -> [WorkflowRunSummary] {
        let result = try await runGH([
            "api", "repos/\(repo)/actions/runs?status=\(status)&per_page=10",
            "--jq", ".workflow_runs"
        ])
        guard result.exitCode == 0 else {
            throw GHError.apiFailed("Failed to list workflow runs: \(result.stderr)")
        }

        struct APIWorkflowRun: Decodable {
            let id: Int
            let name: String?
            let htmlURL: URL

            enum CodingKeys: String, CodingKey {
                case id
                case name
                case htmlURL = "html_url"
            }
        }

        let data = Data(result.stdout.utf8)
        let runs = try JSONDecoder().decode([APIWorkflowRun].self, from: data)
        return runs.map {
            WorkflowRunSummary(id: $0.id, name: $0.name ?? "GitHub Actions", htmlURL: $0.htmlURL)
        }
    }

    private func listJobs(for repo: String, runID: Int, run: WorkflowRunSummary) async throws -> [WorkflowJobSummary] {
        let result = try await runGH([
            "api", "repos/\(repo)/actions/runs/\(runID)/jobs",
            "--jq", ".jobs"
        ])
        guard result.exitCode == 0 else {
            throw GHError.apiFailed("Failed to list workflow jobs: \(result.stderr)")
        }

        struct APIJob: Decodable {
            let id: Int
            let name: String
            let status: String
            let conclusion: String?
            let runnerName: String?

            enum CodingKeys: String, CodingKey {
                case id
                case name
                case status
                case conclusion
                case runnerName = "runner_name"
            }
        }

        let data = Data(result.stdout.utf8)
        let jobs = try JSONDecoder().decode([APIJob].self, from: data)
        return jobs.map {
            WorkflowJobSummary(
                id: $0.id,
                name: $0.name,
                status: $0.status,
                conclusion: $0.conclusion,
                runnerName: $0.runnerName,
                run: run
            )
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
