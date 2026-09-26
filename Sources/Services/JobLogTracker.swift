import Foundation

/// Job activity the GitHub Actions runner prints to its output (runner.log):
///
///     2026-09-26 05:22:18Z: Listening for Jobs
///     2026-09-26 05:22:25Z: Running job: build
///     2026-09-26 05:22:28Z: Job build completed with result: Succeeded
///
/// Reading these catches every job, however short, as soon as it's written,
/// unlike polling GitHub for the runner's busy flag.
enum RunnerLogEvent: Equatable {
    case listening
    case jobStarted(name: String)
    case jobCompleted(name: String, conclusion: String)

    private static let prefix = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}Z: "#

    static func parse(_ line: String) -> RunnerLogEvent? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.range(of: prefix + "Listening for Jobs$", options: .regularExpression) != nil {
            return .listening
        }
        if let range = line.range(of: prefix + "Running job: ", options: .regularExpression) {
            let name = String(line[range.upperBound...])
            return name.isEmpty ? nil : .jobStarted(name: name)
        }
        if let range = line.range(of: prefix + "Job .+ completed with result: \\w+$", options: .regularExpression) {
            let body = line[range].replacingOccurrences(of: prefix + "Job ", with: "", options: .regularExpression)
            guard let split = body.range(of: " completed with result: ", options: .backwards) else { return nil }
            let name = String(body[..<split.lowerBound])
            let result = String(body[split.upperBound...])
            return .jobCompleted(name: name, conclusion: conclusion(for: result))
        }
        return nil
    }

    /// The runner's result word as a GitHub API conclusion ("success", "failure", ...).
    static func conclusion(for result: String) -> String {
        switch result.lowercased() {
        case "succeeded": return "success"
        case "failed": return "failure"
        case "canceled", "cancelled": return "cancelled"
        case "skipped": return "skipped"
        default: return result.lowercased()
        }
    }
}

/// Follows one runner's log and reports job starts and completions.
final class JobLogTracker {
    enum Change: Equatable {
        case started(name: String)
        case completed(name: String, conclusion: String)
    }

    private let follower: LogFollower
    /// The job the log says is running, if any.
    private(set) var currentJob: String?

    /// Start following at the end of the log, taking the in-progress job (if
    /// any) from its recent history so a job already running is known.
    init(path: String) {
        let tail = RunnerLogs.tail(of: path, count: 500)
        currentJob = Self.runningJob(in: tail.lines)
        follower = LogFollower(path: path, offset: tail.endOffset)
    }

    /// The job still running at the end of `lines`, if any.
    static func runningJob(in lines: [String]) -> String? {
        var job: String?
        for line in lines {
            switch RunnerLogEvent.parse(line) {
            case .jobStarted(let name)?: job = name
            case .jobCompleted?, .listening?: job = nil
            case nil: continue
            }
        }
        return job
    }

    /// Job changes written since the last call.
    func poll() -> [Change] {
        var changes: [Change] = []
        for line in follower.readNewLines() {
            switch RunnerLogEvent.parse(line) {
            case .jobStarted(let name)?:
                currentJob = name
                changes.append(.started(name: name))
            case .jobCompleted(let name, let conclusion)?:
                currentJob = nil
                changes.append(.completed(name: name, conclusion: conclusion))
            case .listening?:
                // The runner restarted; a job it was running is over.
                if let job = currentJob {
                    currentJob = nil
                    changes.append(.completed(name: job, conclusion: "cancelled"))
                }
            case nil:
                continue
            }
        }
        return changes
    }
}
