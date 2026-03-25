import Foundation

struct Runner: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var repo: String  // Format: "owner/repo"
    var labels: [String]
    var enabled: Bool
    var status: RunnerStatus
    var githubRunnerId: Int?
    var busy: Bool  // Whether runner is currently executing a job
    var isolationMode: IsolationMode?  // Per-runner isolation override (nil = use global setting)
    var enableGUI: Bool  // Whether to enable GUI access for this runner (default: false, headless)
    var lastRestartEvent: String?
    var openFileLimit: Int?  // Per-runner override for max open files (nil = use global setting)

    init(
        id: UUID = UUID(),
        name: String,
        repo: String,
        labels: [String] = ["macos", "mac-runner"],
        enabled: Bool = true,
        status: RunnerStatus = .stopped,
        githubRunnerId: Int? = nil,
        busy: Bool = false,
        isolationMode: IsolationMode? = nil,
        enableGUI: Bool = false,
        lastRestartEvent: String? = nil,
        openFileLimit: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.repo = repo
        self.labels = labels
        self.enabled = enabled
        self.status = status
        self.githubRunnerId = githubRunnerId
        self.busy = busy
        self.isolationMode = isolationMode
        self.enableGUI = enableGUI
        self.lastRestartEvent = lastRestartEvent
        self.openFileLimit = ResourceLimits.normalizedOpenFileLimit(openFileLimit)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        repo = try container.decode(String.self, forKey: .repo)
        labels = try container.decode([String].self, forKey: .labels)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        status = try container.decode(RunnerStatus.self, forKey: .status)
        githubRunnerId = try container.decodeIfPresent(Int.self, forKey: .githubRunnerId)
        // Default busy to false for backward compatibility
        busy = try container.decodeIfPresent(Bool.self, forKey: .busy) ?? false
        // Per-runner isolation mode (added in v1.5.0)
        isolationMode = try container.decodeIfPresent(IsolationMode.self, forKey: .isolationMode)
        // Default GUI access to false (headless) for backward compatibility
        enableGUI = try container.decodeIfPresent(Bool.self, forKey: .enableGUI) ?? false
        // Default restart event to nil for backward compatibility
        lastRestartEvent = try container.decodeIfPresent(String.self, forKey: .lastRestartEvent)
        openFileLimit = ResourceLimits.normalizedOpenFileLimit(
            try container.decodeIfPresent(Int.self, forKey: .openFileLimit)
        )
    }

    /// Returns the effective isolation mode for this runner.
    ///
    /// If the runner has a specific isolation mode set, that is returned.
    /// Otherwise, falls back to the global app settings isolation mode.
    ///
    /// - Parameter globalMode: The global isolation mode from app settings.
    /// - Returns: The isolation mode to use for this runner.
    func effectiveIsolationMode(global globalMode: IsolationMode) -> IsolationMode {
        return isolationMode ?? globalMode
    }

    func effectiveOpenFileLimit(global globalLimit: Int) -> Int {
        openFileLimit ?? globalLimit
    }
}

enum RunnerStatus: String, Codable, Sendable {
    case running
    case stopped
    case paused
    case error

    var icon: String {
        switch self {
        case .running: return "●"
        case .stopped: return "○"
        case .paused: return "⏸"
        case .error: return "⚠️"
        }
    }

    var color: String {
        switch self {
        case .running: return "green"
        case .stopped: return "gray"
        case .paused: return "orange"
        case .error: return "red"
        }
    }
}

struct RunnerConfig: Codable, Sendable {
    var runners: [Runner]
    var settings: AppSettings

    static let `default` = RunnerConfig(
        runners: [],
        settings: .default
    )
}

enum IsolationMode: Codable, Sendable, Equatable {
    case none
    case dedicatedUser(username: String)
    case container  // Container isolation via Apple Containerization framework (macOS 26+)

    static let defaultUsername = "_macrunner"

    private enum CodingKeys: String, CodingKey {
        case type, username
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none:
            try container.encode("none", forKey: .type)
        case .dedicatedUser(let username):
            try container.encode("dedicatedUser", forKey: .type)
            try container.encode(username, forKey: .username)
        case .container:
            try container.encode("container", forKey: .type)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "dedicatedUser":
            let username = try container.decode(String.self, forKey: .username)
            self = .dedicatedUser(username: username)
        case "container":
            self = .container
        default:
            self = .none
        }
    }

    /// Returns a human-readable description of the isolation mode.
    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .dedicatedUser(let username):
            return "User (\(username))"
        case .container:
            return "Container"
        }
    }

    /// Returns an icon representing the isolation mode.
    var icon: String {
        switch self {
        case .none:
            return "🔓"
        case .dedicatedUser:
            return "👤"
        case .container:
            return "📦"
        }
    }
}

struct AppSettings: Codable, Sendable {
    var startOnLogin: Bool
    var pauseOnBattery: Bool
    var quietHours: QuietHours?
    var isolationMode: IsolationMode
    var tools: ToolProvisioningSettings
    var autoCheckForUpdates: Bool
    var autoRestartEnabled: Bool
    var autoRestartMaxRetries: Int
    var openFileLimit: Int

    static let `default` = AppSettings(
        startOnLogin: false,
        pauseOnBattery: false,
        quietHours: nil,
        isolationMode: .none,
        tools: .default,
        autoCheckForUpdates: true,
        autoRestartEnabled: true,
        autoRestartMaxRetries: 5,
        openFileLimit: ResourceLimits.defaultOpenFileLimit
    )

    init(
        startOnLogin: Bool = false,
        pauseOnBattery: Bool = false,
        quietHours: QuietHours? = nil,
        isolationMode: IsolationMode = .none,
        tools: ToolProvisioningSettings = .default,
        autoCheckForUpdates: Bool = true,
        autoRestartEnabled: Bool = true,
        autoRestartMaxRetries: Int = 5,
        openFileLimit: Int = ResourceLimits.defaultOpenFileLimit
    ) {
        self.startOnLogin = startOnLogin
        self.pauseOnBattery = pauseOnBattery
        self.quietHours = quietHours
        self.isolationMode = isolationMode
        self.tools = tools
        self.autoCheckForUpdates = autoCheckForUpdates
        self.autoRestartEnabled = autoRestartEnabled
        self.autoRestartMaxRetries = max(1, autoRestartMaxRetries)
        self.openFileLimit = ResourceLimits.normalizedOpenFileLimit(openFileLimit) ?? ResourceLimits.defaultOpenFileLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startOnLogin = try container.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? false
        pauseOnBattery = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? false
        quietHours = try container.decodeIfPresent(QuietHours.self, forKey: .quietHours)
        isolationMode = try container.decodeIfPresent(IsolationMode.self, forKey: .isolationMode) ?? .none
        tools = try container.decodeIfPresent(ToolProvisioningSettings.self, forKey: .tools) ?? .default
        autoCheckForUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckForUpdates) ?? true
        autoRestartEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoRestartEnabled) ?? true
        autoRestartMaxRetries = max(1, try container.decodeIfPresent(Int.self, forKey: .autoRestartMaxRetries) ?? 5)
        openFileLimit = ResourceLimits.normalizedOpenFileLimit(
            try container.decodeIfPresent(Int.self, forKey: .openFileLimit)
        ) ?? ResourceLimits.defaultOpenFileLimit
    }
}

struct ToolProvisioningSettings: Codable, Sendable, Equatable {
    var extraPackages: [String]

    static let `default` = ToolProvisioningSettings(extraPackages: [])

    init(extraPackages: [String] = []) {
        self.extraPackages = Self.normalize(extraPackages)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        extraPackages = Self.normalize(
            try container.decodeIfPresent([String].self, forKey: .extraPackages) ?? []
        )
    }

    private static func normalize(_ packages: [String]) -> [String] {
        let allowedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789@+._-")

        return Array(
            Set(
                packages.map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                }
                .filter {
                    !$0.isEmpty && $0.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
                }
            )
        )
        .sorted()
    }
}

struct QuietHours: Codable, Sendable {
    var enabled: Bool
    var start: String  // HH:mm format
    var end: String    // HH:mm format
}
