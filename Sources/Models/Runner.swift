import Foundation

struct Runner: Identifiable, Codable {
    let id: UUID
    var name: String
    var repo: String  // Format: "owner/repo"
    var labels: [String]
    var enabled: Bool
    var status: RunnerStatus

    init(
        id: UUID = UUID(),
        name: String,
        repo: String,
        labels: [String] = ["macos"],
        enabled: Bool = true,
        status: RunnerStatus = .stopped
    ) {
        self.id = id
        self.name = name
        self.repo = repo
        self.labels = labels
        self.enabled = enabled
        self.status = status
    }
}

enum RunnerStatus: String, Codable {
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

struct RunnerConfig: Codable {
    var runners: [Runner]
    var settings: AppSettings

    static let `default` = RunnerConfig(
        runners: [],
        settings: .default
    )
}

struct AppSettings: Codable {
    var startOnLogin: Bool
    var pauseOnBattery: Bool
    var quietHours: QuietHours?

    static let `default` = AppSettings(
        startOnLogin: false,
        pauseOnBattery: false,
        quietHours: nil
    )
}

struct QuietHours: Codable {
    var enabled: Bool
    var start: String  // HH:mm format
    var end: String    // HH:mm format
}
