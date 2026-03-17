import XCTest
@testable import MacRunner

final class MacRunnerTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }

    func testCLIHandlerVersionFallsBackToEnclosingAppBundleVersion() {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let appBundleURL = temporaryDirectory.appendingPathComponent("MacRunner.app", isDirectory: true)
        let contentsURL = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let executableURL = macOSURL.appendingPathComponent("MacRunner")
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")

        do {
            try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
            try "".write(to: executableURL, atomically: true, encoding: .utf8)

            let infoPlist: NSDictionary = [
                "CFBundleIdentifier": "com.omniaura.mac-runner.tests",
                "CFBundleShortVersionString": "1.11.0",
            ]
            XCTAssertTrue(infoPlist.write(to: infoPlistURL, atomically: true))

            let version = CLIHandler.version(
                executablePath: executableURL.path,
                mainBundle: Bundle(for: Self.self)
            )

            XCTAssertEqual(version, "1.11.0")
        } catch {
            XCTFail("Failed to set up bundle fixture: \(error)")
        }

        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testCLIHandlerEnclosingAppBundleURLReturnsNearestAppBundle() {
        let executableURL = URL(fileURLWithPath: "/Applications/MacRunner.app/Contents/MacOS/MacRunner")

        XCTAssertEqual(
            CLIHandler.enclosingAppBundleURL(for: executableURL)?.path,
            "/Applications/MacRunner.app"
        )
    }
}
