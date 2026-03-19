import Foundation

struct UpdateInstallerCommand: Sendable, Equatable {
    let executable: String
    let arguments: [String]
}

struct UpdateInstallerCommandResult: Sendable, Equatable {
    let terminationStatus: Int32
    let output: String
}

enum UpdateInstallerError: LocalizedError, Equatable {
    case automaticUpdateUnavailable
    case homebrewNotFound
    case upgradeFailed(String)

    var errorDescription: String? {
        switch self {
        case .automaticUpdateUnavailable:
            return "Automatic updates are only available for Homebrew installs."
        case .homebrewNotFound:
            return "Homebrew was not found in a standard install location."
        case .upgradeFailed(let output):
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOutput.isEmpty {
                return "Homebrew failed to upgrade Mac Runner."
            }
            return "Homebrew failed to upgrade Mac Runner: \(trimmedOutput)"
        }
    }
}

struct UpdateInstaller: Sendable {
    typealias FileExists = @Sendable (String) -> Bool
    typealias RunCommand = @Sendable (String, [String]) async throws -> UpdateInstallerCommandResult

    private let fileExists: FileExists
    private let runCommand: RunCommand

    init(
        fileExists: @escaping FileExists = { FileManager.default.isExecutableFile(atPath: $0) },
        runCommand: @escaping RunCommand = UpdateInstaller.liveRunCommand
    ) {
        self.fileExists = fileExists
        self.runCommand = runCommand
    }

    func install(_ update: AvailableUpdate) async throws {
        let command = try Self.command(for: update, fileExists: fileExists)
        let result = try await runCommand(command.executable, command.arguments)

        guard result.terminationStatus == 0 else {
            throw UpdateInstallerError.upgradeFailed(result.output)
        }
    }

    static func command(
        for update: AvailableUpdate,
        fileExists: FileExists = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws -> UpdateInstallerCommand {
        let packageArguments: [String]

        switch update.installSource {
        case .homebrewFormula:
            packageArguments = ["upgrade", "mac-runner"]
        case .homebrewCask:
            packageArguments = ["upgrade", "--cask", "mac-runner"]
        case .directDownload:
            throw UpdateInstallerError.automaticUpdateUnavailable
        }

        guard let brewExecutable = brewExecutablePath(fileExists: fileExists) else {
            throw UpdateInstallerError.homebrewNotFound
        }

        return UpdateInstallerCommand(executable: brewExecutable, arguments: packageArguments)
    }

    static func brewExecutablePath(fileExists: FileExists = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]

        return candidates.first(where: fileExists)
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
