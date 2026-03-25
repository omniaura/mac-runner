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

    func testResourceLimitsShellCommandPrefixesUlimit() {
        let command = ResourceLimits.shellCommand("exec '/tmp/run.sh'", openFileLimit: 32768)

        XCTAssertTrue(command.contains("ulimit -n 32768"))
        XCTAssertTrue(command.hasSuffix("exec '/tmp/run.sh'"))
    }

    func testResourceLimitsShellCommandSkipsInvalidLimits() {
        XCTAssertEqual(ResourceLimits.shellCommand("echo test", openFileLimit: nil), "echo test")
        XCTAssertEqual(ResourceLimits.shellCommand("echo test", openFileLimit: 0), "echo test")
    }

    func testAdministratorAuthenticationProcessUsesInteractiveTerminalHandles() {
        let process = UserIsolationService.makeAdministratorAuthenticationProcess()

        XCTAssertEqual(process.executableURL?.path, "/usr/bin/sudo")
        XCTAssertEqual(process.arguments, ["-v"])
        XCTAssertNotNil(process.standardInput)
        XCTAssertNotNil(process.standardOutput)
        XCTAssertNotNil(process.standardError)
    }

    func testConfigServiceUsesInvokingUsersApplicationSupportWhenRunningUnderSudo() {
        let fallback = URL(fileURLWithPath: "/var/root/Library/Application Support")

        let appSupport = ConfigService.applicationSupportDirectory(
            effectiveUserID: 0,
            environment: ["SUDO_USER": "peyton"],
            fallback: fallback
        )

        XCTAssertEqual(appSupport.path, "/Users/peyton/Library/Application Support")
    }

    func testConfigServiceFallsBackToCurrentUsersApplicationSupportWithoutSudoUser() {
        let fallback = URL(fileURLWithPath: "/Users/current/Library/Application Support")

        let appSupport = ConfigService.applicationSupportDirectory(
            effectiveUserID: 0,
            environment: [:],
            fallback: fallback
        )

        XCTAssertEqual(appSupport, fallback)
    }

    func testConfigServiceDetectsInvokingUserOnlyForRootProcesses() {
        XCTAssertEqual(
            ConfigService.invokingUser(effectiveUserID: 0, environment: ["SUDO_USER": "peyton"]),
            "peyton"
        )
        XCTAssertNil(
            ConfigService.invokingUser(effectiveUserID: 501, environment: ["SUDO_USER": "peyton"])
        )
    }

    func testToolProvisioningPlanIncludesAlwaysOnDetectedAndConfiguredPackages() {
        let plan = ToolProvisioningService.plan(
            rootEntries: ["package.json", "requirements.txt", "Cargo.toml"],
            settings: ToolProvisioningSettings(extraPackages: ["jq", "gh", "jq"])
        )

        XCTAssertEqual(plan.packages, ["gh", "jq", "node", "python", "rust"])
    }

    func testToolProvisioningPlanHandlesCaseInsensitiveRepositoryMetadata() {
        let plan = ToolProvisioningService.plan(
            rootEntries: ["Gemfile", "GO.MOD", "PyProject.toml"],
            settings: .default
        )

        XCTAssertEqual(plan.packages, ["gh", "go", "python", "ruby"])
    }

    func testAppSettingsDefaultsToolProvisioningConfigWhenMissing() throws {
        let data = Data("""
        {
          "startOnLogin": true,
          "isolationMode": {
            "type": "none"
          }
        }
        """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.tools, .default)
    }

    func testToolProvisioningSettingsNormalizesExtraPackages() {
        let settings = ToolProvisioningSettings(extraPackages: [" jq ", "PNPM", "jq", "bad;rm", ""])

        XCTAssertEqual(settings.extraPackages, ["jq", "pnpm"])
    }

    func testGHCLIServiceDetectExecutablePathPrefersAvailableStandardLocations() {
        XCTAssertEqual(
            GHCLIService.detectExecutablePath(fileExists: { $0 == "/usr/local/bin/gh" }),
            "/usr/local/bin/gh"
        )
        XCTAssertEqual(
            GHCLIService.detectExecutablePath(fileExists: { _ in false }),
            "/opt/homebrew/bin/gh"
        )
    }
}
