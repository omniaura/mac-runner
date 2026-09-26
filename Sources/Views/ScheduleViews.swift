import SwiftUI

/// Binds an "HH:mm" string to a Date for DatePicker (.hourAndMinute).
enum QuietHoursTime {
    static func date(from time: String, calendar: Calendar = .current) -> Date {
        let minutes = QuietHours.minutes(from: time) ?? 0
        return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
    }

    static func string(from date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 0, components.minute ?? 0)
    }

    static func binding(_ time: Binding<String>) -> Binding<Date> {
        Binding(
            get: { date(from: time.wrappedValue) },
            set: { time.wrappedValue = string(from: $0) }
        )
    }
}

/// Start/end pickers for a pause window.
struct QuietHoursRangePicker: View {
    @Binding var start: String
    @Binding var end: String

    var body: some View {
        HStack {
            DatePicker("From", selection: QuietHoursTime.binding($start), displayedComponents: .hourAndMinute)
            DatePicker("to", selection: QuietHoursTime.binding($end), displayedComponents: .hourAndMinute)
        }
    }
}

/// Settings section for low-battery and quiet-hours auto-pause.
struct AutoPauseSettingsSection: View {
    @EnvironmentObject var runnerManager: RunnerManager

    private var settings: AppSettings { runnerManager.currentSettings }

    private func update(_ change: (inout AppSettings) -> Void) {
        var updated = runnerManager.currentSettings
        change(&updated)
        runnerManager.updateSettings(updated)
    }

    private var quietHours: QuietHours {
        settings.quietHours ?? QuietHours(enabled: false, start: "09:00", end: "17:00")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Pause Runners on Low Battery", isOn: Binding(
                get: { settings.pauseOnBattery },
                set: { newValue in update { $0.pauseOnBattery = newValue } }
            ))

            HStack {
                Text("Pause below")
                Spacer()
                // A hidden label would hide the value, so show it alongside.
                Text("\(settings.batteryPauseThreshold)%")
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                Stepper(
                    value: Binding(
                        get: { settings.batteryPauseThreshold },
                        set: { newValue in update { $0.batteryPauseThreshold = AppSettings.normalizedBatteryPauseThreshold(newValue) } }
                    ),
                    in: AppSettings.batteryPauseThresholdRange,
                    step: 5
                ) {
                    EmptyView()
                }
                .labelsHidden()
            }
            .disabled(!settings.pauseOnBattery)

            Text(batteryCaption)
                .font(.caption)
                .foregroundColor(.secondary)

            Toggle("Quiet Hours", isOn: Binding(
                get: { quietHours.enabled },
                set: { newValue in update { $0.quietHours = QuietHours(enabled: newValue, start: quietHours.start, end: quietHours.end) } }
            ))

            QuietHoursRangePicker(
                start: Binding(
                    get: { quietHours.start },
                    set: { newValue in update { $0.quietHours = QuietHours(enabled: quietHours.enabled, start: newValue, end: quietHours.end) } }
                ),
                end: Binding(
                    get: { quietHours.end },
                    set: { newValue in update { $0.quietHours = QuietHours(enabled: quietHours.enabled, start: quietHours.start, end: newValue) } }
                )
            )
            .disabled(!quietHours.enabled)

            Text("Runners pause during this daily window (it may cross midnight) and resume when it ends. A runner in the middle of a job finishes it first. Individual runners can override this from their Schedule menu.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var batteryCaption: String {
        let base = "Runners finish their current job, then pause while on battery below the threshold. They resume when plugged in or charged above it."
        guard let power = runnerManager.powerState else {
            return base + " No battery detected on this Mac."
        }
        return base + " Battery: \(power.batteryLevel)%\(power.isOnBattery ? " (on battery)" : " (charging)")."
    }
}

/// Per-runner pause schedule editor.
struct RunnerScheduleView: View {
    enum Mode: Hashable {
        case global
        case never
        case custom
    }

    let runner: Runner
    @EnvironmentObject var runnerManager: RunnerManager
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode
    @State private var start: String
    @State private var end: String

    init(runner: Runner) {
        self.runner = runner
        switch runner.quietHours {
        case nil:
            _mode = State(initialValue: .global)
        case let hours? where !hours.enabled:
            _mode = State(initialValue: .never)
        default:
            _mode = State(initialValue: .custom)
        }
        _start = State(initialValue: runner.quietHours?.start ?? "22:00")
        _end = State(initialValue: runner.quietHours?.end ?? "06:00")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Schedule for \(runner.name)")
                .font(.headline)

            Picker("Quiet hours", selection: $mode) {
                Text(globalLabel).tag(Mode.global)
                Text("Never pause").tag(Mode.never)
                Text("Custom window").tag(Mode.custom)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            if mode == .custom {
                QuietHoursRangePicker(start: $start, end: $end)
            }

            Text("Low-battery pausing applies to every runner when enabled in Settings.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    runnerManager.setQuietHours(Self.quietHours(for: mode, start: start, end: end), for: runner.id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private var globalLabel: String {
        guard let global = runnerManager.currentSettings.quietHours, global.enabled else {
            return "Use global (off)"
        }
        return "Use global (\(global.displayRange))"
    }

    static func quietHours(for mode: Mode, start: String, end: String) -> QuietHours? {
        switch mode {
        case .global: return nil
        case .never: return QuietHours(enabled: false, start: start, end: end)
        case .custom: return QuietHours(enabled: true, start: start, end: end)
        }
    }
}

/// Settings for alerting when runners' combined usage is high.
struct ResourceAlertSettingsSection: View {
    @EnvironmentObject var runnerManager: RunnerManager

    private var alerts: ResourceAlertSettings { runnerManager.currentSettings.resourceAlerts }

    private func update(_ change: (inout ResourceAlertSettings) -> Void) {
        var settings = runnerManager.currentSettings
        change(&settings.resourceAlerts)
        runnerManager.updateSettings(settings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Alert on High Resource Usage", isOn: Binding(
                get: { alerts.enabled },
                set: { newValue in update { $0.enabled = newValue } }
            ))

            HStack {
                Text("Total CPU above")
                Spacer()
                Text("\(alerts.cpuPercent)%")
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                Stepper(
                    value: Binding(get: { alerts.cpuPercent }, set: { newValue in update { $0.cpuPercent = newValue } }),
                    in: 50...3200,
                    step: 50
                ) {
                    EmptyView()
                }
                .labelsHidden()
            }
            .disabled(!alerts.enabled)

            HStack {
                Text("Total memory above")
                Spacer()
                Text("\(alerts.memoryGB) GB")
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                Stepper(
                    value: Binding(get: { alerts.memoryGB }, set: { newValue in update { $0.memoryGB = newValue } }),
                    in: 1...512
                ) {
                    EmptyView()
                }
                .labelsHidden()
            }
            .disabled(!alerts.enabled)

            Text("CPU is summed across runners (100% = one core). Each runner's usage appears under it in the menu; you're notified once when a limit is crossed.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
