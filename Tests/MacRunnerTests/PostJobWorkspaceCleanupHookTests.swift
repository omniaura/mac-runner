import XCTest
@testable import MacRunner

final class PostJobWorkspaceCleanupHookTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var runnerDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        runnerDirectory = temporaryDirectory
            .appendingPathComponent(".mac-runner/runners/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testSynchronizeInstallsExternalHookAndPreservesOtherEnvironmentValues() throws {
        let environmentFile = runnerDirectory.appendingPathComponent(".env")
        try "EXISTING_VALUE=preserved\n".write(to: environmentFile, atomically: true, encoding: .utf8)

        try PostJobWorkspaceCleanupHook.synchronize(
            runnerDirectory: runnerDirectory,
            isolation: .none,
            enabled: true,
            minimumFreeDiskSpaceGB: 150
        )

        let hookFile = temporaryDirectory.appendingPathComponent(".mac-runner/hooks/post-job-workspace-cleanup.sh")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hookFile.path))
        XCTAssertFalse(hookFile.path.hasPrefix(runnerDirectory.path + "/"))

        let environment = try String(contentsOf: environmentFile, encoding: .utf8)
        XCTAssertTrue(environment.contains("EXISTING_VALUE=preserved"))
        XCTAssertTrue(environment.contains("ACTIONS_RUNNER_HOOK_JOB_COMPLETED=\(hookFile.path)"))
        XCTAssertTrue(environment.contains("MAC_RUNNER_POST_JOB_CLEANUP_MINIMUM_FREE_GB=150"))
    }

    func testDisablingRemovesOnlyMacRunnerManagedEnvironmentValues() throws {
        let environmentFile = runnerDirectory.appendingPathComponent(".env")
        try "EXISTING_VALUE=preserved\nACTIONS_RUNNER_HOOK_JOB_COMPLETED=/old/hook.sh\nMAC_RUNNER_POST_JOB_CLEANUP_MINIMUM_FREE_GB=100\n".write(
            to: environmentFile,
            atomically: true,
            encoding: .utf8
        )

        try PostJobWorkspaceCleanupHook.synchronize(
            runnerDirectory: runnerDirectory,
            isolation: .none,
            enabled: false,
            minimumFreeDiskSpaceGB: 150
        )

        XCTAssertEqual(try String(contentsOf: environmentFile, encoding: .utf8), "EXISTING_VALUE=preserved\n")
    }

    func testHookCleansOnlyCompletedJobWorkspaceWhenUnderPressure() throws {
        let hookFile = try installHook()
        let runnerWorkspace = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        let completedJobRoot = runnerWorkspace.appendingPathComponent("repository", isDirectory: true)
        let completedCheckout = completedJobRoot.appendingPathComponent("repository", isDirectory: true)
        let retainedTemporaryData = runnerWorkspace.appendingPathComponent("_temp/keep.txt")
        try FileManager.default.createDirectory(at: completedCheckout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retainedTemporaryData.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("job artifact".utf8).write(to: completedCheckout.appendingPathComponent("artifact.txt"))
        try Data("runner temporary data".utf8).write(to: retainedTemporaryData)

        try runHook(
            hookFile,
            runnerWorkspace: runnerWorkspace,
            githubWorkspace: completedCheckout,
            minimumFreeSpaceGB: 999_999
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: completedJobRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: completedCheckout.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedTemporaryData.path))
    }

    func testHookLeavesWorkspaceOutsideRunnerWorkDirectoryUntouched() throws {
        let hookFile = try installHook()
        let runnerWorkspace = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        let externalWorkspace = temporaryDirectory.appendingPathComponent("elsewhere/repository", isDirectory: true)
        let externalFile = externalWorkspace.appendingPathComponent("artifact.txt")
        try FileManager.default.createDirectory(at: runnerWorkspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: externalWorkspace, withIntermediateDirectories: true)
        try Data("must keep".utf8).write(to: externalFile)

        try runHook(
            hookFile,
            runnerWorkspace: runnerWorkspace,
            githubWorkspace: externalWorkspace,
            minimumFreeSpaceGB: 999_999
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: externalFile.path))
    }

    func testHookKeepsCompletedWorkspaceWhenDiskTargetIsMet() throws {
        let hookFile = try installHook()
        let runnerWorkspace = temporaryDirectory.appendingPathComponent("work", isDirectory: true)
        let completedCheckout = runnerWorkspace.appendingPathComponent("repository/repository", isDirectory: true)
        let artifact = completedCheckout.appendingPathComponent("artifact.txt")
        try FileManager.default.createDirectory(at: completedCheckout, withIntermediateDirectories: true)
        try Data("must keep".utf8).write(to: artifact)

        try runHook(
            hookFile,
            runnerWorkspace: runnerWorkspace,
            githubWorkspace: completedCheckout,
            minimumFreeSpaceGB: 1
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path))
    }

    private func installHook() throws -> URL {
        try PostJobWorkspaceCleanupHook.synchronize(
            runnerDirectory: runnerDirectory,
            isolation: .none,
            enabled: true,
            minimumFreeDiskSpaceGB: 150
        )
        return temporaryDirectory.appendingPathComponent(".mac-runner/hooks/post-job-workspace-cleanup.sh")
    }

    private func runHook(
        _ hookFile: URL,
        runnerWorkspace: URL,
        githubWorkspace: URL,
        minimumFreeSpaceGB: Int
    ) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hookFile.path]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "RUNNER_WORKSPACE": runnerWorkspace.path,
            "GITHUB_WORKSPACE": githubWorkspace.path,
            "MAC_RUNNER_POST_JOB_CLEANUP_MINIMUM_FREE_GB": String(minimumFreeSpaceGB)
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
}
