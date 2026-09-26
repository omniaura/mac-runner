import Foundation
import Yams

/// A declarative description of the runners (and a few global settings) a Mac
/// should have — `.mac-runner.yml` — applied with `mac-runner apply`.
///
/// ```yaml
/// version: 1
/// settings:
///   isolation: user
///   quiet-hours: { start: "22:00", end: "06:00" }
/// runners:
///   - name: mac-runner-ci
///     repo: omniaura/mac-runner
///     labels: [macos, swift]
///     count: 2            # mac-runner-ci-1, mac-runner-ci-2
///   - name: org-builder
///     org: omniaura
///     isolation: container
///     enable-gui: false
///     open-files: 65536
///     quiet-hours: never
/// ```
struct DeclarativeConfig: Codable, Equatable {
    var version: Int?
    var settings: SettingsSpec?
    var runners: [RunnerSpec]

    struct SettingsSpec: Codable, Equatable {
        var isolation: String?
        var quietHours: QuietHoursSpec?
        var pauseOnBattery: Bool?
        var batteryThreshold: Int?

        enum CodingKeys: String, CodingKey {
            case isolation
            case quietHours = "quiet-hours"
            case pauseOnBattery = "pause-on-battery"
            case batteryThreshold = "battery-threshold"
        }
    }

    struct RunnerSpec: Codable, Equatable {
        var name: String
        var repo: String?
        var org: String?
        var labels: [String]?
        var isolation: String?
        var enableGUI: Bool?
        var openFiles: Int?
        var quietHours: QuietHoursSpec?
        var count: Int?

        enum CodingKeys: String, CodingKey {
            case name, repo, org, labels, isolation, count
            case enableGUI = "enable-gui"
            case openFiles = "open-files"
            case quietHours = "quiet-hours"
        }
    }

    /// `never` (never pause) or a `{start, end}` window.
    enum QuietHoursSpec: Codable, Equatable {
        case never
        case window(start: String, end: String)

        private struct Window: Codable { var start: String; var end: String }

        init(from decoder: Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                guard ["never", "off", "none"].contains(text.lowercased()) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "expected 'never' or {start, end}"))
                }
                self = .never
                return
            }
            let window = try Window(from: decoder)
            self = .window(start: window.start, end: window.end)
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .never:
                var container = encoder.singleValueContainer()
                try container.encode("never")
            case .window(let start, let end):
                try Window(start: start, end: end).encode(to: encoder)
            }
        }

        init(_ quietHours: QuietHours) {
            self = quietHours.enabled ? .window(start: quietHours.start, end: quietHours.end) : .never
        }

        func resolved() throws -> QuietHours {
            switch self {
            case .never:
                return QuietHours(enabled: false, start: "00:00", end: "00:00")
            case .window(let start, let end):
                guard let start = QuietHours.normalizedTime(start), let end = QuietHours.normalizedTime(end) else {
                    throw DeclarativeConfigError.invalid("quiet-hours times must be HH:mm")
                }
                return QuietHours(enabled: true, start: start, end: end)
            }
        }
    }

    // MARK: - Files

    static let fileName = ".mac-runner.yml"

    /// `-f` path, else `./.mac-runner.yml`, else `~/.mac-runner/config.yml`.
    static func defaultPath(
        currentDirectory: String = FileManager.default.currentDirectoryPath,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let local = (currentDirectory as NSString).appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: local) { return local }
        return home.appendingPathComponent(".mac-runner/config.yml").path
    }

    static func parse(_ text: String) throws -> DeclarativeConfig {
        do {
            return try YAMLDecoder().decode(DeclarativeConfig.self, from: text)
        } catch let error as DecodingError {
            throw DeclarativeConfigError.invalid(Self.describe(error))
        } catch {
            throw DeclarativeConfigError.invalid(error.localizedDescription)
        }
    }

    func yaml() throws -> String {
        try YAMLEncoder().encode(self)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "missing '\(key.stringValue)' at \(path(context).isEmpty ? "top level" : path(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(path(context)): \(context.debugDescription)"
        @unknown default:
            return error.localizedDescription
        }
    }

    // MARK: - Resolution

    /// Runner specs expanded (`count`) and validated.
    func desiredRunners() throws -> [DesiredRunner] {
        var result: [DesiredRunner] = []
        for spec in runners {
            let name = spec.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
                throw DeclarativeConfigError.invalid("runner name '\(spec.name)' may only contain letters, digits, '.', '_' and '-'")
            }
            let target: RunnerTarget
            switch (spec.repo, spec.org) {
            case let (repo?, nil):
                guard repo.split(separator: "/").count == 2 else {
                    throw DeclarativeConfigError.invalid("\(name): repo must be owner/name")
                }
                target = RunnerTarget(scope: .repo, identifier: repo)
            case let (nil, org?):
                target = RunnerTarget(scope: .org, identifier: org)
            default:
                throw DeclarativeConfigError.invalid("\(name): set exactly one of repo or org")
            }
            let count = spec.count ?? 1
            guard (1...50).contains(count) else {
                throw DeclarativeConfigError.invalid("\(name): count must be between 1 and 50")
            }
            if let openFiles = spec.openFiles, openFiles < 1 {
                throw DeclarativeConfigError.invalid("\(name): open-files must be positive")
            }

            let desired = DesiredRunner(
                name: name,
                target: target,
                labels: spec.labels ?? Runner.defaultLabels,
                isolation: try Self.isolation(spec.isolation, context: name),
                enableGUI: spec.enableGUI ?? false,
                openFileLimit: spec.openFiles,
                quietHours: try spec.quietHours?.resolved()
            )
            if count == 1 {
                result.append(desired)
            } else {
                for index in 1...count {
                    var copy = desired
                    copy.name = "\(name)-\(index)"
                    result.append(copy)
                }
            }
        }

        var seen = Set<String>()
        for runner in result where !seen.insert(runner.name).inserted {
            throw DeclarativeConfigError.invalid("duplicate runner name '\(runner.name)'")
        }
        return result
    }

    /// nil = follow the global isolation mode.
    static func isolation(_ text: String?, context: String) throws -> IsolationMode? {
        switch text?.lowercased() {
        case nil, "global": return nil
        case "none": return IsolationMode.none
        case "user": return .dedicatedUser(username: IsolationMode.defaultUsername)
        case "container": return .container
        case let other?:
            throw DeclarativeConfigError.invalid("\(context): isolation '\(other)' must be none, user, container, or global")
        }
    }

    static func isolationName(_ mode: IsolationMode?) -> String? {
        switch mode {
        case nil: return nil
        case .none?: return "none"
        case .dedicatedUser?: return "user"
        case .container?: return "container"
        }
    }

    /// Settings with the file's overrides applied.
    func resolvedSettings(_ current: AppSettings) throws -> AppSettings {
        guard let settings else { return current }
        var result = current
        if let isolation = settings.isolation {
            result.isolationMode = try Self.isolation(isolation, context: "settings") ?? IsolationMode.none
        }
        if let quietHours = settings.quietHours {
            let resolved = try quietHours.resolved()
            // Globally, "never" just means off; keep an existing off window's times.
            if resolved.enabled || current.quietHours?.enabled == true {
                result.quietHours = resolved
            }
        }
        if let pauseOnBattery = settings.pauseOnBattery {
            result.pauseOnBattery = pauseOnBattery
        }
        if let threshold = settings.batteryThreshold {
            guard AppSettings.batteryPauseThresholdRange.contains(threshold) else {
                throw DeclarativeConfigError.invalid("settings: battery-threshold must be 5-95")
            }
            result.batteryPauseThreshold = threshold
        }
        return result
    }

    // MARK: - Export

    /// Describe the current setup as a config file.
    static func export(runners: [Runner], settings: AppSettings) -> DeclarativeConfig {
        DeclarativeConfig(
            version: 1,
            settings: SettingsSpec(
                isolation: isolationName(settings.isolationMode) ?? "none",
                quietHours: settings.quietHours.map(QuietHoursSpec.init),
                pauseOnBattery: settings.pauseOnBattery,
                batteryThreshold: settings.batteryPauseThreshold
            ),
            runners: runners.sorted { $0.name < $1.name }.map { runner in
                RunnerSpec(
                    name: runner.name,
                    repo: runner.scope == .repo ? runner.repo : nil,
                    org: runner.scope == .org ? runner.repo : nil,
                    labels: runner.labels,
                    isolation: isolationName(runner.isolationMode),
                    enableGUI: runner.enableGUI ? true : nil,
                    openFiles: runner.openFileLimit,
                    quietHours: runner.quietHours.map(QuietHoursSpec.init),
                    count: nil
                )
            }
        )
    }
}

enum DeclarativeConfigError: LocalizedError, Equatable {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return "Invalid config: \(message)"
        }
    }
}

/// One runner the config file asks for.
struct DesiredRunner: Equatable {
    var name: String
    var target: RunnerTarget
    var labels: [String]
    var isolation: IsolationMode?
    var enableGUI: Bool
    var openFileLimit: Int?
    var quietHours: QuietHours?
}

/// What `mac-runner apply` will do.
enum ConfigChange: Equatable {
    case add(DesiredRunner)
    /// Registration details changed, so the runner must be removed and registered again.
    case recreate(Runner, DesiredRunner, reasons: [String])
    /// Changed in place; `restart` when a running runner must restart to pick it up.
    case update(Runner, DesiredRunner, changes: [String], restart: Bool)
    case remove(Runner)
    case settings(changes: [String])

    var isDestructive: Bool {
        switch self {
        case .recreate, .remove: return true
        default: return false
        }
    }

    var summary: String {
        switch self {
        case .add(let desired):
            return "+ add \(desired.name) (\(desired.target.displayName))"
        case .recreate(let runner, _, let reasons):
            return "± re-register \(runner.name): \(reasons.joined(separator: ", "))"
        case .update(let runner, _, let changes, let restart):
            return "~ update \(runner.name): \(changes.joined(separator: ", "))\(restart ? " (restarts)" : "")"
        case .remove(let runner):
            return "- remove \(runner.name) (\(runner.target.displayName))"
        case .settings(let changes):
            return "~ settings: \(changes.joined(separator: ", "))"
        }
    }
}

enum ConfigPlanner {
    /// Changes that turn `current` into what `desired` describes. Runners are
    /// matched by name; with `prune`, runners missing from the file are removed.
    static func plan(
        desired: [DesiredRunner],
        desiredSettings: AppSettings,
        current: [Runner],
        currentSettings: AppSettings,
        prune: Bool = true
    ) -> [ConfigChange] {
        var changes: [ConfigChange] = []

        let settingChanges = describeSettingChanges(from: currentSettings, to: desiredSettings)
        if !settingChanges.isEmpty {
            changes.append(.settings(changes: settingChanges))
        }

        for want in desired {
            guard let have = current.first(where: { $0.name == want.name }) else {
                changes.append(.add(want))
                continue
            }

            var reregister: [String] = []
            if have.target != want.target { reregister.append("target \(have.target.displayName) → \(want.target.displayName)") }
            if have.labels != want.labels { reregister.append("labels [\(have.labels.joined(separator: ", "))] → [\(want.labels.joined(separator: ", "))]") }
            if have.isolationMode != want.isolation {
                reregister.append("isolation \(DeclarativeConfig.isolationName(have.isolationMode) ?? "global") → \(DeclarativeConfig.isolationName(want.isolation) ?? "global")")
            }
            if !reregister.isEmpty {
                changes.append(.recreate(have, want, reasons: reregister))
                continue
            }

            var updates: [String] = []
            var restart = false
            if have.enableGUI != want.enableGUI {
                updates.append(want.enableGUI ? "enable GUI" : "disable GUI")
                restart = true
            }
            if have.openFileLimit != want.openFileLimit {
                updates.append("open-files \(have.openFileLimit.map(String.init) ?? "default") → \(want.openFileLimit.map(String.init) ?? "default")")
                restart = true
            }
            if !QuietHours.equivalent(have.quietHours, want.quietHours) {
                updates.append("quiet-hours \(describe(have.quietHours)) → \(describe(want.quietHours))")
            }
            if !updates.isEmpty {
                changes.append(.update(have, want, changes: updates, restart: restart && have.status == .running))
            }
        }

        if prune {
            let wanted = Set(desired.map(\.name))
            for have in current.sorted(by: { $0.name < $1.name }) where !wanted.contains(have.name) {
                changes.append(.remove(have))
            }
        }
        return changes
    }

    static func describe(_ quietHours: QuietHours?) -> String {
        guard let quietHours else { return "global" }
        return quietHours.enabled ? quietHours.displayRange : "never"
    }

    static func describeSettingChanges(from old: AppSettings, to new: AppSettings) -> [String] {
        var changes: [String] = []
        if old.isolationMode != new.isolationMode {
            changes.append("isolation → \(DeclarativeConfig.isolationName(new.isolationMode) ?? "none")")
        }
        if !QuietHours.equivalent(old.quietHours, new.quietHours) && (old.quietHours?.enabled ?? false || new.quietHours?.enabled ?? false) {
            changes.append("quiet-hours → \(new.quietHours.map { $0.enabled ? $0.displayRange : "off" } ?? "off")")
        }
        if old.pauseOnBattery != new.pauseOnBattery {
            changes.append("pause-on-battery → \(new.pauseOnBattery)")
        }
        if old.batteryPauseThreshold != new.batteryPauseThreshold {
            changes.append("battery-threshold → \(new.batteryPauseThreshold)%")
        }
        return changes
    }
}
