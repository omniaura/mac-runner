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
    ///   - serviceUser: Dedicated isolation user that owns the tree. Its processes
    ///     are signalled as that user via the passwordless `sudo -u` shell entry;
    ///     the root `sudo` wrapper at the top of the tree exits with its child.
    static func killProcessTree(_ pid: pid_t, serviceUser: String? = nil) {
        let allPids = Array((findDescendants(of: pid) + [pid]).reversed())

        guard let serviceUser else {
            for p in allPids {
                kill(p, SIGTERM)
            }
            return
        }

        let command = killCommand(for: allPids)
        do {
            _ = try ProcessExecutor.run(
                "/usr/bin/sudo",
                arguments: UserIsolationService.sudoShellArguments(username: serviceUser, shell: "/bin/bash", command: command)
            )
        } catch {
            print("Warning: Failed to kill process tree \(pid): \(error)")
        }
    }

    /// Shell command that sends SIGTERM to each PID, continuing past ones it can't signal.
    static func killCommand(for pids: [pid_t]) -> String {
        "kill -TERM \(pids.map(String.init).joined(separator: " ")) 2>/dev/null; true"
    }
}
