import Foundation

/// Manages process lifecycle for GitHub Actions runners
///
/// Handles starting and stopping runner processes with different isolation modes.
class ProcessManager {
    private let pidManager = PIDFileManager()
    private let isolationService = UserIsolationService.shared

    /// Starts a runner process and writes its PID to file
    ///
    /// - Parameters:
    ///   - id: Runner UUID
    ///   - executable: Path to the runner executable (run.sh)
    ///   - workingDirectory: Working directory for the process
    ///   - logFile: Path to log file for stdout/stderr
    ///   - isolation: Isolation mode to use
    ///   - enableGUI: Whether to enable GUI access (default: false, headless)
    ///   - openFileLimit: Maximum open file limit to apply before launch
    /// - Returns: The launched Process object
    /// - Throws: Error if process launch or PID write fails
    func startProcess(
        for id: UUID,
        executable: String,
        workingDirectory: String,
        logFile: String,
        isolation: IsolationMode,
        enableGUI: Bool = false,
        openFileLimit: Int
    ) throws -> Process {
        let process: Process

        switch isolation {
        case .none, .container:
            // Append to the existing log (earlier runs and Mac Runner's own
            // events stay visible), rotating it first if it has grown too big.
            RunnerLogs.rotateIfNeeded(logFile)
            RunnerLogs.pruneDiagnostics(runnerDirectory: workingDirectory)
            guard let logHandle = try? RunnerLogs.openForAppending(logFile) else {
                throw RunnerError.startFailed
            }

            // Launch process via bash to set resource limits
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            let escapedExec = executable.replacingOccurrences(of: "'", with: "'\\''")
            proc.arguments = ["-c", ResourceLimits.shellCommand("exec '\(escapedExec)'", openFileLimit: openFileLimit)]
            proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            proc.standardOutput = logHandle
            proc.standardError = logHandle

            let env = RunnerEnvironment.environment(enableGUI: enableGUI)
            try RunnerEnvironment.writePathSnapshot(in: workingDirectory, environment: env)
            proc.environment = env

            do {
                try proc.run()
                process = proc
            } catch {
                // Close log handle if process launch fails
                try? logHandle.close()
                throw error
            }

        case .dedicatedUser(let username):
            // Create log file directory as service user
            try RunnerDirectory.createDirectoryWithSudo(
                at: URL(fileURLWithPath: logFile).deletingLastPathComponent().path,
                owner: username
            )

            RunnerLogs.rotateIfNeeded(logFile, serviceUser: username)
            RunnerLogs.pruneDiagnostics(runnerDirectory: workingDirectory, serviceUser: username)

            // The workspace is owned by the service user, so it creates the log and
            // grants only the host user (via ACL) write access, so we can open it
            // for the runner's output and append our own events.
            try ProcessExecutor.runOrThrow(
                "/usr/bin/sudo",
                arguments: UserIsolationService.sudoShellArguments(
                    username: username,
                    shell: "/bin/bash",
                    command: Self.serviceUserLogCommand(logFile: logFile, writer: NSUserName())
                ),
                errorMessage: "Failed to create runner log"
            )

            guard let logHandle = try? RunnerLogs.openForAppending(logFile) else {
                throw RunnerError.startFailed
            }

            // Launch process as dedicated user with logging enabled
            let proc: Process
            do {
                proc = try isolationService.launchAsUser(
                    username: username,
                    executable: executable,
                    currentDirectory: workingDirectory,
                    standardOutput: logHandle,
                    standardError: logHandle,
                    enableGUI: enableGUI,
                    openFileLimit: openFileLimit
                )
                process = proc
            } catch {
                try? logHandle.close()
                throw error
            }
        }

        // Write PID file
        let pid = process.processIdentifier
        try pidManager.writePID(pid, for: id)

        return process
    }

    /// Shell command (run as the service user) that creates the runner log,
    /// readable by all but writable only by its owner and `writer`.
    static func serviceUserLogCommand(logFile: String, writer: String) -> String {
        let log = "'" + logFile.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let acl = "'" + "user:\(writer) allow write,append".replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "touch \(log) && chmod 644 \(log) && chmod -N \(log) && chmod +a \(acl) \(log)"
    }

    /// Stops a runner process by killing its entire process tree
    ///
    /// - Parameters:
    ///   - id: Runner UUID
    ///   - isolation: Isolation mode used when starting the process
    ///   - inMemoryProcess: Optional in-memory Process object (for GUI)
    /// - Throws: RunnerError.notRunning if process is not found
    func stopProcess(
        for id: UUID,
        isolation: IsolationMode,
        inMemoryProcess: Process? = nil
    ) throws {
        // Get PID from in-memory process or PID file
        let pid: pid_t?
        if let process = inMemoryProcess {
            pid = process.processIdentifier
        } else {
            pid = pidManager.readPID(for: id)
        }

        guard let actualPid = pid else {
            throw RunnerError.notRunning
        }

        // Kill process tree based on isolation mode
        switch isolation {
        case .none, .container:
            ProcessUtils.killProcessTree(actualPid)
        case .dedicatedUser(let username):
            ProcessUtils.killProcessTree(actualPid, serviceUser: username)
        }

        // Clean up PID file
        pidManager.removePID(for: id)
    }

    /// Checks if a runner process is alive
    ///
    /// - Parameter id: Runner UUID
    /// - Returns: true if process is alive, false otherwise
    func isProcessAlive(for id: UUID) -> Bool {
        return pidManager.isRunnerProcessAlive(id)
    }
}
