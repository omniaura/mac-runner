import Foundation

/// A single filesystem location owned by Mac Runner.
struct UninstallItem: Equatable {
    enum Category: String, Equatable {
        case runnerWorkspace = "runner workspace"
        case orphanedWorkspace = "orphaned workspace"
        case configuration = "configuration"
        case preferences = "preferences"
        case cache = "cache"
        case application = "application"
    }

    let path: String
    let category: Category
    let bytes: Int64
    /// Workspaces owned by a dedicated service user need sudo to delete.
    let requiresSudo: Bool

    init(path: String, category: Category, bytes: Int64 = 0, requiresSudo: Bool = false) {
        self.path = path
        self.category = category
        self.bytes = bytes
        self.requiresSudo = requiresSudo
    }
}

struct UninstallPlan {
    let items: [UninstallItem]
    /// Runners still registered with GitHub that should be deregistered first.
    let runnersToDeregister: [Runner]
    /// Runners that are still running and must be stopped before removal.
    let activeRunnerNames: [String]

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var isEmpty: Bool { items.isEmpty && runnersToDeregister.isEmpty }
}

struct UninstallReport: Equatable {
    let removedPaths: [String]
    let failedPaths: [String]
    let deregisteredRunners: [String]
    let failedDeregistrations: [String]
    let reclaimedBytes: Int64
    let dryRun: Bool
}

/// Enumerates and removes everything Mac Runner writes to disk.
///
/// `DiskCleanupService` reclaims space from runners that are still configured; this
/// service is the teardown counterpart. It deliberately discovers workspaces from the
/// filesystem as well as from config, because a workspace outlives its config entry if
/// it was removed by an older build (or if config.json was reset), and those orphans are
/// otherwise invisible to every other code path.
struct UninstallService {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let applicationsDirectory: URL
    private let cliSymlinkDirectories: [URL]

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationsDirectory: URL = URL(fileURLWithPath: "/Applications"),
        cliSymlinkDirectories: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin")
        ]
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.applicationsDirectory = applicationsDirectory
        self.cliSymlinkDirectories = cliSymlinkDirectories
    }

    // MARK: - Planning

    /// Build the full list of Mac Runner artifacts present on this machine.
    ///
    /// Only paths that actually exist are returned, so an empty plan means a clean machine.
    func plan(
        runners: [Runner],
        globalIsolationMode: IsolationMode,
        includeApplication: Bool
    ) -> UninstallPlan {
        var items: [UninstallItem] = []

        // Per-runner workspaces, including any under a dedicated service user's home.
        var seenWorkspaces = Set<String>()
        for runner in runners {
            let isolation = runner.effectiveIsolationMode(global: globalIsolationMode)
            let url = RunnerDirectory.directoryURL(for: runner.id, isolation: isolation, currentHome: homeDirectory)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            seenWorkspaces.insert(canonicalPath(url))
            items.append(
                UninstallItem(
                    path: canonicalPath(url),
                    category: .runnerWorkspace,
                    bytes: allocatedSize(of: url),
                    requiresSudo: isRemovableOnlyWithSudo(isolation)
                )
            )
        }

        // Workspaces on disk that no longer have a config entry.
        for orphan in orphanedWorkspaces(runners: runners, globalIsolationMode: globalIsolationMode)
        where !seenWorkspaces.contains(canonicalPath(URL(fileURLWithPath: orphan.path))) {
            items.append(orphan)
        }

        // Support, preference and cache locations.
        for url in supportLocations() where fileManager.fileExists(atPath: url.path) {
            items.append(
                UninstallItem(path: canonicalPath(url), category: category(for: url), bytes: allocatedSize(of: url))
            )
        }

        for url in crashReports() {
            items.append(UninstallItem(path: canonicalPath(url), category: .cache, bytes: allocatedSize(of: url)))
        }

        if includeApplication {
            for url in applicationLocations() where fileExistsAllowingSymlink(url) {
                items.append(
                    UninstallItem(path: canonicalPath(url), category: .application, bytes: allocatedSize(of: url))
                )
            }
        }

        let toDeregister = runners.filter { $0.githubRunnerId != nil }
        let active = runners.filter { $0.status == .running || $0.busy }.map(\.name).sorted()

        return UninstallPlan(
            items: removingNestedPaths(items),
            runnersToDeregister: toDeregister,
            activeRunnerNames: active
        )
    }

    /// Runner workspaces present on disk with no matching entry in config.
    ///
    /// These accumulate from builds that removed a runner without deleting its directory.
    func orphanedWorkspaces(
        runners: [Runner],
        globalIsolationMode: IsolationMode
    ) -> [UninstallItem] {
        let configured = Set(runners.map { $0.id.uuidString.lowercased() })

        var isolations: [IsolationMode] = [.none]
        if case .dedicatedUser = globalIsolationMode { isolations.append(globalIsolationMode) }
        for runner in runners {
            let mode = runner.effectiveIsolationMode(global: globalIsolationMode)
            if case .dedicatedUser = mode, !isolations.contains(mode) { isolations.append(mode) }
        }

        var results: [UninstallItem] = []
        var seen = Set<String>()
        for isolation in isolations {
            let base = RunnerDirectory.baseDirectory(isolation: isolation, currentHome: homeDirectory)
            let children = (try? fileManager.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

            for child in children {
                let name = child.lastPathComponent
                // Only ever consider UUID-named directories, so a stray file is left alone.
                guard UUID(uuidString: name) != nil,
                      !configured.contains(name.lowercased()),
                      seen.insert(canonicalPath(child)).inserted else { continue }

                results.append(
                    UninstallItem(
                        path: canonicalPath(child),
                        category: .orphanedWorkspace,
                        bytes: allocatedSize(of: child),
                        requiresSudo: isRemovableOnlyWithSudo(isolation)
                    )
                )
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    // MARK: - Execution

    /// Delete every path in the plan. Deregistration is handled by the caller.
    func execute(
        plan: UninstallPlan,
        dryRun: Bool,
        deregistered: [String] = [],
        failedDeregistrations: [String] = []
    ) -> UninstallReport {
        var removed: [String] = []
        var failed: [String] = []
        var reclaimed: Int64 = 0

        for item in plan.items {
            if dryRun {
                removed.append(item.path)
                reclaimed += item.bytes
                continue
            }

            do {
                if item.requiresSudo {
                    try RunnerDirectory.removeDirectoryWithSudo(at: item.path)
                } else {
                    try fileManager.removeItem(atPath: item.path)
                }
                removed.append(item.path)
                reclaimed += item.bytes
            } catch {
                failed.append(item.path)
            }
        }

        // The parent tree is only removed once its children are gone, and only if
        // nothing unexpected is left inside it.
        if !dryRun {
            removeEmptyStorageRoots()
        }

        return UninstallReport(
            removedPaths: removed.sorted(),
            failedPaths: failed.sorted(),
            deregisteredRunners: deregistered.sorted(),
            failedDeregistrations: failedDeregistrations.sorted(),
            reclaimedBytes: reclaimed,
            dryRun: dryRun
        )
    }

    /// True when Mac Runner appears to have been installed with `brew install --cask`.
    ///
    /// Homebrew tracks the app bundle it placed, so removing it by hand leaves brew's
    /// metadata inconsistent; callers surface `brew uninstall` instead.
    func isHomebrewManaged() -> Bool {
        let caskRoots = [
            "/opt/homebrew/Caskroom/mac-runner",
            "/usr/local/Caskroom/mac-runner"
        ]
        return caskRoots.contains { fileManager.fileExists(atPath: $0) }
    }

    // MARK: - Locations

    private func supportLocations() -> [URL] {
        // `~/.mac-runner` is deliberately absent: its workspaces are enumerated one by one
        // so that anything a user stored alongside them survives. The root itself is
        // removed by `removeEmptyStorageRoots()` once it holds nothing.
        var urls = [
            homeDirectory.appendingPathComponent("Library/Application Support/MacRunner", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Preferences/com.omniaura.mac-runner.plist"),
            // The CLI writes update-check state under its own bare domain.
            homeDirectory.appendingPathComponent("Library/Preferences/mac-runner.plist"),
            homeDirectory.appendingPathComponent("Library/Caches/com.omniaura.mac-runner", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/mac-runner", isDirectory: true),
            homeDirectory.appendingPathComponent(
                "Library/Saved Application State/com.omniaura.mac-runner.savedState",
                isDirectory: true
            )
        ]

        // URLSession writes cached update-check responses under several bundle spellings.
        for name in ["com.omniaura.mac-runner", "mac-runner", "MacRunner"] {
            urls.append(homeDirectory.appendingPathComponent("Library/HTTPStorages/\(name)", isDirectory: true))
            urls.append(homeDirectory.appendingPathComponent("Library/HTTPStorages/\(name).binarycookies"))
        }
        return urls
    }

    private func crashReports() -> [URL] {
        // CrashReporter names files after the executable, so the GUI app writes
        // `MacRunner_*.plist` while the CLI writes `mac-runner_*.plist`. Diagnostic
        // reports use a dash instead of an underscore.
        let directories = [
            ("Library/Application Support/CrashReporter", ["MacRunner_", "mac-runner_"]),
            ("Library/Logs/DiagnosticReports", ["MacRunner-", "mac-runner-"])
        ]

        var results: [URL] = []
        for (relativePath, prefixes) in directories {
            let directory = homeDirectory.appendingPathComponent(relativePath, isDirectory: true)
            let children = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []
            results.append(contentsOf: children.filter { child in
                prefixes.contains { child.lastPathComponent.hasPrefix($0) }
            })
        }
        return results.sorted { $0.path < $1.path }
    }

    private func applicationLocations() -> [URL] {
        var urls = [applicationsDirectory.appendingPathComponent("MacRunner.app", isDirectory: true)]
        urls.append(contentsOf: cliSymlinkDirectories.map { $0.appendingPathComponent("mac-runner") })
        return urls
    }

    private func category(for url: URL) -> UninstallItem.Category {
        let path = url.path
        if path.hasSuffix(".plist") && path.contains("/Preferences/") { return .preferences }
        if path.contains("/Caches/") || path.contains("/HTTPStorages/") { return .cache }
        if path.contains("/Saved Application State/") { return .cache }
        return .configuration
    }

    /// Remove `~/.mac-runner` and its `runners` child once they hold nothing.
    private func removeEmptyStorageRoots() {
        let root = homeDirectory.appendingPathComponent(".mac-runner", isDirectory: true)
        for url in [root.appendingPathComponent("runners", isDirectory: true), root] {
            let contents = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
            let meaningful = contents.filter { $0 != ".DS_Store" }
            guard fileManager.fileExists(atPath: url.path), meaningful.isEmpty else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Drop any item already covered by an ancestor in the same list.
    ///
    /// Removing a parent first would make every nested entry fail as "not found" and
    /// misreport the reclaimed total, so overlaps are collapsed before execution.
    private func removingNestedPaths(_ items: [UninstallItem]) -> [UninstallItem] {
        let sorted = items.sorted { $0.path < $1.path }
        var kept: [UninstallItem] = []
        for item in sorted {
            if let last = kept.last, item.path == last.path || item.path.hasPrefix(last.path + "/") {
                continue
            }
            kept.append(item)
        }
        return kept
    }

    /// Normalise a path for comparison without dereferencing its final component.
    ///
    /// `/var` is a symlink to `/private/var` on macOS, so a home resolved one way will not
    /// string-match the same directory resolved the other. Only the parent is resolved:
    /// resolving the whole path would turn the `mac-runner` CLI symlink into the app binary
    /// it points at, and deleting that would gut the app bundle instead of the symlink.
    private func canonicalPath(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        return parent.appendingPathComponent(url.lastPathComponent).standardizedFileURL.path
    }

    private func isRemovableOnlyWithSudo(_ isolation: IsolationMode) -> Bool {
        if case .dedicatedUser = isolation { return true }
        return false
    }

    /// `fileExists` follows symlinks, which reports false for the dangling CLI symlink
    /// left behind when the app bundle is deleted first.
    private func fileExistsAllowingSymlink(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
            || (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func allocatedSize(of url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            return Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        var total: Int64 = 0
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }

        if total == 0 {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
