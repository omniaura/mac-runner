import Foundation

/// CPU, memory, and disk use for one runner.
struct RunnerResourceUsage: Sendable, Equatable {
    /// Sum across the runner's processes; 100 = one full core.
    var cpuPercent: Double
    var memoryBytes: UInt64
    var processCount: Int
    /// Size of the runner workspace; nil until measured (it's sampled less often).
    var diskBytes: UInt64?
    /// Some of the workspace couldn't be read, so `diskBytes` is a lower bound.
    var diskIsPartial = false

    static let zero = RunnerResourceUsage(cpuPercent: 0, memoryBytes: 0, processCount: 0, diskBytes: nil)

    static func total(_ usages: [RunnerResourceUsage]) -> RunnerResourceUsage {
        usages.reduce(into: .zero) { total, usage in
            total.cpuPercent += usage.cpuPercent
            total.memoryBytes += usage.memoryBytes
            total.processCount += usage.processCount
            if let disk = usage.diskBytes {
                total.diskBytes = (total.diskBytes ?? 0) + disk
                total.diskIsPartial = total.diskIsPartial || usage.diskIsPartial
            }
        }
    }

    var cpuText: String {
        cpuPercent >= 10 || cpuPercent == 0 ? "\(Int(cpuPercent.rounded()))%" : String(format: "%.1f%%", cpuPercent)
    }

    var memoryText: String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: memoryBytes), countStyle: .memory)
    }

    var diskText: String? {
        diskBytes.map {
            (diskIsPartial ? "≥ " : "") + ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file)
        }
    }

    /// e.g. "CPU 12% · 340 MB · Disk 2.1 GB"
    var summary: String {
        var parts = ["CPU \(cpuText)", memoryText]
        if let diskText { parts.append("Disk \(diskText)") }
        return parts.joined(separator: " · ")
    }
}

/// Samples runner process trees with `ps` (which also reports processes owned
/// by a dedicated service user) and measures workspaces with `du`.
enum ResourceMonitor {
    struct ProcessSample: Equatable {
        var cpuPercent: Double
        var residentBytes: UInt64
    }

    /// Parses `ps -o pid=,%cpu=,rss=` output (RSS in KiB).
    static func parsePSOutput(_ output: String) -> [pid_t: ProcessSample] {
        var samples: [pid_t: ProcessSample] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 3,
                  let pid = pid_t(fields[0]),
                  let cpu = Double(fields[1].replacingOccurrences(of: ",", with: ".")),
                  let rssKiB = UInt64(fields[2]) else { continue }
            samples[pid] = ProcessSample(cpuPercent: cpu, residentBytes: rssKiB * 1024)
        }
        return samples
    }

    static func sampleProcesses(_ pids: [pid_t]) -> [pid_t: ProcessSample] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        // ps exits 1 when some pids have already exited; the rest are still printed.
        guard let result = try? ProcessExecutor.run("/bin/ps", arguments: ["-o", "pid=,%cpu=,rss=", "-p", list], timeout: 10) else {
            return [:]
        }
        return parsePSOutput(result.output)
    }

    /// Usage of the process tree rooted at `rootPID`.
    static func usage(ofProcessTree rootPID: pid_t) -> RunnerResourceUsage {
        let pids = [rootPID] + ProcessUtils.findDescendants(of: rootPID)
        return aggregate(sampleProcesses(pids))
    }

    static func aggregate(_ samples: [pid_t: ProcessSample]) -> RunnerResourceUsage {
        RunnerResourceUsage(
            cpuPercent: samples.values.reduce(0) { $0 + $1.cpuPercent },
            memoryBytes: samples.values.reduce(0) { $0 + $1.residentBytes },
            processCount: samples.count,
            diskBytes: nil
        )
    }

    struct DiskMeasurement: Equatable, Sendable {
        var bytes: UInt64
        /// False when `du` couldn't read part of the tree (the total is a lower bound).
        var isComplete: Bool
    }

    /// Workspace size via `du -sk`, giving up after `timeout` seconds.
    static func directorySize(_ path: String, timeout: TimeInterval = 120) -> DiskMeasurement? {
        guard FileManager.default.fileExists(atPath: path),
              let result = try? ProcessExecutor.run("/usr/bin/du", arguments: ["-sk", path], timeout: timeout),
              let bytes = parseDUOutput(result.output) else {
            return nil
        }
        return DiskMeasurement(bytes: bytes, isComplete: result.succeeded)
    }

    static func parseDUOutput(_ output: String) -> UInt64? {
        // Last line is the total; earlier lines may be permission warnings.
        guard let line = output.split(separator: "\n").last(where: { $0.first?.isNumber == true }),
              let kib = UInt64(line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first ?? "") else {
            return nil
        }
        return kib * 1024
    }

    /// CPU percent from two cumulative CPU-time readings (container cgroup stats).
    static func cpuPercent(previousUsec: UInt64, currentUsec: UInt64, elapsed: TimeInterval) -> Double {
        guard elapsed > 0, currentUsec >= previousUsec else { return 0 }
        return Double(currentUsec - previousUsec) / (elapsed * 1_000_000) * 100
    }
}

/// When total usage should raise an alert.
struct ResourceAlertSettings: Codable, Sendable, Equatable {
    var enabled: Bool
    /// Total CPU across runners, 100 = one core.
    var cpuPercent: Int {
        didSet { cpuPercent = max(1, cpuPercent) }
    }
    var memoryGB: Int {
        didSet { memoryGB = max(1, memoryGB) }
    }

    static let `default` = ResourceAlertSettings(enabled: false, cpuPercent: 400, memoryGB: 16)

    init(enabled: Bool, cpuPercent: Int, memoryGB: Int) {
        self.enabled = enabled
        self.cpuPercent = max(1, cpuPercent)
        self.memoryGB = max(1, memoryGB)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            cpuPercent: try container.decodeIfPresent(Int.self, forKey: .cpuPercent) ?? Self.default.cpuPercent,
            memoryGB: try container.decodeIfPresent(Int.self, forKey: .memoryGB) ?? Self.default.memoryGB
        )
    }

    enum Limit: String, Sendable, CaseIterable {
        case cpu, memory
    }

    /// Limits `total` is over, with a description of each.
    func exceeded(by total: RunnerResourceUsage) -> [Limit: String] {
        guard enabled else { return [:] }
        var over: [Limit: String] = [:]
        if total.cpuPercent > Double(max(1, cpuPercent)) {
            over[.cpu] = "CPU \(total.cpuText) (limit \(cpuPercent)%)"
        }
        if total.memoryBytes > UInt64(max(1, memoryGB)) * 1_073_741_824 {
            over[.memory] = "memory \(total.memoryText) (limit \(memoryGB) GB)"
        }
        return over
    }
}
