import Foundation

/// Parsed `mac-runner schedule` arguments.
enum ScheduleCommand: Equatable {
    case show
    case setGlobal(QuietHours)
    case disableGlobal
    case setRunner(name: String, QuietHours?)

    static let usage = """
    Usage:
      mac-runner schedule                                   Show quiet hours
      mac-runner schedule --start HH:mm --end HH:mm         Pause all runners daily in this window
      mac-runner schedule --off                             Turn global quiet hours off
      mac-runner schedule --runner <name> --start HH:mm --end HH:mm
      mac-runner schedule --runner <name> --never           Never pause this runner for quiet hours
      mac-runner schedule --runner <name> --global          Follow the global schedule
    """

    static func parse(_ args: [String]) -> Result<ScheduleCommand, CLIParseError> {
        var runner: String?
        var start: String?
        var end: String?
        var off = false
        var never = false
        var global = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--runner", "--start", "--end":
                guard i + 1 < args.count else { return .failure(.message("\(arg) requires a value")) }
                let value = args[i + 1]
                if arg == "--runner" {
                    runner = value
                } else {
                    guard let time = QuietHours.normalizedTime(value) else {
                        return .failure(.message("Invalid time '\(value)'. Use 24-hour HH:mm, e.g. 22:00"))
                    }
                    if arg == "--start" { start = time } else { end = time }
                }
                i += 2
            case "--off": off = true; i += 1
            case "--never": never = true; i += 1
            case "--global": global = true; i += 1
            default:
                return .failure(.message("Unknown option '\(arg)'"))
            }
        }

        let window: QuietHours?
        switch (start, end) {
        case let (start?, end?): window = QuietHours(enabled: true, start: start, end: end)
        case (nil, nil): window = nil
        default: return .failure(.message("--start and --end must be given together"))
        }

        let modes = [window != nil, off, never, global].filter { $0 }.count
        guard modes <= 1 else {
            return .failure(.message("Choose one of --start/--end, --off, --never, --global"))
        }

        if let runner {
            if let window { return .success(.setRunner(name: runner, window)) }
            if never { return .success(.setRunner(name: runner, QuietHours(enabled: false, start: "00:00", end: "00:00"))) }
            if global { return .success(.setRunner(name: runner, nil)) }
            return .failure(.message("--runner needs --start/--end, --never, or --global"))
        }

        if never || global { return .failure(.message("--never and --global apply to a single --runner")) }
        if let window { return .success(.setGlobal(window)) }
        if off { return .success(.disableGlobal) }
        return .success(.show)
    }
}

/// Parsed `mac-runner battery` arguments.
enum BatteryCommand: Equatable {
    case show
    case set(enabled: Bool?, threshold: Int?)

    static let usage = """
    Usage:
      mac-runner battery                          Show the low-battery pause setting
      mac-runner battery on|off [--threshold N]   Pause runners on battery below N% (default 20)
    """

    static func parse(_ args: [String]) -> Result<BatteryCommand, CLIParseError> {
        var enabled: Bool?
        var threshold: Int?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "on": enabled = true; i += 1
            case "off": enabled = false; i += 1
            case "--threshold":
                guard i + 1 < args.count, let value = Int(args[i + 1].trimmingCharacters(in: CharacterSet(charactersIn: "%"))) else {
                    return .failure(.message("--threshold requires a percentage"))
                }
                guard AppSettings.batteryPauseThresholdRange.contains(value) else {
                    let range = AppSettings.batteryPauseThresholdRange
                    return .failure(.message("Threshold must be between \(range.lowerBound) and \(range.upperBound)"))
                }
                threshold = value
                i += 2
            default:
                return .failure(.message("Unknown option '\(args[i])'"))
            }
        }

        if enabled == nil && threshold == nil { return .success(.show) }
        return .success(.set(enabled: enabled, threshold: threshold))
    }
}

enum CLIParseError: Error, Equatable {
    case message(String)

    var text: String {
        switch self {
        case .message(let text): return text
        }
    }
}
