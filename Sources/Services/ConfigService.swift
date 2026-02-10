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
    static func path(for runnerId: UUID) throws -> String {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let runnerDir = appSupport
            .appendingPathComponent("MacRunner", isDirectory: true)
            .appendingPathComponent("runners", isDirectory: true)
            .appendingPathComponent(runnerId.uuidString, isDirectory: true)

        try FileManager.default.createDirectory(
            at: runnerDir,
            withIntermediateDirectories: true
        )

        return runnerDir.path
    }
}
