import Foundation

class ConfigService {
    private let configDirectory: URL
    private let configFile: URL
    private let invokingUser: String?

    init() {
        let environment = ProcessInfo.processInfo.environment
        invokingUser = Self.invokingUser(effectiveUserID: geteuid(), environment: environment)

        let appSupport = Self.applicationSupportDirectory(
            effectiveUserID: geteuid(),
            environment: environment,
            fallback: FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
        )

        configDirectory = appSupport.appendingPathComponent("MacRunner", isDirectory: true)
        configFile = configDirectory.appendingPathComponent("config.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try? restoreOwnershipIfNeeded()
    }

    func loadConfig() throws -> RunnerConfig {
        guard FileManager.default.fileExists(atPath: configFile.path) else {
            return .default
        }

        let data = try Data(contentsOf: configFile)
        return try JSONDecoder().decode(RunnerConfig.self, from: data)
    }

    func saveConfig(_ config: RunnerConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configFile, options: .atomic)
        try restoreOwnershipIfNeeded()
    }

    static func invokingUser(effectiveUserID: uid_t, environment: [String: String]) -> String? {
        guard effectiveUserID == 0 else { return nil }
        return environment["SUDO_USER"]
    }

    static func applicationSupportDirectory(
        effectiveUserID: uid_t,
        environment: [String: String],
        fallback: URL
    ) -> URL {
        guard let sudoUser = invokingUser(effectiveUserID: effectiveUserID, environment: environment) else {
            return fallback
        }

        return URL(fileURLWithPath: "/Users/\(sudoUser)/Library/Application Support")
    }

    private func restoreOwnershipIfNeeded() throws {
        guard let invokingUser else { return }

        let chown = Process()
        chown.executableURL = URL(fileURLWithPath: "/usr/sbin/chown")
        chown.arguments = ["-R", "\(invokingUser):staff", configDirectory.path]

        let pipe = Pipe()
        chown.standardOutput = pipe
        chown.standardError = pipe
        try chown.run()
        chown.waitUntilExit()

        guard chown.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: output])
        }
    }
}

class RunnerDirectory {
    /// Home directory that backs runner storage for a given isolation mode.
    ///
    /// `currentHome` is injectable so teardown code can be tested against a temporary
    /// directory instead of the real home.
    static func homeDirectory(
        isolation: IsolationMode,
        currentHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        switch isolation {
        case .none, .container:
            return currentHome
        case .dedicatedUser(let username):
            return URL(fileURLWithPath: "/Users/\(username)")
        }
    }

    /// Directory holding every runner workspace for a given isolation mode.
    ///
    /// This is the parent of the per-runner UUID directories, i.e. `~/.mac-runner/runners`.
    static func baseDirectory(
        isolation: IsolationMode = .none,
        currentHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory(isolation: isolation, currentHome: currentHome)
            .appendingPathComponent(".mac-runner", isDirectory: true)
            .appendingPathComponent("runners", isDirectory: true)
    }

    /// Resolve a runner's workspace path *without* creating it.
    ///
    /// `path(for:isolation:)` creates the directory as a side effect, which makes it
    /// unsuitable for teardown paths that only need to know where a runner lives.
    static func directoryURL(
        for runnerId: UUID,
        isolation: IsolationMode = .none,
        currentHome: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        baseDirectory(isolation: isolation, currentHome: currentHome)
            .appendingPathComponent(runnerId.uuidString, isDirectory: true)
    }

    /// Use ~/.mac-runner/runners/ instead of Application Support to avoid
    /// spaces in paths, which break GitHub Actions runner script execution.
    /// When isolation is `.dedicatedUser`, resolve under /Users/{username}/.mac-runner/runners/.
    static func path(for runnerId: UUID, isolation: IsolationMode = .none) throws -> String {
        let runnerDir = directoryURL(for: runnerId, isolation: isolation)

        switch isolation {
        case .none, .container:
            try FileManager.default.createDirectory(
                at: runnerDir,
                withIntermediateDirectories: true
            )
        case .dedicatedUser(let username):
            try Self.createDirectoryWithSudo(at: runnerDir.path, owner: username)
        }

        return runnerDir.path
    }

    /// Delete a runner's workspace directory.
    ///
    /// Workspaces owned by a dedicated service user are not writable by the invoking
    /// user, so those are removed via the same passwordless sudo entry used to create them.
    static func remove(for runnerId: UUID, isolation: IsolationMode = .none) throws {
        let directory = directoryURL(for: runnerId, isolation: isolation)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }

        switch isolation {
        case .none, .container:
            try FileManager.default.removeItem(at: directory)
        case .dedicatedUser:
            try removeDirectoryWithSudo(at: directory.path)
        }
    }

    /// Remove a directory owned by the service user via sudo.
    static func removeDirectoryWithSudo(at path: String) throws {
        // Guard against ever handing `rm -rf` a path outside Mac Runner storage.
        guard path.contains("/.mac-runner") else {
            throw RunnerDirectoryError.refusedUnsafeRemoval(path)
        }

        let remove = Process()
        remove.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        remove.arguments = ["-n", "rm", "-rf", path]
        remove.standardOutput = FileHandle.nullDevice
        remove.standardError = FileHandle.nullDevice
        try remove.run()
        remove.waitUntilExit()

        guard remove.terminationStatus == 0 else {
            throw RunnerDirectoryError.sudoRemovalFailed(path)
        }
    }

    /// Create a directory owned by the service user via sudo.
    static func createDirectoryWithSudo(at path: String, owner: String) throws {
        // mkdir -p
        let mkdir = Process()
        mkdir.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        mkdir.arguments = ["-n", "mkdir", "-p", path]
        mkdir.standardOutput = FileHandle.nullDevice
        mkdir.standardError = FileHandle.nullDevice
        try mkdir.run()
        mkdir.waitUntilExit()

        // chown -R
        let chown = Process()
        chown.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        chown.arguments = ["-n", "chown", "-R", "\(owner):staff", path]
        chown.standardOutput = FileHandle.nullDevice
        chown.standardError = FileHandle.nullDevice
        try chown.run()
        chown.waitUntilExit()
    }
}

enum RunnerDirectoryError: LocalizedError {
    case refusedUnsafeRemoval(String)
    case sudoRemovalFailed(String)

    var errorDescription: String? {
        switch self {
        case .refusedUnsafeRemoval(let path):
            return "Refusing to remove '\(path)': not a Mac Runner workspace directory."
        case .sudoRemovalFailed(let path):
            return "Failed to remove '\(path)'. Run 'mac-runner setup' to restore sudo access, or delete it manually."
        }
    }
}
