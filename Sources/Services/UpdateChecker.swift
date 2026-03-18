import Foundation

struct SemanticVersion: Comparable, Sendable {
    let components: [Int]

    init?(_ rawValue: String) {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else { return nil }

        let withoutPrefix = trimmedValue.hasPrefix("v") || trimmedValue.hasPrefix("V")
            ? String(trimmedValue.dropFirst())
            : trimmedValue
        let coreVersion = withoutPrefix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true).first
        let parts = coreVersion?.split(separator: ".", omittingEmptySubsequences: false) ?? []

        guard !parts.isEmpty else { return nil }

        var parsedComponents: [Int] = []
        parsedComponents.reserveCapacity(parts.count)

        for part in parts {
            guard let value = Int(part) else { return nil }
            parsedComponents.append(value)
        }

        self.components = parsedComponents
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let maxCount = max(lhs.components.count, rhs.components.count)

        for index in 0..<maxCount {
            let lhsValue = index < lhs.components.count ? lhs.components[index] : 0
            let rhsValue = index < rhs.components.count ? rhs.components[index] : 0

            if lhsValue != rhsValue {
                return lhsValue < rhsValue
            }
        }

        return false
    }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }
}

enum UpdateInstallSource: Sendable, Equatable {
    case homebrewFormula
    case homebrewCask
    case directDownload
}

struct AvailableUpdate: Sendable, Equatable {
    let currentVersion: String
    let latestVersion: String
    let releaseURL: URL
    let installSource: UpdateInstallSource

    var actionTitle: String {
        switch installSource {
        case .homebrewFormula, .homebrewCask:
            return "Upgrade via Homebrew"
        case .directDownload:
            return "Open Release Page"
        }
    }

    var upgradeCommand: String? {
        switch installSource {
        case .homebrewFormula:
            return "brew upgrade mac-runner"
        case .homebrewCask:
            return "brew upgrade --cask mac-runner"
        case .directDownload:
            return nil
        }
    }

    var detailText: String {
        switch installSource {
        case .homebrewFormula:
            return "Use brew upgrade mac-runner"
        case .homebrewCask:
            return "Use brew upgrade --cask mac-runner"
        case .directDownload:
            return "Download the latest DMG from GitHub Releases"
        }
    }
}

enum UpdateCheckResult: Sendable, Equatable {
    case skipped(AvailableUpdate?)
    case upToDate
    case updateAvailable(AvailableUpdate)
}

struct HTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

@MainActor
final class UpdateChecker {
    typealias FetchLatestRelease = (URLRequest) async throws -> HTTPResponse

    private struct LatestRelease: Codable, Sendable {
        let tagName: String
        let htmlURL: URL

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    static let automaticCheckInterval: TimeInterval = 24 * 60 * 60
    static let responseCacheInterval: TimeInterval = 5 * 60

    private let userDefaults: UserDefaults
    private let now: () -> Date
    private let fetchLatestRelease: FetchLatestRelease
    private let owner: String
    private let repo: String

    private let lastCheckedAtKey = "updateChecker.lastCheckedAt"
    private let cachedResponseAtKey = "updateChecker.cachedResponseAt"
    private let cachedReleaseKey = "updateChecker.cachedRelease"

    init(
        userDefaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init,
        owner: String = "omniaura",
        repo: String = "mac-runner",
        fetchLatestRelease: @escaping FetchLatestRelease = UpdateChecker.liveFetch
    ) {
        self.userDefaults = userDefaults
        self.now = now
        self.owner = owner
        self.repo = repo
        self.fetchLatestRelease = fetchLatestRelease
    }

    func checkForUpdates(
        currentVersion: String,
        bundlePath: String,
        allowsAutomaticChecks: Bool,
        force: Bool = false
    ) async throws -> UpdateCheckResult {
        if let cachedRelease = cachedReleaseIfFresh() {
            return result(for: cachedRelease, currentVersion: currentVersion, bundlePath: bundlePath)
        }

        if !force {
            if !allowsAutomaticChecks {
                return .skipped(storedAvailableUpdate(currentVersion: currentVersion, bundlePath: bundlePath))
            }

            if recentlyCheckedWithinAutomaticWindow() {
                return .skipped(storedAvailableUpdate(currentVersion: currentVersion, bundlePath: bundlePath))
            }
        }

        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let checkedAt = now()

        do {
            let response = try await fetchLatestRelease(request)
            guard (200...299).contains(response.statusCode) else {
                throw NSError(
                    domain: "UpdateChecker",
                    code: response.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "GitHub update check failed with status \(response.statusCode)"]
                )
            }

            let latestRelease = try JSONDecoder().decode(LatestRelease.self, from: response.data)
            store(latestRelease, checkedAt: checkedAt)
            return result(for: latestRelease, currentVersion: currentVersion, bundlePath: bundlePath)
        } catch {
            storeFailedCheck(at: checkedAt)
            throw error
        }
    }

    func storedAvailableUpdate(currentVersion: String, bundlePath: String) -> AvailableUpdate? {
        guard let latestRelease = storedRelease() else { return nil }
        guard case .updateAvailable(let update) = result(for: latestRelease, currentVersion: currentVersion, bundlePath: bundlePath) else {
            return nil
        }
        return update
    }

    static func installSource(
        for bundlePath: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> UpdateInstallSource {
        if bundlePath.contains("/usr/local/Cellar/") || bundlePath.contains("/opt/homebrew/Cellar/") {
            return .homebrewFormula
        }

        if bundlePath.hasSuffix("/Mac Runner.app") {
            let caskReceipts = [
                "/opt/homebrew/Caskroom/mac-runner",
                "/usr/local/Caskroom/mac-runner"
            ]

            if caskReceipts.contains(where: fileExists) {
                return .homebrewCask
            }
        }

        return .directDownload
    }

    private func recentlyCheckedWithinAutomaticWindow() -> Bool {
        guard let lastCheckedAt = userDefaults.object(forKey: lastCheckedAtKey) as? Date else {
            return false
        }

        return now().timeIntervalSince(lastCheckedAt) < Self.automaticCheckInterval
    }

    private func cachedReleaseIfFresh() -> LatestRelease? {
        guard let cachedAt = userDefaults.object(forKey: cachedResponseAtKey) as? Date else {
            return nil
        }

        guard now().timeIntervalSince(cachedAt) < Self.responseCacheInterval else {
            return nil
        }

        return storedRelease()
    }

    private func storedRelease() -> LatestRelease? {
        guard let data = userDefaults.data(forKey: cachedReleaseKey) else {
            return nil
        }

        return try? JSONDecoder().decode(LatestRelease.self, from: data)
    }

    private func store(_ latestRelease: LatestRelease, checkedAt: Date) {
        userDefaults.set(checkedAt, forKey: lastCheckedAtKey)
        userDefaults.set(checkedAt, forKey: cachedResponseAtKey)
        userDefaults.set(try? JSONEncoder().encode(latestRelease), forKey: cachedReleaseKey)
    }

    private func storeFailedCheck(at checkedAt: Date) {
        userDefaults.set(checkedAt, forKey: lastCheckedAtKey)
    }

    private func result(for latestRelease: LatestRelease, currentVersion: String, bundlePath: String) -> UpdateCheckResult {
        guard let latestVersion = SemanticVersion(latestRelease.tagName) else {
            print("Warning: Failed to parse latest release version '\(latestRelease.tagName)' during update check")
            return .upToDate
        }

        guard let installedVersion = SemanticVersion(currentVersion) else {
            print("Warning: Failed to parse installed version '\(currentVersion)' during update check")
            return .upToDate
        }

        guard latestVersion > installedVersion else {
            return .upToDate
        }

        return .updateAvailable(
            AvailableUpdate(
                currentVersion: currentVersion,
                latestVersion: latestRelease.tagName,
                releaseURL: latestRelease.htmlURL,
                installSource: Self.installSource(for: bundlePath)
            )
        )
    }

    private static func liveFetch(request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        return HTTPResponse(data: data, statusCode: statusCode)
    }
}
