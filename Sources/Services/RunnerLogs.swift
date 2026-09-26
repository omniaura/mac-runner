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

    /// Days of `_diag` files kept; older ones are pruned when the runner starts.
    static let diagnosticsRetentionDays = 7

    enum Source: String, CaseIterable, Identifiable, Sendable {
        /// The runner process's stdout/stderr plus Mac Runner's events.
        case output
        /// The listener's own log (`_diag/Runner_*.log`), one per runner start.
        case diagnostics
        /// The newest job's worker log (`_diag/Worker_*.log`), one per job.
        case jobDiagnostics

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .output: return "Output"
            case .diagnostics: return "Runner Diagnostics"
            case .jobDiagnostics: return "Job Diagnostics"
            }
        }

        /// `_diag` file-name prefix for diagnostics sources.
        var diagnosticsPrefix: String? {
            switch self {
            case .output: return nil
            case .diagnostics: return "Runner_"
            case .jobDiagnostics: return "Worker_"
            }
        }
    }

    static func outputLogPath(runnerDirectory: String) -> String {
        (runnerDirectory as NSString).appendingPathComponent(fileName)
    }

    /// Newest `_diag` log with `prefix`, or nil if the runner hasn't written one.
    /// The runner names them `Runner_YYYYMMDD-HHMMSS-utc.log`, so the name orders
    /// them; modification times would flip between files that are both active.
    static func latestDiagnosticsLogPath(runnerDirectory: String, prefix: String, fileManager: FileManager = .default) -> String? {
        let diag = (runnerDirectory as NSString).appendingPathComponent("_diag")
        guard let names = try? fileManager.contentsOfDirectory(atPath: diag) else { return nil }

        return names
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".log") }
            .max()
            .map { (diag as NSString).appendingPathComponent($0) }
    }

    static func path(for source: Source, runnerDirectory: String) -> String? {
        guard let prefix = source.diagnosticsPrefix else {
            return outputLogPath(runnerDirectory: runnerDirectory)
        }
        return latestDiagnosticsLogPath(runnerDirectory: runnerDirectory, prefix: prefix)
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
        tail(of: path, count: count, maxBytes: maxBytes).lines
    }

    /// The last `count` lines plus the file offset the read ended at, so a
    /// `LogFollower` can continue from exactly there without missing lines.
    static func tail(of path: String, count: Int, maxBytes: UInt64 = 4 * 1024 * 1024) -> (lines: [String], endOffset: UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return ([], 0) }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: start)
        var data = (try? handle.readToEnd()) ?? Data()

        // Only complete lines; a trailing partial line is left for the follower.
        let lastNewline = data.lastIndex(of: 0x0A)
        let completeEnd = lastNewline.map { UInt64($0 - data.startIndex + 1) + start } ?? start
        data = lastNewline.map { data[data.startIndex...$0] } ?? Data()

        var lines = splitLines(String(decoding: data, as: UTF8.self))
        if start > 0, !lines.isEmpty {
            lines.removeFirst()  // partial line where the read began
        }
        return (count > 0 ? Array(lines.suffix(count)) : [], completeEnd)
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

    /// Rotate the log if it's too big. Only called before a runner starts,
    /// when nothing is writing to it, so no output can be lost between the
    /// copy and the truncate. Dedicated-user logs live in a directory only the
    /// service user can write, so the rotation runs as that user.
    @discardableResult
    static func rotateIfNeeded(
        _ path: String,
        serviceUser: String? = nil,
        maxBytes: UInt64 = RunnerLogs.maxBytes,
        keep: Int = RunnerLogs.keptRotations
    ) -> Bool {
        guard needsRotation(path, maxBytes: maxBytes) else { return false }
        let succeeded = runShell(rotationCommand(path: path, keep: keep), as: serviceUser)
        if !succeeded {
            print("Warning: failed to rotate \(path); it will be retried the next time the runner starts.")
        }
        return succeeded
    }

    /// Shell command deleting `_diag` logs older than `days` days.
    static func diagnosticsPruneCommand(runnerDirectory: String, days: Int = RunnerLogs.diagnosticsRetentionDays) -> String {
        let diag = (runnerDirectory as NSString).appendingPathComponent("_diag")
        let quoted = "'" + diag.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "if [ -d \(quoted) ]; then find \(quoted) -maxdepth 1 -type f -name '*.log' -mtime +\(days) -delete; fi"
    }

    /// Remove old `_diag` logs; the runner writes a new one per start and per job
    /// and never deletes them.
    @discardableResult
    static func pruneDiagnostics(runnerDirectory: String, serviceUser: String? = nil, days: Int = RunnerLogs.diagnosticsRetentionDays) -> Bool {
        runShell(diagnosticsPruneCommand(runnerDirectory: runnerDirectory, days: days), as: serviceUser)
    }

    private static func runShell(_ command: String, as serviceUser: String?) -> Bool {
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
    private var offset: UInt64
    private var fileID: UInt64?
    /// Bytes after the last newline, kept raw so a UTF-8 character split
    /// across reads isn't mangled.
    private var pending = Data()
    /// An unterminated line longer than this is emitted as-is instead of buffered further.
    static let maxPendingBytes = 1024 * 1024

    /// Follow from `offset` (e.g. where `RunnerLogs.tail` stopped).
    init(path: String, offset: UInt64) {
        self.path = path
        self.offset = offset
        fileID = Self.attributes(path).fileID
    }

    convenience init(path: String, startAtEnd: Bool) {
        self.init(path: path, offset: startAtEnd ? Self.attributes(path).size : 0)
    }

    private static func attributes(_ path: String) -> (size: UInt64, fileID: UInt64?) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (
            (attributes?[.size] as? NSNumber)?.uint64Value ?? 0,
            (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    /// Complete lines written since the last call.
    func readNewLines() -> [String] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let (size, currentID) = Self.attributes(path)

        if size < offset || (fileID != nil && currentID != fileID) {
            offset = 0
            pending = Data()
        }
        fileID = currentID
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }

        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset += UInt64(data.count)
        pending.append(data)

        // Newlines are single bytes in UTF-8, so splitting there never cuts a character.
        guard let lastNewline = pending.lastIndex(of: 0x0A) else {
            guard pending.count > Self.maxPendingBytes else { return [] }
            let line = String(decoding: pending, as: UTF8.self)
            pending = Data()
            return [line]
        }
        let complete = pending[pending.startIndex...lastNewline]
        pending = Data(pending[pending.index(after: lastNewline)...])
        return RunnerLogs.splitLines(String(decoding: complete, as: UTF8.self))
    }
}
