import XCTest
@testable import MacRunner

final class UninstallServiceTests: XCTestCase {
    private var home: URL!
    private var applications: URL!
    private var binDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("uninstall-tests-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        applications = root.appendingPathComponent("Applications", isDirectory: true)
        binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        for url in [home, applications, binDirectory] {
            try FileManager.default.createDirectory(at: url!, withIntermediateDirectories: true)
        }
        // TMPDIR lives under /var, a symlink to /private/var. Resolve once so expected
        // paths match the canonical form the service reports.
        home = home.resolvingSymlinksInPath()
        applications = applications.resolvingSymlinksInPath()
        binDirectory = binDirectory.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        let root = home.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeService() -> UninstallService {
        UninstallService(
            homeDirectory: home,
            applicationsDirectory: applications,
            cliSymlinkDirectories: [binDirectory]
        )
    }

    @discardableResult
    private func writeFile(_ relativePath: String, bytes: Int = 1024) throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    /// Create a runner workspace with a file inside so it has non-zero size.
    @discardableResult
    private func makeWorkspace(id: UUID, bytes: Int = 4096) throws -> URL {
        let url = home
            .appendingPathComponent(".mac-runner/runners/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent("_work", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x42, count: bytes)
            .write(to: url.appendingPathComponent("_work/blob.bin"))
        return url
    }

    private func makeRunner(id: UUID = UUID(), name: String = "r", githubRunnerId: Int? = 1) -> Runner {
        Runner(id: id, name: name, repo: "owner/repo", githubRunnerId: githubRunnerId)
    }

    // MARK: - Orphan discovery

    func testOrphanedWorkspacesFindsDirectoriesMissingFromConfig() throws {
        let configured = UUID()
        let orphan = UUID()
        try makeWorkspace(id: configured)
        try makeWorkspace(id: orphan)

        let orphans = makeService().orphanedWorkspaces(
            runners: [makeRunner(id: configured)],
            globalIsolationMode: .none
        )

        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.path, home.appendingPathComponent(
            ".mac-runner/runners/\(orphan.uuidString)", isDirectory: true).path)
        XCTAssertEqual(orphans.first?.category, .orphanedWorkspace)
        XCTAssertGreaterThan(orphans.first?.bytes ?? 0, 0)
    }

    /// An empty config with directories still on disk is the exact state left behind by
    /// builds that removed runners without deleting their workspaces.
    func testOrphanedWorkspacesFindsEverythingWhenConfigIsEmpty() throws {
        try makeWorkspace(id: UUID())
        try makeWorkspace(id: UUID())
        try makeWorkspace(id: UUID())

        let orphans = makeService().orphanedWorkspaces(runners: [], globalIsolationMode: .none)

        XCTAssertEqual(orphans.count, 3)
    }

    func testOrphanedWorkspacesIgnoresNonUUIDEntries() throws {
        try makeWorkspace(id: UUID())
        try writeFile(".mac-runner/runners/README.txt")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".mac-runner/runners/not-a-uuid", isDirectory: true),
            withIntermediateDirectories: true
        )

        let orphans = makeService().orphanedWorkspaces(runners: [], globalIsolationMode: .none)

        XCTAssertEqual(orphans.count, 1)
        XCTAssertFalse(orphans.contains { $0.path.hasSuffix("not-a-uuid") })
    }

    // MARK: - Planning

    func testPlanIncludesWorkspacesSupportFilesAndPreferences() throws {
        let id = UUID()
        try makeWorkspace(id: id)
        try writeFile("Library/Application Support/MacRunner/config.json")
        try writeFile("Library/Preferences/com.omniaura.mac-runner.plist")
        try writeFile("Library/Preferences/mac-runner.plist")
        try writeFile("Library/HTTPStorages/com.omniaura.mac-runner/cache.db")
        try writeFile("Library/Application Support/CrashReporter/MacRunner_ABC.plist")
        try writeFile("Library/Application Support/CrashReporter/mac-runner_DEF.plist")
        try writeFile("Library/Logs/DiagnosticReports/mac-runner-2026-01-01-120000.ips")

        let plan = makeService().plan(
            runners: [makeRunner(id: id)],
            globalIsolationMode: .none,
            includeApplication: false
        )

        let paths = plan.items.map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix(".mac-runner/runners/\(id.uuidString)") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Application Support/MacRunner") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Preferences/com.omniaura.mac-runner.plist") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/Preferences/mac-runner.plist") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("Library/HTTPStorages/com.omniaura.mac-runner") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("CrashReporter/MacRunner_ABC.plist") })
        // The CLI and the GUI app produce differently-spelled crash reports.
        XCTAssertTrue(paths.contains { $0.hasSuffix("CrashReporter/mac-runner_DEF.plist") })
        XCTAssertTrue(paths.contains { $0.hasSuffix("mac-runner-2026-01-01-120000.ips") })
        XCTAssertGreaterThan(plan.totalBytes, 0)
    }

    func testPlanIgnoresOtherAppsCrashReports() throws {
        try writeFile("Library/Application Support/CrashReporter/Xcode_ABC.plist")
        try writeFile("Library/Logs/DiagnosticReports/Safari-2026-01-01-120000.ips")

        let plan = makeService().plan(runners: [], globalIsolationMode: .none, includeApplication: false)

        XCTAssertTrue(plan.isEmpty)
    }

    func testPlanIsEmptyOnCleanMachine() {
        let plan = makeService().plan(
            runners: [],
            globalIsolationMode: .none,
            includeApplication: true
        )

        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.totalBytes, 0)
    }

    func testPlanExcludesApplicationUnlessRequested() throws {
        try FileManager.default.createDirectory(
            at: applications.appendingPathComponent("MacRunner.app", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeFile("Library/Preferences/com.omniaura.mac-runner.plist")

        let service = makeService()

        let without = service.plan(runners: [], globalIsolationMode: .none, includeApplication: false)
        XCTAssertFalse(without.items.contains { $0.category == .application })

        let with = service.plan(runners: [], globalIsolationMode: .none, includeApplication: true)
        XCTAssertTrue(with.items.contains { $0.path.hasSuffix("MacRunner.app") })
    }

    func testPlanReportsRunnersNeedingDeregistrationAndActiveRunners() throws {
        let idle = makeRunner(id: UUID(), name: "idle", githubRunnerId: 7)
        var active = makeRunner(id: UUID(), name: "active", githubRunnerId: 8)
        active.status = .running
        let unregistered = makeRunner(id: UUID(), name: "local", githubRunnerId: nil)
        try writeFile("Library/Preferences/com.omniaura.mac-runner.plist")

        let plan = makeService().plan(
            runners: [idle, active, unregistered],
            globalIsolationMode: .none,
            includeApplication: false
        )

        XCTAssertEqual(plan.runnersToDeregister.map(\.name).sorted(), ["active", "idle"])
        XCTAssertEqual(plan.activeRunnerNames, ["active"])
    }

    func testPlanDoesNotDuplicateConfiguredWorkspaceAsOrphan() throws {
        let id = UUID()
        try makeWorkspace(id: id)

        let plan = makeService().plan(
            runners: [makeRunner(id: id)],
            globalIsolationMode: .none,
            includeApplication: false
        )

        let matching = plan.items.filter { $0.path.hasSuffix(id.uuidString) }
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.category, .runnerWorkspace)
    }

    // MARK: - Execution

    func testExecuteRemovesEverythingInPlan() throws {
        let id = UUID()
        let workspace = try makeWorkspace(id: id)
        let prefs = try writeFile("Library/Preferences/com.omniaura.mac-runner.plist")
        let service = makeService()

        let plan = service.plan(runners: [makeRunner(id: id)], globalIsolationMode: .none, includeApplication: false)
        let report = service.execute(plan: plan, dryRun: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prefs.path))
        XCTAssertTrue(report.failedPaths.isEmpty)
        XCTAssertGreaterThan(report.reclaimedBytes, 0)
        XCTAssertFalse(report.dryRun)
    }

    func testDryRunDeletesNothing() throws {
        let id = UUID()
        let workspace = try makeWorkspace(id: id)
        let service = makeService()

        let plan = service.plan(runners: [makeRunner(id: id)], globalIsolationMode: .none, includeApplication: false)
        let report = service.execute(plan: plan, dryRun: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertTrue(report.dryRun)
        XCTAssertEqual(report.removedPaths.count, plan.items.count)
        XCTAssertGreaterThan(report.reclaimedBytes, 0)
    }

    /// `~/.mac-runner` should not survive as an empty shell after a full uninstall.
    func testExecuteRemovesEmptyStorageRoot() throws {
        let id = UUID()
        try makeWorkspace(id: id)
        let service = makeService()

        let plan = service.plan(runners: [makeRunner(id: id)], globalIsolationMode: .none, includeApplication: false)
        _ = service.execute(plan: plan, dryRun: false)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: home.appendingPathComponent(".mac-runner").path)
        )
    }

    /// Anything the user put under `~/.mac-runner` themselves must survive.
    func testExecuteKeepsStorageRootWhenUnknownFilesRemain() throws {
        let id = UUID()
        try makeWorkspace(id: id)
        try writeFile(".mac-runner/notes.txt")
        let service = makeService()

        let plan = service.plan(runners: [makeRunner(id: id)], globalIsolationMode: .none, includeApplication: false)
        _ = service.execute(plan: plan, dryRun: false)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: home.appendingPathComponent(".mac-runner/notes.txt").path)
        )
    }

    func testExecuteReportsPathsItCouldNotRemove() {
        let missing = home.appendingPathComponent(".mac-runner/runners/\(UUID().uuidString)").path
        let plan = UninstallPlan(
            items: [UninstallItem(path: missing, category: .orphanedWorkspace, bytes: 10)],
            runnersToDeregister: [],
            activeRunnerNames: []
        )

        let report = makeService().execute(plan: plan, dryRun: false)

        XCTAssertEqual(report.failedPaths, [missing])
        XCTAssertTrue(report.removedPaths.isEmpty)
        XCTAssertEqual(report.reclaimedBytes, 0)
    }

    func testExecutePassesThroughDeregistrationResults() {
        let plan = UninstallPlan(items: [], runnersToDeregister: [], activeRunnerNames: [])

        let report = makeService().execute(
            plan: plan,
            dryRun: false,
            deregistered: ["b", "a"],
            failedDeregistrations: ["c"]
        )

        XCTAssertEqual(report.deregisteredRunners, ["a", "b"])
        XCTAssertEqual(report.failedDeregistrations, ["c"])
    }

    // MARK: - Safety

    func testSudoRemovalRefusesPathsOutsideRunnerStorage() {
        XCTAssertThrowsError(
            try RunnerDirectory.removeDirectoryWithSudo(at: "/Users/someone/Documents")
        ) { error in
            guard case RunnerDirectoryError.refusedUnsafeRemoval = error else {
                return XCTFail("Expected refusedUnsafeRemoval, got \(error)")
            }
        }
    }

    func testDirectoryURLDoesNotCreateDirectory() {
        let id = UUID()
        let url = RunnerDirectory.directoryURL(for: id, isolation: .none)

        XCTAssertTrue(url.path.hasSuffix(".mac-runner/runners/\(id.uuidString)"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
