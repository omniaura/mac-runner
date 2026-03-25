import Foundation

enum ToolProvisioningError: LocalizedError, Equatable {
    case homebrewNotFound
    case installFailed(package: String, output: String)

    var errorDescription: String? {
        switch self {
        case .homebrewNotFound:
            return "Homebrew was not found in a standard install location."
        case .installFailed(let package, let output):
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOutput.isEmpty {
                return "Failed to install tool: \(package)"
            }
            return "Failed to install tool \(package): \(trimmedOutput)"
        }
    }
}

struct ToolProvisioningPlan: Sendable, Equatable {
    let packages: [String]
}

struct ToolProvisioningService: Sendable {
    typealias FetchRepositoryRootEntries = @Sendable (String) async throws -> Set<String>
    typealias FileExists = @Sendable (String) -> Bool
    typealias RunCommand = @Sendable (String, [String]) async throws -> UpdateInstallerCommandResult

    private let fetchRepositoryRootEntries: FetchRepositoryRootEntries
    private let fileExists: FileExists
    private let runCommand: RunCommand

    init(
        fetchRepositoryRootEntries: @escaping FetchRepositoryRootEntries = { repo in
            try await GHCLIService.shared.repositoryRootEntries(for: repo)
        },
        fileExists: @escaping FileExists = { FileManager.default.isExecutableFile(atPath: $0) },
        runCommand: @escaping RunCommand = Self.liveRunCommand
    ) {
        self.fetchRepositoryRootEntries = fetchRepositoryRootEntries
        self.fileExists = fileExists
        self.runCommand = runCommand
    }

    func ensureGitHubCLI(isolation: IsolationMode) async throws {
        guard isolation != .container else { return }
        try await ensureInstalled(packages: ["gh"])
    }

    func provisionTools(
        for repo: String,
        settings: ToolProvisioningSettings,
        isolation: IsolationMode
    ) async throws {
        guard isolation != .container else { return }

        let rootEntries = try await fetchRepositoryRootEntries(repo)
        let plan = Self.plan(rootEntries: rootEntries, settings: settings)

        try await ensureInstalled(packages: plan.packages)
    }

    private func ensureInstalled(packages: [String]) async throws {
        guard !packages.isEmpty else { return }

        guard let brewExecutable = UpdateInstaller.brewExecutablePath(fileExists: fileExists) else {
            throw ToolProvisioningError.homebrewNotFound
        }

        for package in packages {
            guard !(try await isInstalled(package: package)) else { continue }

            let result = try await runCommand(brewExecutable, ["install", package])
            guard result.terminationStatus == 0 else {
                throw ToolProvisioningError.installFailed(package: package, output: result.output)
            }
        }
    }

    static func plan(rootEntries: Set<String>, settings: ToolProvisioningSettings) -> ToolProvisioningPlan {
        let lowercasedEntries = Set(rootEntries.map { $0.lowercased() })
        var packages = Set(["gh"])

        for detector in ToolDetector.allCases where detector.matches(rootEntries: lowercasedEntries) {
            packages.insert(detector.packageName)
        }

        for package in settings.extraPackages {
            packages.insert(package)
        }

        return ToolProvisioningPlan(packages: packages.sorted())
    }

    private func isInstalled(package: String) async throws -> Bool {
        for candidate in Self.executableCandidates(for: package) where fileExists(candidate) {
            return true
        }

        let result = try await runCommand("/bin/bash", ["-lc", "command -v \(package)"])
        return result.terminationStatus == 0 && !result.output.isEmpty
    }

    private static func executableCandidates(for package: String) -> [String] {
        switch package {
        case "gh":
            return ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
        case "node":
            return ["/opt/homebrew/bin/node", "/usr/local/bin/node"]
        case "python":
            return ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        case "go":
            return ["/opt/homebrew/bin/go", "/usr/local/bin/go"]
        case "ruby":
            return ["/opt/homebrew/bin/ruby", "/usr/local/bin/ruby", "/usr/bin/ruby"]
        case "rust":
            return ["/opt/homebrew/bin/rustc", "/usr/local/bin/rustc"]
        default:
            return []
        }
    }

    private static func liveRunCommand(executable: String, arguments: [String]) async throws -> UpdateInstallerCommandResult {
        try await Task.detached(priority: .userInitiated) {
            let result = try ProcessExecutor.run(executable, arguments: arguments)
            return UpdateInstallerCommandResult(
                terminationStatus: result.terminationStatus,
                output: result.output
            )
        }.value
    }
}

private enum ToolDetector: CaseIterable {
    case node
    case python
    case go
    case ruby
    case rust

    var packageName: String {
        switch self {
        case .node:
            return "node"
        case .python:
            return "python"
        case .go:
            return "go"
        case .ruby:
            return "ruby"
        case .rust:
            return "rust"
        }
    }

    func matches(rootEntries: Set<String>) -> Bool {
        switch self {
        case .node:
            return !rootEntries.isDisjoint(with: ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb", ".nvmrc"])
        case .python:
            return !rootEntries.isDisjoint(with: ["requirements.txt", "pyproject.toml", "pipfile", "poetry.lock", "uv.lock", ".python-version"])
        case .go:
            return rootEntries.contains("go.mod")
        case .ruby:
            return !rootEntries.isDisjoint(with: ["gemfile", ".ruby-version"])
        case .rust:
            return rootEntries.contains("cargo.toml")
        }
    }
}
