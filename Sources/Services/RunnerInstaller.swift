import Foundation

/// Handles downloading and installing GitHub Actions runner binary
class RunnerInstaller {
    nonisolated(unsafe) static let shared = RunnerInstaller()

    private let session = URLSession.shared
    private let runnerVersion = "2.311.0" // Latest as of 2024

    /// Download and extract GitHub Actions runner to specified directory
    func installRunner(to directory: String) async throws {
        // Determine architecture
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x64"
        #else
        throw InstallerError.unsupportedArchitecture
        #endif

        let downloadURL = "https://github.com/actions/runner/releases/download/v\(runnerVersion)/actions-runner-osx-\(arch)-\(runnerVersion).tar.gz"

        print("Downloading runner from: \(downloadURL)")

        // Download tar.gz
        let tarGzPath = "\(directory)/runner.tar.gz"
        try await downloadFile(from: downloadURL, to: tarGzPath)

        // Extract
        try await extractTarGz(at: tarGzPath, to: directory)

        // Clean up
        try FileManager.default.removeItem(atPath: tarGzPath)

        // Make scripts executable
        try makeExecutable("\(directory)/config.sh")
        try makeExecutable("\(directory)/run.sh")
        try makeExecutable("\(directory)/bin/Runner.Listener")

        print("Runner installed successfully to: \(directory)")
    }

    /// Configure runner with a registration token (caller obtains it via GHCLIService).
    ///
    /// Legacy `repo`-based overload preserved for callers that haven't been
    /// updated to pass an explicit `RunnerTarget`.
    func configureRunner(
        at directory: String,
        repo: String,
        registrationToken: String,
        name: String,
        labels: [String],
        isolation: IsolationMode = .none
    ) async throws {
        try await configureRunner(
            at: directory,
            target: RunnerTarget(scope: .repo, identifier: repo),
            registrationToken: registrationToken,
            name: name,
            labels: labels,
            isolation: isolation
        )
    }

    func configureRunner(
        at directory: String,
        target: RunnerTarget,
        registrationToken: String,
        name: String,
        labels: [String],
        isolation: IsolationMode = .none
    ) async throws {
        // Build config command
        var args = [
            "./config.sh",
            "--url", target.registrationURL,
            "--token", registrationToken,
            "--name", name,
            "--unattended",
            "--replace"
        ]

        if !labels.isEmpty {
            args.append("--labels")
            args.append(labels.joined(separator: ","))
        }

        let escapedDir = directory.replacingOccurrences(of: "'", with: "'\\''")
        let configCommand = "cd '\(escapedDir)' && \(args.joined(separator: " "))"

        let process: Process
        let pipe = Pipe()

        switch isolation {
        case .none, .container:
            process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", configCommand]
            process.environment = RunnerEnvironment.environment(enableGUI: false)

        case .dedicatedUser(let username):
            // Run config.sh as the service user
            process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", "-u", username, "/bin/bash", "-l", "-c", configCommand]
        }

        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallerError.configurationFailed(output)
        }

        if isolation == .none || isolation == .container {
            try RunnerEnvironment.writePathSnapshot(
                in: directory,
                environment: RunnerEnvironment.environment(enableGUI: false)
            )
        }

        print("Runner configured successfully")
    }

    /// One-click setup: Download, configure, and register runner.
    ///
    /// Legacy repo-only overload — defaults the runner target to repository scope.
    @discardableResult
    func setupRunner(
        repo: String,
        registrationToken: String,
        name: String,
        labels: [String],
        runnerId: UUID,
        isolation: IsolationMode = .none
    ) async throws -> String {
        try await setupRunner(
            target: RunnerTarget(scope: .repo, identifier: repo),
            registrationToken: registrationToken,
            name: name,
            labels: labels,
            runnerId: runnerId,
            isolation: isolation
        )
    }

    @discardableResult
    func setupRunner(
        target: RunnerTarget,
        registrationToken: String,
        name: String,
        labels: [String],
        runnerId: UUID,
        isolation: IsolationMode = .none
    ) async throws -> String {
        let directory = try RunnerDirectory.path(for: runnerId, isolation: isolation)

        // Install runner binary
        try await installRunner(to: directory)

        // When isolated, chown the extracted runner to the service user
        if case .dedicatedUser(let username) = isolation {
            try RunnerDirectory.createDirectoryWithSudo(at: directory, owner: username)
        }

        // Configure with GitHub
        try await configureRunner(
            at: directory,
            target: target,
            registrationToken: registrationToken,
            name: name,
            labels: labels,
            isolation: isolation
        )

        return directory
    }

    // MARK: - Private Helpers

    private func downloadFile(from urlString: String, to destination: String) async throws {
        guard let url = URL(string: urlString) else {
            throw InstallerError.invalidURL
        }

        let (tempURL, response) = try await session.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw InstallerError.downloadFailed
        }

        // Move to destination
        try FileManager.default.moveItem(at: tempURL, to: URL(fileURLWithPath: destination))
    }

    private func extractTarGz(at path: String, to directory: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", path, "-C", directory]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw InstallerError.extractionFailed
        }
    }

    private func makeExecutable(_ path: String) throws {
        let attributes = [FileAttributeKey.posixPermissions: 0o755]
        try FileManager.default.setAttributes(attributes, ofItemAtPath: path)
    }
}

enum InstallerError: LocalizedError {
    case unsupportedArchitecture
    case invalidURL
    case downloadFailed
    case extractionFailed
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "Unsupported architecture. Mac Runner requires arm64 or x86_64."
        case .invalidURL:
            return "Invalid download URL"
        case .downloadFailed:
            return "Failed to download runner binary"
        case .extractionFailed:
            return "Failed to extract runner archive"
        case .configurationFailed(let output):
            return "Failed to configure runner:\n\(output)"
        }
    }
}
