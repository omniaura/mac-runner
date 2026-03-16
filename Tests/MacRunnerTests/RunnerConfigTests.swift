import XCTest
@testable import MacRunner

/// Unit tests for RunnerConfig persistence and migration.
final class RunnerConfigTests: XCTestCase {

    // MARK: - Initialization Tests

    func testRunnerConfigDefaultInitialization() {
        let config = RunnerConfig.default

        XCTAssertEqual(config.runners.count, 0)
        XCTAssertEqual(config.settings.isolationMode, .none)
        XCTAssertEqual(config.settings.startOnLogin, false)
        XCTAssertEqual(config.settings.openFileLimit, ResourceLimits.defaultOpenFileLimit)
    }

    func testRunnerConfigCustomInitialization() {
        let runner1 = Runner(name: "runner1", repo: "owner/repo1")
        let runner2 = Runner(name: "runner2", repo: "owner/repo2", isolationMode: .container, openFileLimit: 32768)
        let settings = AppSettings(isolationMode: .dedicatedUser(username: "_macrunner"), openFileLimit: 131072)

        let config = RunnerConfig(
            runners: [runner1, runner2],
            settings: settings
        )

        XCTAssertEqual(config.runners.count, 2)
        XCTAssertEqual(config.runners[0].name, "runner1")
        XCTAssertEqual(config.runners[1].name, "runner2")
        XCTAssertEqual(config.runners[1].isolationMode, .container)
        XCTAssertEqual(config.runners[1].openFileLimit, 32768)
        XCTAssertEqual(config.settings.isolationMode, .dedicatedUser(username: "_macrunner"))
        XCTAssertEqual(config.settings.openFileLimit, 131072)
    }

    // MARK: - Coding Tests

    func testRunnerConfigEncodingWithMixedIsolation() throws {
        let runner1 = Runner(
            name: "macos-runner",
            repo: "owner/repo1",
            labels: ["macos"],
            isolationMode: .dedicatedUser(username: "_runner1"),
            openFileLimit: 32768
        )
        let runner2 = Runner(
            name: "linux-runner",
            repo: "owner/repo2",
            labels: ["linux"],
            isolationMode: .container
        )
        let runner3 = Runner(
            name: "default-runner",
            repo: "owner/repo3",
            labels: ["macos"],
            isolationMode: nil  // Will use global setting
        )

        let config = RunnerConfig(
            runners: [runner1, runner2, runner3],
            settings: AppSettings(isolationMode: .none, openFileLimit: 131072)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(config)

        // Verify it encodes without errors
        XCTAssertGreaterThan(data.count, 0)

        // Verify structure
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)

        let runners = json?["runners"] as? [[String: Any]]
        XCTAssertEqual(runners?.count, 3)

        let settings = json?["settings"] as? [String: Any]
        let isolationMode = settings?["isolationMode"] as? [String: Any]
        XCTAssertEqual(isolationMode?["type"] as? String, "none")
        XCTAssertEqual(settings?["openFileLimit"] as? Int, 131072)
    }

    func testRunnerConfigDecodingWithMixedIsolation() throws {
        let json = """
        {
            "runners": [
                {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "name": "macos-runner",
                    "repo": "owner/repo1",
                    "labels": ["macos"],
                    "enabled": true,
                    "status": "running",
                    "busy": false,
                    "openFileLimit": 32768,
                    "isolationMode": {
                        "type": "dedicatedUser",
                        "username": "_runner1"
                    }
                },
                {
                    "id": "00000000-0000-0000-0000-000000000002",
                    "name": "linux-runner",
                    "repo": "owner/repo2",
                    "labels": ["linux"],
                    "enabled": true,
                    "status": "stopped",
                    "busy": false,
                    "isolationMode": {
                        "type": "container"
                    }
                },
                {
                    "id": "00000000-0000-0000-0000-000000000003",
                    "name": "default-runner",
                    "repo": "owner/repo3",
                    "labels": ["macos"],
                    "enabled": true,
                    "status": "stopped",
                    "busy": false
                }
            ],
            "settings": {
                "startOnLogin": false,
                "pauseOnBattery": false,
                "openFileLimit": 131072,
                "isolationMode": {
                    "type": "none"
                }
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let config = try decoder.decode(RunnerConfig.self, from: json)

        XCTAssertEqual(config.runners.count, 3)

        // First runner: dedicated user isolation
        XCTAssertEqual(config.runners[0].name, "macos-runner")
        if case .dedicatedUser(let username) = config.runners[0].isolationMode {
            XCTAssertEqual(username, "_runner1")
        } else {
            XCTFail("Expected dedicatedUser isolation mode")
        }
        XCTAssertEqual(config.runners[0].openFileLimit, 32768)

        // Second runner: container isolation
        XCTAssertEqual(config.runners[1].name, "linux-runner")
        XCTAssertEqual(config.runners[1].isolationMode, .container)

        // Third runner: nil (uses global setting)
        XCTAssertEqual(config.runners[2].name, "default-runner")
        XCTAssertNil(config.runners[2].isolationMode)

        // Global settings
        XCTAssertEqual(config.settings.isolationMode, .none)
        XCTAssertEqual(config.settings.openFileLimit, 131072)
    }

    func testRunnerConfigBackwardCompatibility() throws {
        // Old config format without isolationMode fields
        let json = """
        {
            "runners": [
                {
                    "id": "00000000-0000-0000-0000-000000000001",
                    "name": "legacy-runner",
                    "repo": "owner/repo",
                    "labels": ["macos"],
                    "enabled": true,
                    "status": "running"
                }
            ],
            "settings": {
                "startOnLogin": true,
                "pauseOnBattery": false
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let config = try decoder.decode(RunnerConfig.self, from: json)

        XCTAssertEqual(config.runners.count, 1)
        XCTAssertEqual(config.runners[0].name, "legacy-runner")
        XCTAssertNil(config.runners[0].isolationMode)  // Default
        XCTAssertEqual(config.runners[0].busy, false)  // Default
        XCTAssertNil(config.runners[0].openFileLimit)  // Default
        XCTAssertEqual(config.settings.isolationMode, .none)  // Default
        XCTAssertEqual(config.settings.openFileLimit, ResourceLimits.defaultOpenFileLimit)  // Default
    }

    // MARK: - Round-trip Tests

    func testRunnerConfigRoundTrip() throws {
        let originalRunner = Runner(
            name: "test-runner",
            repo: "owner/repo",
            labels: ["linux", "self-hosted"],
            enabled: true,
            status: .running,
            busy: true,
            isolationMode: .container,
            openFileLimit: 32768
        )

        let originalConfig = RunnerConfig(
            runners: [originalRunner],
            settings: AppSettings(
                startOnLogin: true,
                pauseOnBattery: false,
                isolationMode: .dedicatedUser(username: "_macrunner"),
                openFileLimit: 131072
            )
        )

        // Encode
        let encoder = JSONEncoder()
        let data = try encoder.encode(originalConfig)

        // Decode
        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(RunnerConfig.self, from: data)

        // Verify round-trip preserves all data
        XCTAssertEqual(decodedConfig.runners.count, 1)
        XCTAssertEqual(decodedConfig.runners[0].name, originalRunner.name)
        XCTAssertEqual(decodedConfig.runners[0].repo, originalRunner.repo)
        XCTAssertEqual(decodedConfig.runners[0].labels, originalRunner.labels)
        XCTAssertEqual(decodedConfig.runners[0].enabled, originalRunner.enabled)
        XCTAssertEqual(decodedConfig.runners[0].status, originalRunner.status)
        XCTAssertEqual(decodedConfig.runners[0].busy, originalRunner.busy)
        XCTAssertEqual(decodedConfig.runners[0].isolationMode, originalRunner.isolationMode)
        XCTAssertEqual(decodedConfig.runners[0].openFileLimit, originalRunner.openFileLimit)

        XCTAssertEqual(decodedConfig.settings.startOnLogin, originalConfig.settings.startOnLogin)
        XCTAssertEqual(decodedConfig.settings.pauseOnBattery, originalConfig.settings.pauseOnBattery)
        XCTAssertEqual(decodedConfig.settings.isolationMode, originalConfig.settings.isolationMode)
        XCTAssertEqual(decodedConfig.settings.openFileLimit, originalConfig.settings.openFileLimit)
    }
}
