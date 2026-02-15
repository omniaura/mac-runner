import Foundation

/// Utilities for process management and process tree operations
enum ProcessUtils {
    /// Recursively finds all descendant PIDs of a given process.
    ///
    /// GitHub Actions runners spawn a process tree:
    /// run.sh → run-helper.sh → Runner.Listener
    ///
    /// This function walks the full tree using pgrep to find all descendants.
    ///
    /// - Parameter pid: The parent process ID
    /// - Returns: Array of all descendant PIDs (children, grandchildren, etc.)
    static func findDescendants(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let children = output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }

        // Recurse into each child
        return children + children.flatMap { findDescendants(of: $0) }
    }

    /// Kills an entire process tree (process + all descendants).
    ///
    /// Kills processes in reverse order (deepest children first) to ensure
    /// clean termination without orphaned processes.
    ///
    /// - Parameters:
    ///   - pid: The root process ID to kill
    ///   - useSudo: If true, uses sudo to kill processes (required for killing processes owned by other users)
    static func killProcessTree(_ pid: pid_t, useSudo: Bool = false) {
        let allPids = findDescendants(of: pid) + [pid]

        // Kill deepest children first
        for p in allPids.reversed() {
            if useSudo {
                let killProc = Process()
                killProc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                killProc.arguments = ["-n", "kill", "-TERM", String(p)]
                killProc.standardOutput = FileHandle.nullDevice
                killProc.standardError = FileHandle.nullDevice
                do {
                    try killProc.run()
                } catch {
                    // Log failure but continue with remaining processes
                    print("Warning: Failed to kill process \(p): \(error)")
                }
                killProc.waitUntilExit()
            } else {
                kill(p, SIGTERM)
            }
        }
    }
}
