import XCTest
@testable import MacRunner

final class DiskCleanupServiceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testDryRunReportsSharedCacheWithoutRemovingIt() throws {
        let cacheFile = temporaryDirectory.appendingPathComponent(".cache/tool/artifact.bin")
        try FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 4096).write(to: cacheFile)

        let report = try DiskCleanupService(homeDirectory: temporaryDirectory).cleanup(
            runners: [],
            globalIsolationMode: .none,
            includeSharedCaches: true,
            dryRun: true
        )

        XCTAssertGreaterThan(report.reclaimedBytes, 0)
        XCTAssertEqual(report.removedPaths.count, 1)
        XCTAssertTrue(report.removedPaths[0].hasSuffix("/.cache/tool"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    func testCleanupRemovesSharedCacheContentsButKeepsCacheRoot() throws {
        let cacheRoot = temporaryDirectory.appendingPathComponent(".npm/_npx", isDirectory: true)
        let cacheFile = cacheRoot.appendingPathComponent("package/index.js")
        try FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cached".utf8).write(to: cacheFile)

        let report = try DiskCleanupService(homeDirectory: temporaryDirectory).cleanup(
            runners: [],
            globalIsolationMode: .none,
            includeSharedCaches: true,
            dryRun: false
        )

        XCTAssertEqual(report.removedPaths.count, 1)
        XCTAssertTrue(report.removedPaths[0].hasSuffix("/.npm/_npx/package"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFile.path))
    }

    func testActiveRunnerPreservesSharedCaches() throws {
        let cacheFile = temporaryDirectory.appendingPathComponent(".cache/tool/artifact.bin")
        try FileManager.default.createDirectory(
            at: cacheFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("cached".utf8).write(to: cacheFile)
        let runner = Runner(name: "busy-runner", repo: "owner/repo", status: .running, busy: true)

        let report = try DiskCleanupService(homeDirectory: temporaryDirectory).cleanup(
            runners: [runner],
            globalIsolationMode: .none,
            includeSharedCaches: true,
            dryRun: false
        )

        XCTAssertEqual(report.skippedRunnerNames, ["busy-runner"])
        XCTAssertTrue(report.removedPaths.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheFile.path))
    }
}
