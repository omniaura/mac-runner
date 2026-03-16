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
}
