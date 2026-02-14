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
    /// - Returns: The launched Process object
    /// - Throws: Error if process launch or PID write fails
    func startProcess(
        for id: UUID,
        executable: String,
        workingDirectory: String,
        logFile: String,
        isolation: IsolationMode
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

            try proc.run()
            process = proc

        case .dedicatedUser(let username):
            // Create log file directory as service user
            try RunnerDirectory.createDirectoryWithSudo(
                at: URL(fileURLWithPath: logFile).deletingLastPathComponent().path,
                owner: username
            )

            // Launch process as dedicated user
            let proc = try isolationService.launchAsUser(
                username: username,
                executable: executable,
                currentDirectory: workingDirectory,
                standardOutput: FileHandle.nullDevice,
                standardError: FileHandle.nullDevice
            )
            process = proc
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
        // Try in-memory process first (GUI path)
        if let process = inMemoryProcess {
            process.terminate()
            process.waitUntilExit()
        } else if let pid = pidManager.readPID(for: id) {
            // Kill process tree based on isolation mode
            switch isolation {
            case .none, .container:
                ProcessUtils.killProcessTree(pid, useSudo: false)
            case .dedicatedUser:
                ProcessUtils.killProcessTree(pid, useSudo: true)
            }
        } else {
            throw RunnerError.notRunning
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
