import XCTest
@testable import MacRunner

final class RunnerInstallerTests: XCTestCase {
    private func releaseData(tag: String) -> Data {
        Data(#"{"tag_name": "\#(tag)", "html_url": "https://github.com/actions/runner/releases/tag/\#(tag)"}"#.utf8)
    }

    func testFallbackVersionMeetsGitHubMinimumRunnerVersion() throws {
        let fallback = try XCTUnwrap(SemanticVersion(RunnerInstaller.fallbackRunnerVersion))
        let minimum = try XCTUnwrap(SemanticVersion("2.329.0"))
        XCTAssertGreaterThanOrEqual(fallback, minimum)
    }

    func testUsesLatestReleaseVersionWhenNewerThanFallback() {
        let version = RunnerInstaller.runnerVersion(fromLatestReleaseData: releaseData(tag: "v9.400.1"), statusCode: 200)
        XCTAssertEqual(version, "9.400.1")
    }

    func testFallsBackWhenLatestReleaseIsOlderThanFallback() {
        let version = RunnerInstaller.runnerVersion(fromLatestReleaseData: releaseData(tag: "v2.311.0"), statusCode: 200)
        XCTAssertEqual(version, RunnerInstaller.fallbackRunnerVersion)
    }

    func testFallsBackOnErrorStatusOrMalformedResponse() {
        XCTAssertEqual(
            RunnerInstaller.runnerVersion(fromLatestReleaseData: releaseData(tag: "v9.0.0"), statusCode: 403),
            RunnerInstaller.fallbackRunnerVersion
        )
        XCTAssertEqual(
            RunnerInstaller.runnerVersion(fromLatestReleaseData: Data("not json".utf8), statusCode: 200),
            RunnerInstaller.fallbackRunnerVersion
        )
        XCTAssertEqual(
            RunnerInstaller.runnerVersion(fromLatestReleaseData: releaseData(tag: "v9.0.0/../x"), statusCode: 200),
            RunnerInstaller.fallbackRunnerVersion
        )
    }

    func testDownloadURLMatchesActionsRunnerAssetNaming() {
        XCTAssertEqual(
            RunnerInstaller.downloadURL(version: "2.337.0", arch: "arm64"),
            "https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-osx-arm64-2.337.0.tar.gz"
        )
    }

    func testServiceUserShellSetsTargetUsersHome() {
        let arguments = UserIsolationService.sudoShellArguments(
            username: "_macrunner",
            shell: "/bin/zsh",
            command: "echo $HOME"
        )

        XCTAssertEqual(arguments, ["-n", "-H", "-u", "_macrunner", "/bin/zsh", "-l", "-c", "echo $HOME"])
    }
}

final class ServiceUserInstallCommandTests: XCTestCase {
    func testDownloadsAndExtractsRunnerAsServiceUser() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-\(UUID().uuidString)", isDirectory: true)
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let target = directory.appendingPathComponent("it's target", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for file in ["config.sh", "run.sh", "bin/Runner.Listener"] {
            try "#!/bin/sh\n".write(to: source.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let archive = directory.appendingPathComponent("runner.tar.gz")
        let tar = try ProcessExecutor.run("/usr/bin/tar", arguments: ["-czf", archive.path, "-C", source.path, "."])
        XCTAssertTrue(tar.succeeded, tar.output)

        let command = RunnerInstaller.serviceUserInstallCommand(
            directory: target.path,
            downloadURLs: ["file:///nonexistent/runner.tar.gz", archive.absoluteString]
        )
        let result = try ProcessExecutor.run("/bin/bash", arguments: ["-c", command])

        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.appendingPathComponent("bin/Runner.Listener").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("runner.tar.gz").path))
    }

    func testFailsWhenNoURLDownloads() throws {
        let command = RunnerInstaller.serviceUserInstallCommand(
            directory: FileManager.default.temporaryDirectory.path,
            downloadURLs: ["file:///nonexistent/runner.tar.gz"]
        )
        let result = try ProcessExecutor.run("/bin/bash", arguments: ["-c", command])
        XCTAssertFalse(result.succeeded)
    }
}

final class ServiceUserLaunchCommandTests: XCTestCase {
    func testHeadlessEnvironmentWrapsRunnerNotCd() throws {
        let command = UserIsolationService.launchCommand(directory: "/tmp", executable: "/usr/bin/env", enableGUI: false)
        XCTAssertTrue(command.hasPrefix("cd '/tmp' && env "))

        let result = try ProcessExecutor.run("/bin/bash", arguments: ["-c", command])
        XCTAssertTrue(result.output.contains("CI=true"), result.output)
        XCTAssertTrue(result.output.contains("HEADLESS=true"), result.output)
    }

    func testGUIModeLeavesEnvironmentAlone() {
        XCTAssertEqual(
            UserIsolationService.launchCommand(directory: "/it's", executable: "/run.sh", enableGUI: true),
            "cd '/it'\\''s' && '/run.sh'"
        )
    }
}

final class ProcessTreeKillTests: XCTestCase {
    func testKillCommandSignalsEveryPidAndIgnoresFailures() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()

        // 1 is launchd: not signallable, which must not stop the remaining kills.
        let command = ProcessUtils.killCommand(for: [1, sleeper.processIdentifier])
        let result = try ProcessExecutor.run("/bin/bash", arguments: ["-c", command])
        sleeper.waitUntilExit()

        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertEqual(sleeper.terminationReason, .uncaughtSignal)
        XCTAssertEqual(sleeper.terminationStatus, SIGTERM)
    }
}

final class ServiceUserInstallFallbackTests: XCTestCase {
    func testCorruptArchiveFallsThroughToNextURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("installer-\(UUID().uuidString)", isDirectory: true)
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let target = directory.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for file in ["config.sh", "run.sh", "bin/Runner.Listener"] {
            try "#!/bin/sh\n".write(to: source.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        let corrupt = directory.appendingPathComponent("corrupt.tar.gz")
        try Data("not a tarball".utf8).write(to: corrupt)
        let good = directory.appendingPathComponent("good.tar.gz")
        XCTAssertTrue(try ProcessExecutor.run("/usr/bin/tar", arguments: ["-czf", good.path, "-C", source.path, "."]).succeeded)

        let command = RunnerInstaller.serviceUserInstallCommand(
            directory: target.path,
            downloadURLs: [corrupt.absoluteString, good.absoluteString]
        )
        let result = try ProcessExecutor.run("/bin/bash", arguments: ["-c", command])

        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: target.appendingPathComponent("bin/Runner.Listener").path))
    }
}

final class ServiceUserLogCommandTests: XCTestCase {
    func testLogIsWritableOnlyByOwnerAndNamedWriter() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("runner.log").path

        let command = ProcessManager.serviceUserLogCommand(logFile: log, writer: NSUserName())
        let result = try ProcessExecutor.run("/bin/bash", arguments: ["-c", command + " && ls -le " + "'\(log)'"])

        XCTAssertTrue(result.succeeded, result.output)
        XCTAssertTrue(result.output.contains("-rw-r--r--+"), result.output)
        XCTAssertTrue(result.output.contains("user:\(NSUserName()) allow write,append"), result.output)
    }
}
