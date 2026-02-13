import Foundation

struct Runner: Identifiable, Codable, Sendable {
    let id: UUID
    var name: String
    var repo: String  // Format: "owner/repo"
    var labels: [String]
    var enabled: Bool
    var status: RunnerStatus
    var githubRunnerId: Int?

    init(
        id: UUID = UUID(),
        name: String,
        repo: String,
        labels: [String] = ["macos", "mac-runner"],
        enabled: Bool = true,
        status: RunnerStatus = .stopped,
        githubRunnerId: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.repo = repo
        self.labels = labels
        self.enabled = enabled
        self.status = status
        self.githubRunnerId = githubRunnerId
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
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "dedicatedUser":
            let username = try container.decode(String.self, forKey: .username)
            self = .dedicatedUser(username: username)
        default:
            self = .none
        }
    }
}

struct AppSettings: Codable, Sendable {
    var startOnLogin: Bool
    var pauseOnBattery: Bool
    var quietHours: QuietHours?
    var isolationMode: IsolationMode

    static let `default` = AppSettings(
        startOnLogin: false,
        pauseOnBattery: false,
        quietHours: nil,
        isolationMode: .none
    )

    init(startOnLogin: Bool = false, pauseOnBattery: Bool = false, quietHours: QuietHours? = nil, isolationMode: IsolationMode = .none) {
        self.startOnLogin = startOnLogin
        self.pauseOnBattery = pauseOnBattery
        self.quietHours = quietHours
        self.isolationMode = isolationMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startOnLogin = try container.decodeIfPresent(Bool.self, forKey: .startOnLogin) ?? false
        pauseOnBattery = try container.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? false
        quietHours = try container.decodeIfPresent(QuietHours.self, forKey: .quietHours)
        isolationMode = try container.decodeIfPresent(IsolationMode.self, forKey: .isolationMode) ?? .none
    }
}

struct QuietHours: Codable, Sendable {
    var enabled: Bool
    var start: String  // HH:mm format
    var end: String    // HH:mm format
}
