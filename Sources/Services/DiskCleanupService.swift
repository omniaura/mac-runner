import Foundation

struct DiskCleanupReport: Equatable {
    let reclaimedBytes: Int64
    let removedPaths: [String]
    let skippedRunnerNames: [String]
    let dryRun: Bool
}

struct DiskCleanupService {
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func availableDiskBytes() -> Int64? {
        let values = try? homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func cleanup(
        runners: [Runner],
        globalIsolationMode: IsolationMode,
        includeSharedCaches: Bool,
        dryRun: Bool
    ) throws -> DiskCleanupReport {
        var candidates: [URL] = []
        var skipped: [String] = []

        for runner in runners {
            guard runner.status != .running && !runner.busy else {
                skipped.append(runner.name)
                continue
            }

            let isolation = runner.effectiveIsolationMode(global: globalIsolationMode)
            guard isolation != .container,
                  let runnerDirectory = try? RunnerDirectory.path(for: runner.id, isolation: isolation) else {
                continue
            }
            candidates.append(URL(fileURLWithPath: runnerDirectory).appendingPathComponent("_work", isDirectory: true))
        }

        // Shared caches can be in use by any job, so only touch them when every
        // configured runner is stopped and idle.
        if includeSharedCaches && skipped.isEmpty {
            candidates.append(contentsOf: sharedCICacheDirectories())
        }

        var reclaimedBytes: Int64 = 0
        var removedPaths: [String] = []
        for directory in candidates where fileManager.fileExists(atPath: directory.path) {
            let children = (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )) ?? []

            for child in children {
                reclaimedBytes += allocatedSize(of: child)
                removedPaths.append(child.path)
                if !dryRun {
                    try fileManager.removeItem(at: child)
                }
            }
        }

        return DiskCleanupReport(
            reclaimedBytes: reclaimedBytes,
            removedPaths: removedPaths.sorted(),
            skippedRunnerNames: skipped.sorted(),
            dryRun: dryRun
        )
    }

    private func sharedCICacheDirectories() -> [URL] {
        [
            homeDirectory.appendingPathComponent(".cache", isDirectory: true),
            homeDirectory.appendingPathComponent(".npm/_cacache", isDirectory: true),
            homeDirectory.appendingPathComponent(".npm/_npx", isDirectory: true),
            homeDirectory.appendingPathComponent(".cargo/registry/cache", isDirectory: true),
            homeDirectory.appendingPathComponent(".cargo/git", isDirectory: true),
            homeDirectory.appendingPathComponent(".gradle/caches", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/go-build", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Caches/org.swift.swiftpm", isDirectory: true),
            homeDirectory.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true)
        ]
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
        return total
    }
}
