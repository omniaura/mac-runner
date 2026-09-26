import XCTest
@testable import MacRunner

final class ResourceMonitorTests: XCTestCase {
    func testParsesPSOutput() {
        let samples = ResourceMonitor.parsePSOutput("""
          123   12.5  20480
          456    0,3   1024
        garbage line
          789
        """)
        XCTAssertEqual(samples[123], .init(cpuPercent: 12.5, residentBytes: 20_971_520))
        XCTAssertEqual(samples[456], .init(cpuPercent: 0.3, residentBytes: 1_048_576))
        XCTAssertEqual(samples.count, 2)
    }

    func testParsesDUOutputIgnoringWarnings() {
        XCTAssertEqual(ResourceMonitor.parseDUOutput("du: ./x: Permission denied\n2048\t/some/dir\n"), 2_097_152)
        XCTAssertNil(ResourceMonitor.parseDUOutput("du: /nope: No such file or directory\n"))
    }

    func testContainerCPUPercentFromCumulativeTime() {
        XCTAssertEqual(ResourceMonitor.cpuPercent(previousUsec: 1_000_000, currentUsec: 3_000_000, elapsed: 2), 100, accuracy: 0.001)
        XCTAssertEqual(ResourceMonitor.cpuPercent(previousUsec: 5, currentUsec: 1, elapsed: 1), 0, "counter reset")
        XCTAssertEqual(ResourceMonitor.cpuPercent(previousUsec: 0, currentUsec: 10, elapsed: 0), 0)
    }

    func testTotalsAndFormatting() {
        let total = RunnerResourceUsage.total([
            RunnerResourceUsage(cpuPercent: 12.4, memoryBytes: 300 * 1_048_576, processCount: 3, diskBytes: 1_000_000_000),
            RunnerResourceUsage(cpuPercent: 0.25, memoryBytes: 100 * 1_048_576, processCount: 2, diskBytes: nil),
        ])
        XCTAssertEqual(total.cpuPercent, 12.65, accuracy: 0.001)
        XCTAssertEqual(total.processCount, 5)
        XCTAssertEqual(total.diskBytes, 1_000_000_000)
        XCTAssertEqual(total.cpuText, "13%")
        XCTAssertEqual(RunnerResourceUsage(cpuPercent: 0.26, memoryBytes: 0, processCount: 0).cpuText, "0.3%")
        XCTAssertTrue(total.summary.hasPrefix("CPU 13% · "))
        XCTAssertTrue(total.summary.contains("Disk "))
        XCTAssertNil(RunnerResourceUsage.zero.diskText)
    }

    func testMeasuresALiveProcessTree() throws {
        let root = Process()
        root.executableURL = URL(fileURLWithPath: "/bin/bash")
        root.arguments = ["-c", "sleep 30 & sleep 30 & wait"]
        try root.run()
        defer { ProcessUtils.killProcessTree(root.processIdentifier) }

        let deadline = Date().addingTimeInterval(5)
        var usage = RunnerResourceUsage.zero
        while Date() < deadline {
            usage = ResourceMonitor.usage(ofProcessTree: root.processIdentifier)
            if usage.processCount >= 3 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertEqual(usage.processCount, 3, "bash plus two sleeps")
        XCTAssertGreaterThan(usage.memoryBytes, 0)
    }

    func testMeasuresWorkspaceSize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("du-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(count: 2 * 1_048_576).write(to: directory.appendingPathComponent("blob"))

        XCTAssertGreaterThanOrEqual(ResourceMonitor.directorySize(directory.path) ?? 0, 2 * 1_048_576)
        XCTAssertNil(ResourceMonitor.directorySize(directory.appendingPathComponent("missing").path))
    }

    func testAlertThresholds() {
        let usage = RunnerResourceUsage(cpuPercent: 450, memoryBytes: 20 * 1_073_741_824, processCount: 1)
        XCTAssertEqual(ResourceAlertSettings.default.exceeded(by: usage), [], "disabled by default")

        var alerts = ResourceAlertSettings(enabled: true, cpuPercent: 400, memoryGB: 16)
        XCTAssertEqual(alerts.exceeded(by: usage).count, 2)
        alerts.memoryGB = 32
        XCTAssertEqual(alerts.exceeded(by: usage), ["CPU 450% (limit 400%)"])
    }

    func testSettingsDecodeWithoutResourceAlerts() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.resourceAlerts, .default)
        let custom = AppSettings(resourceAlerts: ResourceAlertSettings(enabled: true, cpuPercent: 800, memoryGB: 8))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(custom)).resourceAlerts, custom.resourceAlerts)
    }

    func testResourceTable() {
        let a = Runner(name: "alpha", repo: "o/r", status: .running)
        let b = Runner(name: "b", repo: "o/r", status: .running)
        let stopped = Runner(name: "stopped", repo: "o/r")
        let table = CLIHandler.resourceTable(runners: [b, stopped, a], usage: [
            a.id: RunnerResourceUsage(cpuPercent: 5, memoryBytes: 1_048_576, processCount: 3, diskBytes: nil),
            b.id: RunnerResourceUsage(cpuPercent: 20, memoryBytes: 2_097_152, processCount: 4, diskBytes: 1_000_000),
        ])
        let lines = table.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4)
        XCTAssertTrue(lines[0].hasPrefix("NAME "))
        XCTAssertTrue(lines[1].hasPrefix("alpha"))
        XCTAssertTrue(lines[3].hasPrefix("TOTAL"))
        XCTAssertTrue(lines[3].contains("25%"))
        XCTAssertFalse(table.contains("stopped"))
        XCTAssertEqual(CLIHandler.resourceTable(runners: [stopped], usage: [:]), "No running runners.")
    }
}
