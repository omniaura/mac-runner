import Foundation

enum RunnerEnvironment {
    private static let preferredPathEntries = [
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
    ]

    private static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    static func environment(
        from base: [String: String] = ProcessInfo.processInfo.environment,
        enableGUI: Bool
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = normalizedPath(base["PATH"])

        if !enableGUI {
            environment.removeValue(forKey: "DISPLAY")
            environment.removeValue(forKey: "WAYLAND_DISPLAY")
            environment.removeValue(forKey: "XDG_SESSION_TYPE")
            environment.removeValue(forKey: "XDG_RUNTIME_DIR")
            environment["CI"] = "true"
            environment["HEADLESS"] = "true"
        }

        return environment
    }

    static func normalizedPath(_ path: String?) -> String {
        let sourcePath = path.flatMap { $0.isEmpty ? nil : $0 } ?? fallbackPath
        let existingEntries = sourcePath
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)

        var seen = Set<String>()
        var entries: [String] = []

        for entry in preferredPathEntries + existingEntries where seen.insert(entry).inserted {
            entries.append(entry)
        }

        return entries.joined(separator: ":")
    }

    static func writePathSnapshot(
        in runnerDirectory: String,
        environment: [String: String] = Self.environment(enableGUI: false)
    ) throws {
        let path = normalizedPath(environment["PATH"])
        let pathFile = URL(fileURLWithPath: runnerDirectory)
            .appendingPathComponent(".path")

        try (path + "\n").write(to: pathFile, atomically: true, encoding: .utf8)
    }
}
