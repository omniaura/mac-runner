import Foundation

/// Installs GitHub Actions' post-job hook outside the runner application directory.
///
/// A self-hosted runner executes one job at a time. GitHub invokes this hook only after
/// every workflow step has completed, which lets us reclaim that job's checkout without
/// racing a currently running workflow. The hook is deliberately best-effort: cleanup
/// failures must never turn an otherwise successful workflow into a failed one.
enum PostJobWorkspaceCleanupHook {
    static let hookEnvironmentKey = "ACTIONS_RUNNER_HOOK_JOB_COMPLETED"
    static let minimumFreeSpaceEnvironmentKey = "MAC_RUNNER_POST_JOB_CLEANUP_MINIMUM_FREE_GB"

    private static let hookFileName = "post-job-workspace-cleanup.sh"

    static func synchronize(
        runnerDirectory: URL,
        isolation: IsolationMode,
        enabled: Bool,
        minimumFreeDiskSpaceGB: Int,
        fileManager: FileManager = .default
    ) throws {
        let layout = try managedLayout(for: runnerDirectory)
        let environmentFile = runnerDirectory.appendingPathComponent(".env")
        let existingEnvironment = try readText(at: environmentFile, isolation: isolation, fileManager: fileManager)

        guard enabled else {
            let updatedEnvironment = updatingEnvironment(
                existingEnvironment,
                hookPath: layout.hookFile,
                minimumFreeDiskSpaceGB: minimumFreeDiskSpaceGB,
                enabled: false
            )
            if updatedEnvironment != existingEnvironment {
                try writeText(updatedEnvironment, to: environmentFile, mode: 0o644, isolation: isolation, fileManager: fileManager)
            }
            return
        }

        try writeText(hookScript, to: layout.hookFile, mode: 0o755, isolation: isolation, fileManager: fileManager)
        let updatedEnvironment = updatingEnvironment(
            existingEnvironment,
            hookPath: layout.hookFile,
            minimumFreeDiskSpaceGB: minimumFreeDiskSpaceGB,
            enabled: true
        )
        if updatedEnvironment != existingEnvironment {
            try writeText(updatedEnvironment, to: environmentFile, mode: 0o644, isolation: isolation, fileManager: fileManager)
        }
    }

    static func updatingEnvironment(
        _ existing: String,
        hookPath: URL,
        minimumFreeDiskSpaceGB: Int,
        enabled: Bool
    ) -> String {
        let managedKeys = [hookEnvironmentKey, minimumFreeSpaceEnvironmentKey]
        var lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" {
            lines.removeLast()
        }
        lines.removeAll { line in
            managedKeys.contains { line.hasPrefix("\($0)=") }
        }

        guard enabled else {
            return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        }

        lines.append("\(hookEnvironmentKey)=\(hookPath.path)")
        lines.append("\(minimumFreeSpaceEnvironmentKey)=\(max(1, minimumFreeDiskSpaceGB))")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func managedLayout(for runnerDirectory: URL) throws -> (root: URL, hookFile: URL) {
        let runnersDirectory = runnerDirectory.deletingLastPathComponent()
        let macRunnerDirectory = runnersDirectory.deletingLastPathComponent()
        guard runnersDirectory.lastPathComponent == "runners",
              macRunnerDirectory.lastPathComponent == ".mac-runner",
              UUID(uuidString: runnerDirectory.lastPathComponent) != nil else {
            throw PostJobWorkspaceCleanupHookError.unsafeRunnerDirectory(runnerDirectory.path)
        }

        let hookDirectory = macRunnerDirectory.appendingPathComponent("hooks", isDirectory: true)
        return (macRunnerDirectory, hookDirectory.appendingPathComponent(hookFileName))
    }

    private static func readText(
        at url: URL,
        isolation: IsolationMode,
        fileManager: FileManager
    ) throws -> String {
        switch isolation {
        case .none, .container:
            guard fileManager.fileExists(atPath: url.path) else { return "" }
            return try String(contentsOf: url, encoding: .utf8)
        case .dedicatedUser(let username):
            let result = try runSudo(as: username, command: "/bin/cat", arguments: [url.path])
            // `cat` exits 1 for a missing .env; that is the same as an empty file.
            guard result.status == 0 else {
                if result.output.contains("No such file or directory") {
                    return ""
                }
                throw PostJobWorkspaceCleanupHookError.dedicatedUserReadFailed(url.path, result.output)
            }
            return result.output
        }
    }

    private static func writeText(
        _ text: String,
        to url: URL,
        mode: Int,
        isolation: IsolationMode,
        fileManager: FileManager
    ) throws {
        let parent = url.deletingLastPathComponent()
        switch isolation {
        case .none, .container:
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        case .dedicatedUser(let username):
            try RunnerDirectory.createDirectoryWithSudo(at: parent.path, owner: username)
            let temporaryFile = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? fileManager.removeItem(at: temporaryFile) }
            try text.write(to: temporaryFile, atomically: true, encoding: .utf8)
            let result = try runSudo(
                as: nil,
                command: "/usr/bin/install",
                arguments: ["-m", String(mode, radix: 8), "-o", username, "-g", "staff", temporaryFile.path, url.path]
            )
            guard result.status == 0 else {
                throw PostJobWorkspaceCleanupHookError.dedicatedUserWriteFailed(url.path, result.output)
            }
        }
    }

    private static func runSudo(
        as username: String?,
        command: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-n"] + (username.map { ["-u", $0] } ?? []) + [command] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    private static let hookScript = """
    #!/bin/bash
    # Managed by Mac Runner. This hook is intentionally best-effort: it must never fail a workflow.
    set +e

    minimum_free_gb="${MAC_RUNNER_POST_JOB_CLEANUP_MINIMUM_FREE_GB:-0}"
    case "$minimum_free_gb" in
      ''|*[!0-9]*) exit 0 ;;
    esac

    runner_workspace="${RUNNER_WORKSPACE:-}"
    github_workspace="${GITHUB_WORKSPACE:-}"
    [ -n "$runner_workspace" ] && [ -n "$github_workspace" ] || exit 0
    case "$github_workspace" in
      "$runner_workspace"/*) ;;
      *) exit 0 ;;
    esac

    available_kb="$(LC_ALL=C /bin/df -Pk "$runner_workspace" 2>/dev/null | /usr/bin/awk 'NR == 2 { print $4 }')"
    case "$available_kb" in
      ''|*[!0-9]*) exit 0 ;;
    esac
    required_kb=$((minimum_free_gb * 1024 * 1024))
    [ "$available_kb" -lt "$required_kb" ] || exit 0

    relative_path="${github_workspace#"$runner_workspace"/}"
    top_level="${relative_path%%/*}"
    [ -n "$top_level" ] && [ "$top_level" != "." ] || exit 0
    cleanup_root="$runner_workspace/$top_level"
    case "$cleanup_root" in
      "$runner_workspace"/*) ;;
      *) exit 0 ;;
    esac

    # Keep the runner's _work directory itself, but remove this completed job's checkout tree.
    [ -d "$cleanup_root" ] && [ ! -L "$cleanup_root" ] || exit 0
    /usr/bin/find "$cleanup_root" -mindepth 1 -maxdepth 1 -exec /bin/rm -rf {} + 2>/dev/null
    exit 0
    """
}

enum PostJobWorkspaceCleanupHookError: LocalizedError {
    case unsafeRunnerDirectory(String)
    case dedicatedUserReadFailed(String, String)
    case dedicatedUserWriteFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .unsafeRunnerDirectory(let path):
            return "Refusing to configure a cleanup hook outside Mac Runner storage: \(path)"
        case .dedicatedUserReadFailed(let path, let output):
            return "Failed to read cleanup hook environment at \(path): \(output)"
        case .dedicatedUserWriteFailed(let path, let output):
            return "Failed to configure cleanup hook at \(path): \(output)"
        }
    }
}
