import XCTest
@testable import MacRunner

final class MacRunnerTests: XCTestCase {
    func testPlaceholder() {
        XCTAssertTrue(true)
    }

    func testEnablingLaunchAtLoginRegistersWhenSystemItemIsDisabled() {
        XCTAssertEqual(
            RunnerManager.loginItemAction(startOnLogin: true, isRegistered: false),
            .register
        )
    }

    func testDisablingLaunchAtLoginUnregistersWhenSystemItemIsEnabled() {
        XCTAssertEqual(
            RunnerManager.loginItemAction(startOnLogin: false, isRegistered: true),
            .unregister
        )
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

    func testRunnerEnvironmentPrependsHomebrewPathsToLaunchServicesPath() {
        let path = RunnerEnvironment.normalizedPath("/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin")

        XCTAssertTrue(path.hasPrefix("/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:"))
        XCTAssertEqual(path.components(separatedBy: ":").filter { $0 == "/usr/local/bin" }.count, 1)
    }

    func testRunnerEnvironmentMarksHeadlessRuns() {
        let environment = RunnerEnvironment.environment(
            from: [
                "PATH": "/usr/bin:/bin",
                "DISPLAY": ":0",
                "WAYLAND_DISPLAY": "wayland-0",
                "XDG_SESSION_TYPE": "x11",
                "XDG_RUNTIME_DIR": "/tmp/runtime",
            ],
            enableGUI: false
        )

        XCTAssertNil(environment["DISPLAY"])
        XCTAssertNil(environment["WAYLAND_DISPLAY"])
        XCTAssertNil(environment["XDG_SESSION_TYPE"])
        XCTAssertNil(environment["XDG_RUNTIME_DIR"])
        XCTAssertEqual(environment["CI"], "true")
        XCTAssertEqual(environment["HEADLESS"], "true")
        XCTAssertTrue(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    }

    func testRunnerEnvironmentPreservesGUIVariablesWhenEnabled() {
        let environment = RunnerEnvironment.environment(
            from: [
                "PATH": "/usr/bin:/bin",
                "DISPLAY": ":0",
            ],
            enableGUI: true
        )

        XCTAssertEqual(environment["DISPLAY"], ":0")
        XCTAssertNil(environment["CI"])
        XCTAssertNil(environment["HEADLESS"])
    }

    func testRunnerEnvironmentWritesPathSnapshot() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try RunnerEnvironment.writePathSnapshot(
            in: temporaryDirectory.path,
            environment: ["PATH": "/usr/bin:/bin"]
        )

        let written = try String(
            contentsOf: temporaryDirectory.appendingPathComponent(".path"),
            encoding: .utf8
        )
        XCTAssertEqual(
            written,
            "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin\n"
        )
    }

    func testRunnerEnvironmentDetectsMissingPathSnapshot() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        XCTAssertTrue(RunnerEnvironment.pathSnapshotNeedsRefresh(in: temporaryDirectory.path))
    }

    func testRunnerEnvironmentDetectsStalePathSnapshotMissingHomebrewEntries() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin\n".write(
            to: temporaryDirectory.appendingPathComponent(".path"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertTrue(RunnerEnvironment.pathSnapshotNeedsRefresh(in: temporaryDirectory.path))
    }

    func testRunnerEnvironmentAcceptsCurrentPathSnapshotWithPreferredEntries() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        try RunnerEnvironment.writePathSnapshot(
            in: temporaryDirectory.path,
            environment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertFalse(RunnerEnvironment.pathSnapshotNeedsRefresh(in: temporaryDirectory.path))
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
        XCTAssertTrue(settings.notificationsEnabled)
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

    func testGitHubAuthStateUsesDetailedAuthenticatedStatusOutput() {
        let state = GitHubAuthState.fromProcessResult(
            exitCode: 0,
            stdout: "",
            stderr: "Logged in to github.com as peyton"
        )

        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.statusMessage, "Logged in to github.com as peyton")
        XCTAssertEqual(state.recoveryMessage, "")
    }

    func testGitHubAuthStateBuildsActionableRecoveryMessage() {
        let state = GitHubAuthState.fromProcessResult(
            exitCode: 1,
            stdout: "",
            stderr: "Token in keychain has expired"
        )

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.statusMessage, "Token in keychain has expired")
        XCTAssertEqual(
            state.recoveryMessage,
            "GitHub authentication expired or is invalid. Run: gh auth login\nToken in keychain has expired"
        )
    }

    func testGitHubAuthStateFallsBackToGenericRecoveryMessageWithoutDetails() {
        let state = GitHubAuthState.fromProcessResult(exitCode: 1, stdout: "", stderr: "")

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.statusMessage, "gh CLI not found or not authenticated")
        XCTAssertEqual(state.recoveryMessage, "GitHub authentication expired or is invalid. Run: gh auth login")
    }

    func testRegistrationTokenFailureAddsAdminOrgRecoveryCommand() {
        let message = """
        gh: You must be an org admin or have the runners and runner groups fine-grained permission. (HTTP 403)
        This API operation needs the "admin:org" scope.
        """

        let recovery = GHCLIService.registrationTokenFailureMessage(from: message)

        XCTAssertTrue(GHCLIService.requiresAdminOrgScope(recovery))
        XCTAssertTrue(recovery.contains(GitHubAuthRecovery.adminOrgRefreshCommand))
        XCTAssertTrue(recovery.contains(message))
    }

    func testJobNotificationPayloadFactoryBuildsStartedPayload() {
        let runner = Runner(name: "runner-1", repo: "omniaura/mac-runner")
        let run = WorkflowRunSummary(
            id: 42,
            name: "CI",
            htmlURL: URL(string: "https://github.com/omniaura/mac-runner/actions/runs/42")!
        )
        let job = WorkflowJobSummary(
            id: 7,
            name: "build",
            status: "in_progress",
            conclusion: nil,
            runnerName: "runner-1",
            run: run
        )

        let payload = JobNotificationPayloadFactory.make(event: .started, runner: runner, job: job)

        XCTAssertEqual(payload.title, "Job started on runner-1")
        XCTAssertEqual(payload.body, "omniaura/mac-runner - CI")
        XCTAssertEqual(payload.runURL, run.htmlURL)
    }

    func testJobNotificationPayloadFactoryBuildsFailurePayload() {
        let runner = Runner(name: "runner-1", repo: "omniaura/mac-runner")
        let run = WorkflowRunSummary(
            id: 42,
            name: "Nightly",
            htmlURL: URL(string: "https://github.com/omniaura/mac-runner/actions/runs/42")!
        )
        let job = WorkflowJobSummary(
            id: 8,
            name: "test",
            status: "completed",
            conclusion: "failure",
            runnerName: "runner-1",
            run: run
        )

        let payload = JobNotificationPayloadFactory.make(event: .completed, runner: runner, job: job)

        XCTAssertEqual(payload.title, "Job failed on runner-1")
        XCTAssertEqual(payload.body, "omniaura/mac-runner - Nightly (failure)")
        XCTAssertEqual(payload.runURL, run.htmlURL)
    }

    func testRunnerManagerCurrentWorkflowHelpersPreferRunNameAndURL() {
        let runURL = URL(string: "https://github.com/omniaura/mac-runner/actions/runs/42")!
        let job = WorkflowJobSummary(
            id: 8,
            name: "test",
            status: "in_progress",
            conclusion: nil,
            runnerName: "runner-1",
            run: WorkflowRunSummary(id: 42, name: "Nightly", htmlURL: runURL)
        )

        XCTAssertEqual(RunnerManager.currentWorkflowDisplayName(from: job), "Nightly")
        XCTAssertEqual(RunnerManager.currentWorkflowRunURL(from: job), runURL)
    }

    func testRunnerManagerCurrentWorkflowHelpersFallBackToJobName() {
        let job = WorkflowJobSummary(
            id: 9,
            name: "integration",
            status: "in_progress",
            conclusion: nil,
            runnerName: "runner-1",
            run: WorkflowRunSummary(
                id: 43,
                name: "",
                htmlURL: URL(string: "https://github.com/omniaura/mac-runner/actions/runs/43")!
            )
        )

        XCTAssertEqual(RunnerManager.currentWorkflowDisplayName(from: job), "integration")
    }
}
