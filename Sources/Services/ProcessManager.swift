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
    /// - Returns: The launched Process object
    /// - Throws: Error if process launch or PID write fails
    func startProcess(
        for id: UUID,
        executable: String,
        workingDirectory: String,
        logFile: String,
        isolation: IsolationMode,
        enableGUI: Bool = false
    ) throws -> Process {
        let process: Process

        switch isolation {
        case .none, .container:
            // Create log file and open handle
            FileManager.default.createFile(atPath: logFile, contents: nil)
            guard let logHandle = FileHandle(forWritingAtPath: logFile) else {
                throw RunnerError.startFailed
            }
            logHandle.seekToEndOfFile()

            // Launch process directly
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: executable)
            proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            proc.standardOutput = logHandle
            proc.standardError = logHandle

            // Configure environment for headless mode (remove GUI access)
            if !enableGUI {
                var env = ProcessInfo.processInfo.environment
                // Remove GUI-related environment variables
                env.removeValue(forKey: "DISPLAY")
                env.removeValue(forKey: "WAYLAND_DISPLAY")
                env.removeValue(forKey: "XDG_SESSION_TYPE")
                env.removeValue(forKey: "XDG_RUNTIME_DIR")
                // Explicitly mark as headless
                env["CI"] = "true"
                env["HEADLESS"] = "true"
                proc.environment = env
            }

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

            // Create log file and set ownership
            FileManager.default.createFile(atPath: logFile, contents: nil)

            // Set ownership via sudo chown
            let chown = Process()
            chown.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            chown.arguments = ["-n", "chown", "\(username):staff", logFile]
            chown.standardOutput = FileHandle.nullDevice
            chown.standardError = FileHandle.nullDevice
            try chown.run()
            chown.waitUntilExit()

            // Open log file for writing
            guard let logHandle = FileHandle(forWritingAtPath: logFile) else {
                throw RunnerError.startFailed
            }
            logHandle.seekToEndOfFile()

            // Launch process as dedicated user with logging enabled
            let proc: Process
            do {
                proc = try isolationService.launchAsUser(
                    username: username,
                    executable: executable,
                    currentDirectory: workingDirectory,
                    standardOutput: logHandle,
                    standardError: logHandle,
                    enableGUI: enableGUI
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
        let useSudo: Bool
        switch isolation {
        case .none, .container:
            useSudo = false
        case .dedicatedUser:
            useSudo = true
        }
        ProcessUtils.killProcessTree(actualPid, useSudo: useSudo)

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
