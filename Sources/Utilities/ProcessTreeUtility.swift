import Foundation

/// Utility for managing process trees on macOS.
///
/// Provides functions to recursively find descendant processes and terminate
/// entire process trees. Supports both direct kill (for current user) and
/// sudo-based kill (for processes owned by other users).
enum ProcessTreeUtility {
    /// Recursively find all descendant PIDs of a given process.
    ///
    /// Uses `pgrep -P` to find direct children, then recursively traverses
    /// the entire tree. This is necessary because GitHub Actions runners
    /// spawn nested processes (run.sh → run-helper.sh → Runner.Listener).
    ///
    /// - Parameter pid: The parent process ID to search from
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

        // Recurse into each child to find the full tree
        return children + children.flatMap { findDescendants(of: $0) }
    }

    /// Kill an entire process tree using direct kill (for current user's processes).
    ///
    /// Finds all descendants and kills them in reverse order (deepest first)
    /// to ensure clean termination. Uses SIGTERM for graceful shutdown.
    ///
    /// - Parameter pid: The root process ID to kill
    static func killProcessTree(_ pid: pid_t) {
        let allPids = findDescendants(of: pid) + [pid]
        // Kill deepest children first to avoid orphaned processes
        for p in allPids.reversed() {
            kill(p, SIGTERM)
        }
    }

    /// Kill an entire process tree using sudo (for processes owned by other users).
    ///
    /// Similar to `killProcessTree(_:)` but uses `sudo kill` to terminate
    /// processes owned by a different user (e.g., service user in dedicated
    /// user isolation mode).
    ///
    /// - Parameters:
    ///   - pid: The root process ID to kill
    ///   - username: The username that owns the processes (unused but kept for API clarity)
    static func killProcessTreeWithSudo(_ pid: pid_t, username: String? = nil) {
        let descendants = findDescendants(of: pid) + [pid]
        // Kill in reverse order (deepest first)
        for p in descendants.reversed() {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            kill.arguments = ["-n", "kill", "-TERM", String(p)]
            kill.standardOutput = FileHandle.nullDevice
            kill.standardError = FileHandle.nullDevice
            try? kill.run()
            kill.waitUntilExit()
        }
    }
}
