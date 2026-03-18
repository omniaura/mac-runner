import XCTest
@testable import MacRunner

final class UpdateInstallerTests: XCTestCase {
    func testBrewExecutablePathPrefersAppleSiliconLocation() {
        let path = UpdateInstaller.brewExecutablePath { candidate in
            candidate == "/opt/homebrew/bin/brew" || candidate == "/usr/local/bin/brew"
        }

        XCTAssertEqual(path, "/opt/homebrew/bin/brew")
    }

    func testCommandUsesFormulaUpgradeArguments() throws {
        let command = try UpdateInstaller.command(
            for: Self.availableUpdate(installSource: .homebrewFormula),
            fileExists: { $0 == "/opt/homebrew/bin/brew" }
        )

        XCTAssertEqual(command.executable, "/opt/homebrew/bin/brew")
        XCTAssertEqual(command.arguments, ["upgrade", "mac-runner"])
    }

    func testCommandUsesCaskUpgradeArguments() throws {
        let command = try UpdateInstaller.command(
            for: Self.availableUpdate(installSource: .homebrewCask),
            fileExists: { $0 == "/usr/local/bin/brew" }
        )

        XCTAssertEqual(command.executable, "/usr/local/bin/brew")
        XCTAssertEqual(command.arguments, ["upgrade", "--cask", "mac-runner"])
    }

    func testCommandRejectsDirectDownloads() {
        XCTAssertThrowsError(
            try UpdateInstaller.command(
                for: Self.availableUpdate(installSource: .directDownload),
                fileExists: { _ in true }
            )
        ) { error in
            XCTAssertEqual(error as? UpdateInstallerError, .automaticUpdateUnavailable)
        }
    }

    func testInstallThrowsWhenHomebrewCommandFails() async {
        let installer = UpdateInstaller(
            fileExists: { $0 == "/opt/homebrew/bin/brew" },
            runCommand: { _, _ in
                UpdateInstallerCommandResult(terminationStatus: 1, output: "upgrade failed")
            }
        )

        do {
            try await installer.install(Self.availableUpdate(installSource: .homebrewCask))
            XCTFail("Expected install to throw")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                "Homebrew failed to upgrade Mac Runner: upgrade failed"
            )
        }
    }

    private static func availableUpdate(installSource: UpdateInstallSource) -> AvailableUpdate {
        AvailableUpdate(
            currentVersion: "1.0.0",
            latestVersion: "v1.2.0",
            releaseURL: URL(string: "https://github.com/omniaura/mac-runner/releases/tag/v1.2.0")!,
            installSource: installSource
        )
    }
}
