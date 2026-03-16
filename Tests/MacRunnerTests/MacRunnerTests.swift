import XCTest
@testable import MacRunner

final class MacRunnerTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }

    func testPreferredKernelPathPrefersBundledKernel() {
        let bundleURL = URL(fileURLWithPath: "/Applications/MacRunner.app/Contents/Resources")
        let appSupportURL = URL(fileURLWithPath: "/Users/test/Library/Application Support/MacRunner")

        let preferredPath = RunnerManager.preferredKernelPath(
            bundleResourceURL: bundleURL,
            applicationSupportURL: appSupportURL,
            fileExists: { path in
                path == "/Applications/MacRunner.app/Contents/Resources/vmlinux" ||
                path == "/Users/test/Library/Application Support/MacRunner/vmlinux"
            }
        )

        XCTAssertEqual(preferredPath?.path, "/Applications/MacRunner.app/Contents/Resources/vmlinux")
    }

    func testPreferredKernelPathFallsBackToApplicationSupport() {
        let bundleURL = URL(fileURLWithPath: "/Applications/MacRunner.app/Contents/Resources")
        let appSupportURL = URL(fileURLWithPath: "/Users/test/Library/Application Support/MacRunner")

        let preferredPath = RunnerManager.preferredKernelPath(
            bundleResourceURL: bundleURL,
            applicationSupportURL: appSupportURL,
            fileExists: { path in
                path == "/Users/test/Library/Application Support/MacRunner/vmlinux"
            }
        )

        XCTAssertEqual(preferredPath?.path, "/Users/test/Library/Application Support/MacRunner/vmlinux")
    }

    func testPreferredKernelPathReturnsNilWhenKernelMissing() {
        let bundleURL = URL(fileURLWithPath: "/Applications/MacRunner.app/Contents/Resources")
        let appSupportURL = URL(fileURLWithPath: "/Users/test/Library/Application Support/MacRunner")

        let preferredPath = RunnerManager.preferredKernelPath(
            bundleResourceURL: bundleURL,
            applicationSupportURL: appSupportURL,
            fileExists: { _ in false }
        )

        XCTAssertNil(preferredPath)
    }

    func testDetectedIsolationUsernameUsesConfiguredDedicatedUser() {
        let username = SetupWizard.detectedIsolationUsername(
            configuredIsolationMode: .dedicatedUser(username: "_customrunner"),
            userExists: { _ in false },
            hasSudoersEntry: { false }
        )

        XCTAssertEqual(username, "_customrunner")
    }

    func testDetectedIsolationUsernameFallsBackToDefaultUserWhenArtifactsExist() {
        let username = SetupWizard.detectedIsolationUsername(
            configuredIsolationMode: .none,
            userExists: { $0 == IsolationMode.defaultUsername },
            hasSudoersEntry: { false }
        )

        XCTAssertEqual(username, IsolationMode.defaultUsername)
    }

    func testDetectedIsolationUsernameFallsBackToDefaultUserWhenSudoersExists() {
        let username = SetupWizard.detectedIsolationUsername(
            configuredIsolationMode: .none,
            userExists: { _ in false },
            hasSudoersEntry: { true }
        )

        XCTAssertEqual(username, IsolationMode.defaultUsername)
    }

    func testDetectedIsolationUsernameReturnsNilWithoutConfigOrArtifacts() {
        let username = SetupWizard.detectedIsolationUsername(
            configuredIsolationMode: .none,
            userExists: { _ in false },
            hasSudoersEntry: { false }
        )

        XCTAssertNil(username)
    }
}
