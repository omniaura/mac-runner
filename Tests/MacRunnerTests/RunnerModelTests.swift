import XCTest
@testable import MacRunner

/// Unit tests for Runner model, focusing on isolation mode functionality.
final class RunnerModelTests: XCTestCase {

    // MARK: - Initialization Tests

    func testRunnerInitialization() {
        let runner = Runner(
            name: "test-runner",
            repo: "owner/repo",
            labels: ["macos", "self-hosted"],
            isolationMode: .container,
            openFileLimit: 32768
        )

        XCTAssertEqual(runner.name, "test-runner")
        XCTAssertEqual(runner.repo, "owner/repo")
        XCTAssertEqual(runner.labels, ["macos", "self-hosted"])
        XCTAssertEqual(runner.isolationMode, .container)
        XCTAssertEqual(runner.openFileLimit, 32768)
        XCTAssertEqual(runner.enabled, true)
        XCTAssertEqual(runner.status, .stopped)
        XCTAssertEqual(runner.busy, false)
        XCTAssertNil(runner.githubRunnerId)
        XCTAssertNil(runner.lastRestartEvent)
    }

    func testRunnerInitializationWithDefaults() {
        let runner = Runner(
            name: "test-runner",
            repo: "owner/repo"
        )

        XCTAssertEqual(runner.labels, ["macos", "mac-runner"])
        XCTAssertNil(runner.isolationMode)
        XCTAssertNil(runner.openFileLimit)
        XCTAssertEqual(runner.enabled, true)
        XCTAssertEqual(runner.status, .stopped)
        XCTAssertEqual(runner.busy, false)
        XCTAssertNil(runner.lastRestartEvent)
    }

    // MARK: - Coding Tests

    func testRunnerEncodingWithIsolationMode() throws {
        let runner = Runner(
            id: UUID(),
            name: "test-runner",
            repo: "owner/repo",
            labels: ["linux", "self-hosted"],
            enabled: true,
            status: .running,
            githubRunnerId: 12345,
            busy: true,
            isolationMode: .container,
            lastRestartEvent: "Runner auto-restarted successfully.",
            openFileLimit: 32768
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(runner)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["name"] as? String, "test-runner")
        XCTAssertEqual(json?["repo"] as? String, "owner/repo")
        XCTAssertEqual(json?["enabled"] as? Bool, true)
        XCTAssertEqual(json?["busy"] as? Bool, true)
        XCTAssertEqual(json?["githubRunnerId"] as? Int, 12345)
        XCTAssertEqual(json?["lastRestartEvent"] as? String, "Runner auto-restarted successfully.")

        // Check isolation mode is encoded
        let isolationModeData = json?["isolationMode"] as? [String: Any]
        XCTAssertEqual(isolationModeData?["type"] as? String, "container")
        XCTAssertEqual(json?["openFileLimit"] as? Int, 32768)
    }

    func testRunnerDecodingWithIsolationMode() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "test-runner",
            "repo": "owner/repo",
            "labels": ["linux", "self-hosted"],
            "enabled": true,
            "status": "running",
            "githubRunnerId": 12345,
            "busy": true,
            "lastRestartEvent": "Runner auto-restarted successfully.",
            "openFileLimit": 32768,
            "isolationMode": {
                "type": "container"
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let runner = try decoder.decode(Runner.self, from: json)

        XCTAssertEqual(runner.name, "test-runner")
        XCTAssertEqual(runner.repo, "owner/repo")
        XCTAssertEqual(runner.labels, ["linux", "self-hosted"])
        XCTAssertEqual(runner.enabled, true)
        XCTAssertEqual(runner.status, .running)
        XCTAssertEqual(runner.githubRunnerId, 12345)
        XCTAssertEqual(runner.busy, true)
        XCTAssertEqual(runner.openFileLimit, 32768)
        XCTAssertEqual(runner.isolationMode, .container)
        XCTAssertEqual(runner.lastRestartEvent, "Runner auto-restarted successfully.")
    }

    func testRunnerDecodingWithoutIsolationMode() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "test-runner",
            "repo": "owner/repo",
            "labels": ["macos"],
            "enabled": true,
            "status": "stopped"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let runner = try decoder.decode(Runner.self, from: json)

        XCTAssertNil(runner.isolationMode)
        XCTAssertNil(runner.openFileLimit)
        XCTAssertEqual(runner.busy, false)  // Default value for backward compatibility
        XCTAssertNil(runner.lastRestartEvent)
    }

    func testRunnerDecodingBackwardCompatibility() throws {
        // Old runner config without busy and isolationMode fields
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "legacy-runner",
            "repo": "owner/repo",
            "labels": ["macos"],
            "enabled": true,
            "status": "running",
            "githubRunnerId": 999
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let runner = try decoder.decode(Runner.self, from: json)

        XCTAssertEqual(runner.name, "legacy-runner")
        XCTAssertEqual(runner.busy, false)  // Default
        XCTAssertNil(runner.isolationMode)  // Default
        XCTAssertNil(runner.openFileLimit)  // Default
        XCTAssertEqual(runner.githubRunnerId, 999)
        XCTAssertNil(runner.lastRestartEvent)
    }

    // MARK: - Effective Isolation Mode Tests

    func testEffectiveIsolationModeWithPerRunnerOverride() {
        let runner = Runner(
            name: "test-runner",
            repo: "owner/repo",
            isolationMode: .container
        )

        let globalMode = IsolationMode.dedicatedUser(username: "_macrunner")
        let effective = runner.effectiveIsolationMode(global: globalMode)

        // Per-runner setting takes precedence
        XCTAssertEqual(effective, .container)
    }

    func testEffectiveIsolationModeWithoutOverride() {
        let runner = Runner(
            name: "test-runner",
            repo: "owner/repo",
            isolationMode: nil
        )

        let globalMode = IsolationMode.dedicatedUser(username: "_macrunner")
        let effective = runner.effectiveIsolationMode(global: globalMode)

        // Falls back to global setting
        XCTAssertEqual(effective, .dedicatedUser(username: "_macrunner"))
    }

    func testEffectiveIsolationModeGlobalNone() {
        let runner = Runner(
            name: "test-runner",
            repo: "owner/repo",
            isolationMode: nil
        )

        let globalMode = IsolationMode.none
        let effective = runner.effectiveIsolationMode(global: globalMode)

        XCTAssertEqual(effective, .none)
    }

    func testEffectiveOpenFileLimitWithPerRunnerOverride() {
        let runner = Runner(
            name: "test-runner",
            repo: "owner/repo",
            openFileLimit: 32768
        )

        XCTAssertEqual(runner.effectiveOpenFileLimit(global: ResourceLimits.defaultOpenFileLimit), 32768)
    }

    func testEffectiveOpenFileLimitWithoutOverride() {
        let runner = Runner(
            name: "test-runner",
            repo: "owner/repo"
        )

        XCTAssertEqual(runner.effectiveOpenFileLimit(global: 131072), 131072)
    }

    // MARK: - Runner Status Tests

    func testRunnerStatusIcon() {
        XCTAssertEqual(RunnerStatus.running.icon, "●")
        XCTAssertEqual(RunnerStatus.stopped.icon, "○")
        XCTAssertEqual(RunnerStatus.paused.icon, "⏸")
        XCTAssertEqual(RunnerStatus.error.icon, "⚠️")
    }

    func testRunnerStatusColor() {
        XCTAssertEqual(RunnerStatus.running.color, "green")
        XCTAssertEqual(RunnerStatus.stopped.color, "gray")
        XCTAssertEqual(RunnerStatus.paused.color, "orange")
        XCTAssertEqual(RunnerStatus.error.color, "red")
    }
}
