import Foundation

/// Handles downloading and installing GitHub Actions runner binary
class RunnerInstaller {
    nonisolated(unsafe) static let shared = RunnerInstaller()

    /// Runner version used when the latest release can't be resolved.
    /// Must stay at or above GitHub's minimum supported runner version, or
    /// newly created runners fail to register.
    static let fallbackRunnerVersion = "2.337.0"

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/actions/runner/releases/latest")!

    private let session = URLSession.shared

    /// Resolve the runner version to install: the latest actions/runner release,
    /// or `fallbackRunnerVersion` if the lookup fails or returns something older.
    func resolveRunnerVersion() async -> String {
        var request = URLRequest(url: Self.latestReleaseURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("mac-runner", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Self.runnerVersion(fromLatestReleaseData: data, statusCode: statusCode)
        } catch {
            print("Could not resolve latest runner version (\(error.localizedDescription)); using \(Self.fallbackRunnerVersion)")
            return Self.fallbackRunnerVersion
        }
    }

    static func runnerVersion(fromLatestReleaseData data: Data, statusCode: Int) -> String {
        struct LatestRelease: Decodable {
            let tagName: String

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
            }
        }

        guard statusCode == 200,
              let release = try? JSONDecoder().decode(LatestRelease.self, from: data) else {
            return fallbackRunnerVersion
        }

        let tag = release.tagName.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag

        guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              let resolved = SemanticVersion(version),
              let fallback = SemanticVersion(fallbackRunnerVersion),
              resolved >= fallback else {
            return fallbackRunnerVersion
        }

        return version
    }

    static func downloadURL(version: String, arch: String) -> String {
        "https://github.com/actions/runner/releases/download/v\(version)/actions-runner-osx-\(arch)-\(version).tar.gz"
    }

    /// Shell command that downloads and extracts the runner, trying each URL in turn.
    ///
    /// Used for dedicated-user isolation, where the workspace is owned by the
    /// service user and only writable by it.
    static func serviceUserInstallCommand(directory: String, downloadURLs: [String]) -> String {
        func quoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        let urls = downloadURLs.map(quoted).joined(separator: " ")
        return """
        set -e; cd \(quoted(directory)); \
        for url in \(urls); do echo "Downloading runner from: $url"; \
        curl -fsSL --retry 2 -o runner.tar.gz "$url" && break; rm -f runner.tar.gz; done; \
        test -f runner.tar.gz; tar -xzf runner.tar.gz; rm -f runner.tar.gz; \
        chmod 755 config.sh run.sh bin/Runner.Listener
        """
    }

    /// Download and extract GitHub Actions runner to specified directory
    func installRunner(to directory: String, isolation: IsolationMode = .none) async throws {
        // Determine architecture
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x64"
        #else
        throw InstallerError.unsupportedArchitecture
        #endif

        let runnerVersion = await resolveRunnerVersion()

        if case .dedicatedUser(let username) = isolation {
            let versions = runnerVersion == Self.fallbackRunnerVersion
                ? [runnerVersion]
                : [runnerVersion, Self.fallbackRunnerVersion]
            let command = Self.serviceUserInstallCommand(
                directory: directory,
                downloadURLs: versions.map { Self.downloadURL(version: $0, arch: arch) }
            )
            let result = try ProcessExecutor.run(
                "/usr/bin/sudo",
                arguments: UserIsolationService.sudoShellArguments(username: username, shell: "/bin/bash", command: command)
            )
            print(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
            guard result.succeeded else {
                throw InstallerError.downloadFailed
            }
            print("Runner installed successfully to: \(directory)")
            return
        }

        let tarGzPath = "\(directory)/runner.tar.gz"

        // Download tar.gz, retrying with the pinned version if the resolved
        // release's assets aren't available yet.
        do {
            try await downloadRunner(version: runnerVersion, arch: arch, to: tarGzPath)
        } catch where runnerVersion != Self.fallbackRunnerVersion {
            try await downloadRunner(version: Self.fallbackRunnerVersion, arch: arch, to: tarGzPath)
        }

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
            process.arguments = UserIsolationService.sudoShellArguments(
                username: username,
                shell: "/bin/bash",
                command: configCommand
            )
        }

        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()
        // Read before waiting so config.sh can't block on a full pipe.
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let output = String(data: outputData, encoding: .utf8) ?? ""
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
        try await installRunner(to: directory, isolation: isolation)

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

    private func downloadRunner(version: String, arch: String, to destination: String) async throws {
        let downloadURL = Self.downloadURL(version: version, arch: arch)
        print("Downloading runner from: \(downloadURL)")
        try await downloadFile(from: downloadURL, to: destination)
    }

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
