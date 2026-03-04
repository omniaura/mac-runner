import XCTest
@testable import MacRunner

/// Unit tests for runner name generation — baseName stripping and unique name logic.
final class RunnerNamingTests: XCTestCase {

    // MARK: - baseName(from:)

    func testBaseNameStripsNumericSuffix() {
        XCTAssertEqual(RunnerManager.baseName(from: "my-runner-2"), "my-runner")
        XCTAssertEqual(RunnerManager.baseName(from: "my-runner-99"), "my-runner")
        XCTAssertEqual(RunnerManager.baseName(from: "runner-1"), "runner")
    }

    func testBaseNamePreservesNameWithoutSuffix() {
        XCTAssertEqual(RunnerManager.baseName(from: "my-runner"), "my-runner")
        XCTAssertEqual(RunnerManager.baseName(from: "runner"), "runner")
    }

    func testBaseNamePreservesNonNumericSuffix() {
        XCTAssertEqual(RunnerManager.baseName(from: "my-runner-arm"), "my-runner-arm")
        XCTAssertEqual(RunnerManager.baseName(from: "my-runner-abc"), "my-runner-abc")
    }

    func testBaseNameStripsOnlyLastNumericSegment() {
        // "my-runner-2-3" → strip "-3" → "my-runner-2"
        XCTAssertEqual(RunnerManager.baseName(from: "my-runner-2-3"), "my-runner-2")
    }

    func testBaseNameWithNoDash() {
        XCTAssertEqual(RunnerManager.baseName(from: "runner"), "runner")
    }

    func testBaseNameWithEmptyNumericSuffix() {
        // Trailing dash with nothing after it — not a numeric suffix
        XCTAssertEqual(RunnerManager.baseName(from: "runner-"), "runner-")
    }
}
