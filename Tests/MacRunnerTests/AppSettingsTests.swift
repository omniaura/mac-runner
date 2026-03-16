import XCTest
@testable import MacRunner

/// Unit tests for AppSettings model and isolation mode persistence.
final class AppSettingsTests: XCTestCase {

    // MARK: - Initialization Tests

    func testAppSettingsDefaultInitialization() {
        let settings = AppSettings.default

        XCTAssertEqual(settings.startOnLogin, false)
        XCTAssertEqual(settings.pauseOnBattery, false)
        XCTAssertNil(settings.quietHours)
        XCTAssertEqual(settings.isolationMode, .none)
        XCTAssertEqual(settings.openFileLimit, ResourceLimits.defaultOpenFileLimit)
    }

    func testAppSettingsCustomInitialization() {
        let settings = AppSettings(
            startOnLogin: true,
            pauseOnBattery: true,
            quietHours: QuietHours(enabled: true, start: "22:00", end: "08:00"),
            isolationMode: .dedicatedUser(username: "_testrunner"),
            openFileLimit: 32768
        )

        XCTAssertEqual(settings.startOnLogin, true)
        XCTAssertEqual(settings.pauseOnBattery, true)
        XCTAssertNotNil(settings.quietHours)
        XCTAssertEqual(settings.quietHours?.start, "22:00")
        XCTAssertEqual(settings.isolationMode, .dedicatedUser(username: "_testrunner"))
        XCTAssertEqual(settings.openFileLimit, 32768)
    }

    // MARK: - Coding Tests

    func testAppSettingsEncoding() throws {
        let settings = AppSettings(
            startOnLogin: true,
            pauseOnBattery: false,
            quietHours: QuietHours(enabled: true, start: "23:00", end: "07:00"),
            isolationMode: .container,
            openFileLimit: 131072
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(settings)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["startOnLogin"] as? Bool, true)
        XCTAssertEqual(json?["pauseOnBattery"] as? Bool, false)
        XCTAssertEqual(json?["openFileLimit"] as? Int, 131072)

        let isolationModeData = json?["isolationMode"] as? [String: Any]
        XCTAssertEqual(isolationModeData?["type"] as? String, "container")

        let quietHoursData = json?["quietHours"] as? [String: Any]
        XCTAssertEqual(quietHoursData?["enabled"] as? Bool, true)
        XCTAssertEqual(quietHoursData?["start"] as? String, "23:00")
        XCTAssertEqual(quietHoursData?["end"] as? String, "07:00")
    }

    func testAppSettingsDecoding() throws {
        let json = """
        {
            "startOnLogin": true,
            "pauseOnBattery": true,
            "quietHours": {
                "enabled": true,
                "start": "22:00",
                "end": "08:00"
            },
            "openFileLimit": 32768,
            "isolationMode": {
                "type": "dedicatedUser",
                "username": "_macrunner"
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let settings = try decoder.decode(AppSettings.self, from: json)

        XCTAssertEqual(settings.startOnLogin, true)
        XCTAssertEqual(settings.pauseOnBattery, true)
        XCTAssertNotNil(settings.quietHours)
        XCTAssertEqual(settings.quietHours?.enabled, true)
        XCTAssertEqual(settings.quietHours?.start, "22:00")
        XCTAssertEqual(settings.quietHours?.end, "08:00")
        XCTAssertEqual(settings.isolationMode, .dedicatedUser(username: "_macrunner"))
        XCTAssertEqual(settings.openFileLimit, 32768)
    }

    func testAppSettingsBackwardCompatibility() throws {
        // Old config without isolationMode field
        let json = """
        {
            "startOnLogin": false,
            "pauseOnBattery": true
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let settings = try decoder.decode(AppSettings.self, from: json)

        XCTAssertEqual(settings.startOnLogin, false)
        XCTAssertEqual(settings.pauseOnBattery, true)
        XCTAssertNil(settings.quietHours)
        XCTAssertEqual(settings.isolationMode, .none)  // Default value
        XCTAssertEqual(settings.openFileLimit, ResourceLimits.defaultOpenFileLimit)
    }

    func testAppSettingsMinimalConfig() throws {
        // Empty config should use defaults
        let json = """
        {}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let settings = try decoder.decode(AppSettings.self, from: json)

        XCTAssertEqual(settings.startOnLogin, false)
        XCTAssertEqual(settings.pauseOnBattery, false)
        XCTAssertNil(settings.quietHours)
        XCTAssertEqual(settings.isolationMode, .none)
        XCTAssertEqual(settings.openFileLimit, ResourceLimits.defaultOpenFileLimit)
    }

    // MARK: - Quiet Hours Tests

    func testQuietHoursEncoding() throws {
        let quietHours = QuietHours(enabled: true, start: "22:00", end: "06:00")

        let encoder = JSONEncoder()
        let data = try encoder.encode(quietHours)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["enabled"] as? Bool, true)
        XCTAssertEqual(json?["start"] as? String, "22:00")
        XCTAssertEqual(json?["end"] as? String, "06:00")
    }

    func testQuietHoursDecoding() throws {
        let json = """
        {
            "enabled": false,
            "start": "23:30",
            "end": "07:30"
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let quietHours = try decoder.decode(QuietHours.self, from: json)

        XCTAssertEqual(quietHours.enabled, false)
        XCTAssertEqual(quietHours.start, "23:30")
        XCTAssertEqual(quietHours.end, "07:30")
    }
}
