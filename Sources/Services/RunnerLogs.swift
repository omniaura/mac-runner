import Foundation

/// Where a runner's logs live and how they're read, followed, and rotated.
///
/// `runner.log` in the runner workspace holds the runner process's output plus
/// Mac Runner's own events for every isolation mode. The GitHub runner also
/// writes detailed diagnostics to `_diag/Runner_*.log` and `_diag/Worker_*.log`.
enum RunnerLogs {
    static let fileName = "runner.log"
    /// Rotate `runner.log` once it grows past this size.
    static let maxBytes: UInt64 = 10 * 1024 * 1024
    /// Rotated copies kept alongside it (runner.log.1 ... runner.log.N).
    static let keptRotations = 3

    enum Source: String, CaseIterable, Identifiable, Sendable {
        case output
        case diagnostics

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .output: return "Runner Output"
            case .diagnostics: return "Diagnostics"
            }
        }
    }

    static func outputLogPath(runnerDirectory: String) -> String {
        (runnerDirectory as NSString).appendingPathComponent(fileName)
    }

    /// Newest `_diag` log (Runner_ or Worker_), or nil if the runner hasn't written one yet.
    static func latestDiagnosticsLogPath(runnerDirectory: String, fileManager: FileManager = .default) -> String? {
        let diag = (runnerDirectory as NSString).appendingPathComponent("_diag")
        guard let names = try? fileManager.contentsOfDirectory(atPath: diag) else { return nil }

        return names
            .filter { $0.hasSuffix(".log") }
            .map { (diag as NSString).appendingPathComponent($0) }
            .max { modificationDate($0, fileManager) < modificationDate($1, fileManager) }
    }

    static func path(for source: Source, runnerDirectory: String) -> String? {
        switch source {
        case .output: return outputLogPath(runnerDirectory: runnerDirectory)
        case .diagnostics: return latestDiagnosticsLogPath(runnerDirectory: runnerDirectory)
        }
    }

    private static func modificationDate(_ path: String, _ fileManager: FileManager) -> Date {
        ((try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date) ?? .distantPast
    }

    // MARK: - Writing

    /// Open (creating if needed) a log for appending without truncating it.
    /// O_APPEND keeps writes at the end even after the file is truncated by rotation.
    static func openForAppending(_ path: String) throws -> FileHandle {
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    // MARK: - Reading

    /// The last `count` lines of the file at `path` (reads at most `maxBytes` from the end).
    static func lastLines(of path: String, count: Int, maxBytes: UInt64 = 4 * 1024 * 1024) -> [String] {
        guard count > 0, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()

        var lines = splitLines(String(decoding: data, as: UTF8.self))
        if start > 0, !lines.isEmpty {
            lines.removeFirst()  // partial line where the read began
        }
        return Array(lines.suffix(count))
    }

    static func splitLines(_ text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" {
            lines.removeLast()
        }
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }

    /// Case-insensitive filter; an empty query keeps every line.
    static func filter(_ lines: [String], matching query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return lines }
        return lines.filter { $0.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    // MARK: - Rotation

    /// Whether the log at `path` has outgrown `maxBytes`.
    static func needsRotation(_ path: String, maxBytes: UInt64 = RunnerLogs.maxBytes) -> Bool {
        let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        return size > maxBytes
    }

    /// Shell command that copy-truncates `path` into numbered rotations,
    /// keeping `keep` of them. Copy-truncate lets a running runner keep
    /// writing to the same (O_APPEND) descriptor.
    static func rotationCommand(path: String, keep: Int = RunnerLogs.keptRotations) -> String {
        let quoted = { (value: String) in "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var steps = ["rm -f \(quoted("\(path).\(keep)"))"]
        if keep > 1 {
            for index in stride(from: keep - 1, through: 1, by: -1) {
                steps.append("if [ -f \(quoted("\(path).\(index)")) ]; then mv \(quoted("\(path).\(index)")) \(quoted("\(path).\(index + 1)")); fi")
            }
        }
        steps.append("cp -p \(quoted(path)) \(quoted("\(path).1"))")
        steps.append(": > \(quoted(path))")
        return steps.joined(separator: " && ")
    }

    /// Rotate the log if it's too big. Dedicated-user logs live in a directory
    /// only the service user can write, so the rotation runs as that user.
    @discardableResult
    static func rotateIfNeeded(
        _ path: String,
        serviceUser: String? = nil,
        maxBytes: UInt64 = RunnerLogs.maxBytes,
        keep: Int = RunnerLogs.keptRotations
    ) -> Bool {
        guard needsRotation(path, maxBytes: maxBytes) else { return false }
        let command = rotationCommand(path: path, keep: keep)

        let result: ProcessExecutor.ProcessResult?
        if let serviceUser {
            result = try? ProcessExecutor.run(
                "/usr/bin/sudo",
                arguments: UserIsolationService.sudoShellArguments(username: serviceUser, shell: "/bin/bash", command: command)
            )
        } else {
            result = try? ProcessExecutor.run("/bin/bash", arguments: ["-c", command])
        }
        return result?.succeeded ?? false
    }
}

/// Incrementally reads lines appended to a log, coping with truncation and
/// rotation (the file shrinking or being replaced).
final class LogFollower {
    let path: String
    private var offset: UInt64 = 0
    private var fileID: UInt64?
    private var pending = ""

    init(path: String, startAtEnd: Bool) {
        self.path = path
        if startAtEnd, let attributes = try? FileManager.default.attributesOfItem(atPath: path) {
            offset = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        }
    }

    /// Complete lines written since the last call.
    func readNewLines() -> [String] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return [] }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let currentID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value

        if size < offset || (fileID != nil && currentID != fileID) {
            offset = 0
            pending = ""
        }
        fileID = currentID
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)

        let text = pending + String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")
        pending = lines.removeLast()
        return lines.map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
    }
}
