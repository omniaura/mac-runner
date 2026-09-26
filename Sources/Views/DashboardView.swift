import AppKit
import SwiftUI

extension Notification.Name {
    static let openDashboard = Notification.Name("openDashboard")
}

/// Full window for monitoring runners: a runner list and a detail pane with
/// status, configuration, resources, recent jobs, and live logs.
struct DashboardView: View {
    @EnvironmentObject var runnerManager: RunnerManager
    @State private var selection: UUID?
    @State private var showAddRunner = false

    private var groups: [(target: RunnerTarget, runners: [Runner])] {
        Self.groups(runnerManager.runners)
    }

    static func groups(_ runners: [Runner]) -> [(target: RunnerTarget, runners: [Runner])] {
        Dictionary(grouping: runners) { $0.target }
            .map { (target: $0.key, runners: $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
            .sorted { $0.target.identifier.localizedCaseInsensitiveCompare($1.target.identifier) == .orderedAscending }
    }

    var body: some View {
        NavigationSplitView {
            DashboardSidebar(groups: groups, selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let id = selection, let runner = runnerManager.runners.first(where: { $0.id == id }) {
                RunnerDetailView(runner: runner)
                    .id(runner.id)
            } else {
                Text(runnerManager.runners.isEmpty ? "Add a runner to get started" : "Select a runner")
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showAddRunner = true
                } label: {
                    Label("Add Runner", systemImage: "plus")
                }
                .help("Add Runner")

                Button {
                    Task { try? await runnerManager.pauseAll() }
                } label: {
                    Label("Pause All", systemImage: "pause.fill")
                }
                .help("Pause all running runners")
                .disabled(runnerManager.runners.allSatisfy { $0.status != .running })

                Button {
                    Task { try? await runnerManager.resumeAll() }
                } label: {
                    Label("Resume All", systemImage: "play.fill")
                }
                .help("Resume all paused runners")
                .disabled(runnerManager.runners.allSatisfy { $0.status != .paused })

                Button {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showAddRunner) {
            AddRunnerView()
                .environmentObject(runnerManager)
        }
        .onAppear {
            if selection == nil {
                selection = groups.first?.runners.first?.id
            }
        }
        .frame(minWidth: 820, minHeight: 520)
    }
}

/// Summary counts above the runner list, grouped by target.
struct DashboardSidebar: View {
    let groups: [(target: RunnerTarget, runners: [Runner])]
    @Binding var selection: UUID?
    @EnvironmentObject var runnerManager: RunnerManager

    var body: some View {
        VStack(spacing: 0) {
            DashboardSummary()
                .padding(10)
            Divider()
            List(selection: $selection) {
                ForEach(groups, id: \.target) { group in
                    Section(group.target.displayName) {
                        ForEach(group.runners) { runner in
                            DashboardRunnerRow(runner: runner)
                                .tag(runner.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if runnerManager.runners.isEmpty {
                    Text("No runners yet")
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

/// Counts and totals shown above the runner list.
struct DashboardSummary: View {
    @EnvironmentObject var runnerManager: RunnerManager

    var body: some View {
        let runners = runnerManager.runners
        let executing = runners.filter { $0.status == .running && $0.busy }.count
        let running = runners.filter { $0.status == .running }.count
        let paused = runners.filter { $0.status == .paused }.count

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                SummaryCount(value: executing, label: "Executing", color: .orange)
                SummaryCount(value: running - executing, label: "Idle", color: .green)
                SummaryCount(value: paused, label: "Paused", color: .yellow)
                SummaryCount(value: runners.filter { $0.status == .stopped }.count, label: "Stopped", color: .gray)
                SummaryCount(value: runners.filter { $0.status == .error }.count, label: "Error", color: .red)
            }
            if !runnerManager.resourceUsage.isEmpty {
                Text(runnerManager.totalResourceUsage.summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if let summary = runnerManager.autoPauseSummary() {
                Label(summary.text, systemImage: "moon.zzz")
                    .font(.caption)
                    .foregroundColor(summary.isActive ? .orange : .secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SummaryCount: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(value)")
                .font(.title2.monospacedDigit().weight(.semibold))
                .foregroundColor(value > 0 ? color : .secondary)
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

/// Large status pill: EXECUTING / IDLE / PAUSED / STOPPED / ERROR.
struct RunnerStatusBadge: View {
    let runner: Runner
    var large = false

    private var text: String {
        switch runner.status {
        case .running: return runner.busy ? "EXECUTING" : "IDLE"
        case .paused: return "PAUSED"
        case .stopped: return "STOPPED"
        case .error: return "ERROR"
        }
    }

    private var color: Color {
        switch runner.status {
        case .running: return runner.busy ? .orange : .green
        case .paused: return .yellow
        case .stopped: return .gray
        case .error: return .red
        }
    }

    var body: some View {
        Text(text)
            .font(large ? .headline : .caption2.weight(.bold))
            .foregroundColor(runner.status == .running && runner.busy ? .white : color)
            .padding(.horizontal, large ? 12 : 6)
            .padding(.vertical, large ? 5 : 2)
            .background(color.opacity(runner.status == .running && runner.busy ? 1 : 0.18))
            .cornerRadius(large ? 8 : 4)
    }
}

struct DashboardRunnerRow: View {
    let runner: Runner
    @EnvironmentObject var runnerManager: RunnerManager

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(runner.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                RunnerStatusBadge(runner: runner)
            }
            if let usage = runnerManager.resourceUsage[runner.id], runner.status == .running {
                Text(usage.summary)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            } else if let status = runnerManager.autoPauseStatus(for: runner) {
                Text(status)
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct RunnerDetailView: View {
    let runner: Runner
    @EnvironmentObject var runnerManager: RunnerManager
    @StateObject private var logModel: LogViewerModel
    @State private var confirmRemove = false
    @State private var actionError: String?

    init(runner: Runner) {
        self.runner = runner
        _logModel = StateObject(wrappedValue: LogViewerModel(runner: runner) { _ in nil })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let actionError {
                        Text(actionError)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    HStack(alignment: .top, spacing: 24) {
                        configuration
                        activity
                    }
                    recentJobs
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)

            Divider()
            LogViewerView(model: logModel)
                .frame(minWidth: 0, minHeight: 200)
        }
        .onAppear {
            logModel.resolvePath = { [weak runnerManager] source in
                guard let runnerManager, let current = runnerManager.runners.first(where: { $0.id == runner.id }) else { return nil }
                return runnerManager.logPath(for: current, source: source)
            }
            logModel.reload()
        }
        .confirmationDialog("Remove \(runner.name)?", isPresented: $confirmRemove) {
            Button("Remove Runner", role: .destructive) {
                perform { try await runnerManager.removeRunner(runner.id) }
            }
        } message: {
            Text("It will be unregistered from GitHub and its workspace deleted.")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(runner.name)
                    .font(.title.weight(.semibold))
                Text(runner.target.displayName)
                    .foregroundColor(.secondary)
            }
            RunnerStatusBadge(runner: runner, large: true)
            Spacer()
            if runner.status == .running {
                Button {
                    perform { try await runnerManager.stopRunner(runner.id) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
            } else {
                Button {
                    perform { try await runnerManager.startRunner(runner.id) }
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            Button {
                NotificationCenter.default.post(name: .openRunnerLogs, object: runner.id)
            } label: {
                Label("Logs", systemImage: "doc.text.magnifyingglass")
            }
            .help("Open logs in their own window")
            Button(role: .destructive) {
                confirmRemove = true
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove runner")
        }
    }

    private var configuration: some View {
        let isolation = runner.effectiveIsolationMode(global: runnerManager.currentSettings.isolationMode)
        let schedule = runner.effectiveQuietHours(global: runnerManager.currentSettings.quietHours)

        return DetailSection(title: "Configuration") {
            DetailRow("Scope", runner.scope.displayName)
            DetailRow("Isolation", "\(isolation.icon) \(isolation.displayName)\(runner.isolationMode == nil ? " (global)" : "")")
            if isolation == .container {
                DetailRow("Image", runner.containerImage ?? ContainerRunnerConfiguration.defaultRunnerImage)
                DetailRow("Tools", (runner.containerTools ?? []).isEmpty ? "—" : (runner.containerTools ?? []).joined(separator: ", "))
            }
            DetailRow("Display", runner.enableGUI ? "GUI access" : "Headless")
            DetailRow("Labels", runner.labels.isEmpty ? "—" : runner.labels.joined(separator: ", "))
            DetailRow("Open files", "\(runner.effectiveOpenFileLimit(global: runnerManager.currentSettings.openFileLimit))")
            DetailRow("Quiet hours", schedule.map { $0.enabled ? $0.displayRange : "Off" } ?? "Off")
            if let id = runner.githubRunnerId {
                DetailRow("GitHub ID", "\(id)")
            }
        }
    }

    private var activity: some View {
        DetailSection(title: "Activity") {
            if runner.status == .running, runner.busy,
               let job = runnerManager.currentWorkflowJob(for: runner.id),
               let name = RunnerManager.currentWorkflowDisplayName(from: job) {
                HStack {
                    Text("Current job")
                        .foregroundColor(.secondary)
                        .frame(width: 100, alignment: .leading)
                    Button(name) { runnerManager.openCurrentWorkflowRun(for: runner.id) }
                        .buttonStyle(.link)
                }
            }
            if let usage = runnerManager.resourceUsage[runner.id], runner.status == .running {
                DetailRow("CPU", usage.cpuText)
                DetailRow("Memory", usage.memoryText)
                DetailRow("Workspace", usage.diskText ?? "measuring…")
                DetailRow("Processes", "\(usage.processCount)")
            } else {
                DetailRow("Resources", "Not running")
            }
            if let status = runnerManager.autoPauseStatus(for: runner) {
                DetailRow("Schedule", status)
            }
            if let event = runner.lastRestartEvent {
                DetailRow("Last event", event)
            }
        }
    }

    private var recentJobs: some View {
        DetailSection(title: "Recent Jobs") {
            let jobs = runnerManager.recentJobs[runner.id] ?? []
            if jobs.isEmpty {
                Text("No jobs since Mac Runner started.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(jobs) { job in
                    HStack(spacing: 8) {
                        Image(systemName: Self.icon(for: job.outcome))
                            .foregroundColor(Self.color(for: job.outcome))
                        Button(job.displayName) { NSWorkspace.shared.open(job.job.run.htmlURL) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                        Spacer()
                        Text(job.startedAt, style: .relative)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        actionError = nil
        Task {
            do {
                try await action()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    static func icon(for outcome: String) -> String {
        switch outcome {
        case "running": return "circle.dotted"
        case "pending": return "clock"
        case "success": return "checkmark.circle.fill"
        case "cancelled", "skipped": return "slash.circle"
        default: return "xmark.circle.fill"
        }
    }

    static func color(for outcome: String) -> Color {
        switch outcome {
        case "running": return .orange
        case "success": return .green
        case "pending", "cancelled", "skipped": return .secondary
        default: return .red
        }
    }
}

private struct DetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct DetailRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}
