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

struct AppSettings: Codable, Sendable {
    var startOnLogin: Bool
    var pauseOnBattery: Bool
    var quietHours: QuietHours?

    static let `default` = AppSettings(
        startOnLogin: false,
        pauseOnBattery: false,
        quietHours: nil
    )
}

struct QuietHours: Codable, Sendable {
    var enabled: Bool
    var start: String  // HH:mm format
    var end: String    // HH:mm format
}
