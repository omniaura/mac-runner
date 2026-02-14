import Foundation

class ConfigService {
    private let configDirectory: URL
    private let configFile: URL

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        configDirectory = appSupport.appendingPathComponent("MacRunner", isDirectory: true)
        configFile = configDirectory.appendingPathComponent("config.json")

        // Create directory if needed
        try? FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
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
    }
}

class RunnerDirectory {
    /// Use ~/.mac-runner/runners/ instead of Application Support to avoid
    /// spaces in paths, which break GitHub Actions runner script execution.
    /// When isolation is `.dedicatedUser`, resolve under /Users/{username}/.mac-runner/runners/.
    static func path(for runnerId: UUID, isolation: IsolationMode = .none) throws -> String {
        let baseDir: URL
        switch isolation {
        case .none, .container:
            baseDir = FileManager.default.homeDirectoryForCurrentUser
        case .dedicatedUser(let username):
            baseDir = URL(fileURLWithPath: "/Users/\(username)")
        }

        let runnerDir = baseDir
            .appendingPathComponent(".mac-runner", isDirectory: true)
            .appendingPathComponent("runners", isDirectory: true)
            .appendingPathComponent(runnerId.uuidString, isDirectory: true)

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
