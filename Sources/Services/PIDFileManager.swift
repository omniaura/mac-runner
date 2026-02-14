import Foundation

/// Manages PID files for tracking runner processes
///
/// PID files are always stored in the main user's Application Support directory
/// to avoid cross-user permission issues when isolation is enabled.
class PIDFileManager {
    enum PIDError: LocalizedError {
        case directoryCreationFailed(String)

        var errorDescription: String? {
            switch self {
            case .directoryCreationFailed(let msg):
                return "Failed to create PID directory: \(msg)"
            }
        }
    }

    /// Returns the path to the PID file for a given runner ID
    /// - Parameter id: The runner UUID
    /// - Returns: Absolute path to the PID file
    /// - Throws: PIDError if the directory cannot be created
    func pidFilePath(for id: UUID) throws -> String {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw PIDError.directoryCreationFailed("Could not locate Application Support directory")
        }

        let pidsDir = appSupport
            .appendingPathComponent("MacRunner", isDirectory: true)
            .appendingPathComponent("pids", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: pidsDir,
                withIntermediateDirectories: true
            )
        } catch {
            throw PIDError.directoryCreationFailed(error.localizedDescription)
        }

        return pidsDir.appendingPathComponent("\(id.uuidString).pid").path
    }

    /// Writes a PID to file for a runner
    /// - Parameters:
    ///   - pid: Process ID to write
    ///   - id: Runner UUID
    /// - Throws: Error if file write fails
    func writePID(_ pid: pid_t, for id: UUID) throws {
        let pidFile = try pidFilePath(for: id)
        try String(pid).write(toFile: pidFile, atomically: true, encoding: .utf8)
    }

    /// Reads a PID from file for a runner
    /// - Parameter id: Runner UUID
    /// - Returns: The PID if file exists and is valid, nil otherwise
    func readPID(for id: UUID) -> pid_t? {
        guard let pidFile = try? pidFilePath(for: id),
              let contents = try? String(contentsOfFile: pidFile, encoding: .utf8),
              let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    /// Removes the PID file for a runner
    /// - Parameter id: Runner UUID
    func removePID(for id: UUID) {
        guard let pidFile = try? pidFilePath(for: id) else { return }
        try? FileManager.default.removeItem(atPath: pidFile)
    }

    /// Checks if a process is still alive
    /// - Parameter pid: Process ID to check
    /// - Returns: true if process exists, false otherwise
    func isProcessAlive(_ pid: pid_t) -> Bool {
        return kill(pid, 0) == 0 // signal 0 = just check if process exists
    }

    /// Checks if a runner process is alive by reading its PID file
    /// - Parameter id: Runner UUID
    /// - Returns: true if process exists and is alive, false otherwise
    func isRunnerProcessAlive(_ id: UUID) -> Bool {
        guard let pid = readPID(for: id) else { return false }
        return isProcessAlive(pid)
    }
}
