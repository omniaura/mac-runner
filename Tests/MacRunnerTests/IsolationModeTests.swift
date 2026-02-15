import XCTest
@testable import MacRunner

/// Unit tests for IsolationMode enum coding/decoding and functionality.
final class IsolationModeTests: XCTestCase {

    // MARK: - Coding Tests

    func testIsolationModeNoneEncoding() throws {
        let mode = IsolationMode.none
        let encoder = JSONEncoder()
        let data = try encoder.encode(mode)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "none")
    }

    func testIsolationModeNoneDecoding() throws {
        let json = """
        {"type": "none"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let mode = try decoder.decode(IsolationMode.self, from: json)

        XCTAssertEqual(mode, .none)
    }

    func testIsolationModeDedicatedUserEncoding() throws {
        let mode = IsolationMode.dedicatedUser(username: "_testrunner")
        let encoder = JSONEncoder()
        let data = try encoder.encode(mode)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "dedicatedUser")
        XCTAssertEqual(json?["username"] as? String, "_testrunner")
    }

    func testIsolationModeDedicatedUserDecoding() throws {
        let json = """
        {"type": "dedicatedUser", "username": "_testrunner"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let mode = try decoder.decode(IsolationMode.self, from: json)

        if case .dedicatedUser(let username) = mode {
            XCTAssertEqual(username, "_testrunner")
        } else {
            XCTFail("Expected dedicatedUser mode")
        }
    }

    func testIsolationModeContainerEncoding() throws {
        let mode = IsolationMode.container
        let encoder = JSONEncoder()
        let data = try encoder.encode(mode)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["type"] as? String, "container")
    }

    func testIsolationModeContainerDecoding() throws {
        let json = """
        {"type": "container"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let mode = try decoder.decode(IsolationMode.self, from: json)

        XCTAssertEqual(mode, .container)
    }

    func testIsolationModeUnknownTypeDefaultsToNone() throws {
        let json = """
        {"type": "unknown"}
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let mode = try decoder.decode(IsolationMode.self, from: json)

        XCTAssertEqual(mode, .none)
    }

    // MARK: - Display Name Tests

    func testDisplayNameNone() {
        let mode = IsolationMode.none
        XCTAssertEqual(mode.displayName, "None")
    }

    func testDisplayNameDedicatedUser() {
        let mode = IsolationMode.dedicatedUser(username: "_macrunner")
        XCTAssertEqual(mode.displayName, "User (_macrunner)")
    }

    func testDisplayNameContainer() {
        let mode = IsolationMode.container
        XCTAssertEqual(mode.displayName, "Container")
    }

    // MARK: - Icon Tests

    func testIconNone() {
        let mode = IsolationMode.none
        XCTAssertEqual(mode.icon, "🔓")
    }

    func testIconDedicatedUser() {
        let mode = IsolationMode.dedicatedUser(username: "_macrunner")
        XCTAssertEqual(mode.icon, "👤")
    }

    func testIconContainer() {
        let mode = IsolationMode.container
        XCTAssertEqual(mode.icon, "📦")
    }

    // MARK: - Equality Tests

    func testNoneEquality() {
        XCTAssertEqual(IsolationMode.none, IsolationMode.none)
    }

    func testDedicatedUserEquality() {
        let mode1 = IsolationMode.dedicatedUser(username: "_runner1")
        let mode2 = IsolationMode.dedicatedUser(username: "_runner1")
        let mode3 = IsolationMode.dedicatedUser(username: "_runner2")

        XCTAssertEqual(mode1, mode2)
        XCTAssertNotEqual(mode1, mode3)
    }

    func testContainerEquality() {
        XCTAssertEqual(IsolationMode.container, IsolationMode.container)
    }

    func testModeInequality() {
        XCTAssertNotEqual(IsolationMode.none, IsolationMode.container)
        XCTAssertNotEqual(
            IsolationMode.none,
            IsolationMode.dedicatedUser(username: "_runner")
        )
        XCTAssertNotEqual(
            IsolationMode.container,
            IsolationMode.dedicatedUser(username: "_runner")
        )
    }
}
