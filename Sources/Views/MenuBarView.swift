import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var runnerManager: RunnerManager
    @State private var showAddRunner = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "figure.run")
                    .font(.title2)
                Text("Mac Runner")
                    .font(.headline)
                Spacer()
                Button(action: { showAddRunner = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("Add Runner")
            }
            .padding()
            .background(Color.gray.opacity(0.1))

            // Runner List
            if runnerManager.runners.isEmpty {
                emptyState
            } else {
                runnerList
            }

            Divider()

            // Actions
            actionButtons

            Divider()

            // Footer
            footerButtons
        }
        .frame(width: 300, height: 430)
        .sheet(isPresented: $showAddRunner) {
            AddRunnerView()
                .environmentObject(runnerManager)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "figure.run.square.stack")
                .font(.system(size: 48))
                .foregroundColor(.gray)

            Text("No runners configured")
                .font(.headline)

            Text("Add your first runner to get started")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Add Runner") {
                showAddRunner = true
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxHeight: .infinity)
    }

    /// Runners grouped by target (scope + identifier), sorted alphabetically by identifier
    /// then by runner name. Grouping by target — not by `repo` string — keeps a repo-level
    /// runner for "acme/api" separate from an org-level runner for "acme" if both exist.
    private var groupedRunners: [(target: RunnerTarget, runners: [Runner])] {
        let grouped = Dictionary(grouping: runnerManager.runners) { $0.target }
        return grouped
            .map { (target: $0.key, runners: $0.value.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
            .sorted { $0.target.identifier.localizedCaseInsensitiveCompare($1.target.identifier) == .orderedAscending }
    }

    private var runnerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groupedRunners, id: \.target) { group in
                    // Section header — org-level groups use a building icon to distinguish
                    // them from repo-level groups at a glance.
                    HStack(spacing: 4) {
                        Image(systemName: group.target.scope == .org ? "building.2" : "folder")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(group.target.displayName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(group.runners.count)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

                    ForEach(group.runners) { runner in
                        RunnerRow(runner: runner)
                            .environmentObject(runnerManager)
                    }
                }
            }
            .padding(.vertical)
            .padding(.horizontal, 4)
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: {
                Task {
                    try? await runnerManager.pauseAll()
                }
            }) {
                Label("Pause All", systemImage: "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(runnerManager.runners.allSatisfy { $0.status != .running })

            Button(action: {
                Task {
                    try? await runnerManager.resumeAll()
                }
            }) {
                Label("Resume All", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .disabled(runnerManager.runners.allSatisfy { $0.status != .paused })
        }
        .padding()
    }

    private var footerButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let gitHubAuthIssue = runnerManager.gitHubAuthIssue {
                Text(gitHubAuthIssue)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let update = runnerManager.availableUpdate {
                Button(action: {
                    Task {
                        await runnerManager.performAvailableUpdate()
                    }
                }) {
                    HStack(spacing: 10) {
                        if runnerManager.isInstallingUpdate {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.accentColor)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(update.actionTitle)
                                .font(.caption)
                                .fontWeight(.semibold)
                            Text(update.detailText)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        Spacer()
                    }
                    .padding(10)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(runnerManager.isInstallingUpdate)
            }

            HStack {
                Button(action: {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }) {
                    Label("Settings", systemImage: "gear")
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: {
                    Task {
                        await runnerManager.checkForUpdates(force: true)
                    }
                }) {
                    if runnerManager.isCheckingForUpdates {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Updates", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.plain)
                .disabled(runnerManager.isInstallingUpdate)

                Spacer()

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Label("Quit", systemImage: "xmark.circle")
                }
                .buttonStyle(.plain)
            }

            Text(runnerManager.updateStatusMessage)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
    }
}

struct RunnerRow: View {
    let runner: Runner
    @EnvironmentObject var runnerManager: RunnerManager

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(runner.name)
                        .font(.headline)

                    // Show execution status badge when runner is busy
                    if runner.status == .running && runner.busy {
                        Text("EXECUTING")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange)
                            .cornerRadius(4)
                    } else if runner.status == .running {
                        Text("IDLE")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }
                }

                Text(runner.target.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if runner.status == .running,
                   runner.busy,
                   let currentJob = runnerManager.currentWorkflowJob(for: runner.id),
                   let workflowName = RunnerManager.currentWorkflowDisplayName(from: currentJob) {
                    Button(action: {
                        runnerManager.openCurrentWorkflowRun(for: runner.id)
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                            Text("View \(workflowName)")
                                .lineLimit(1)
                        }
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help("Open current GitHub Actions run")
                }

                FlowLayout(spacing: 4) {
                    // Isolation mode indicator
                    if let mode = runner.isolationMode {
                        Text("\(mode.icon) \(mode.displayName)")
                            .font(.caption2)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.2))
                            .cornerRadius(4)
                    } else {
                        Text("🌐 Global")
                            .font(.caption2)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }

                    // GUI access indicator
                    if runner.enableGUI {
                        Text("🖥️ GUI")
                            .font(.caption2)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .cornerRadius(4)
                    } else {
                        Text("⚫ Headless")
                            .font(.caption2)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.2))
                            .cornerRadius(4)
                    }

                    ForEach(runner.labels, id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(4)
                    }
                }

                if let restartEvent = runner.lastRestartEvent {
                    Text(restartEvent)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Inline start/stop button
            Button(action: {
                Task {
                    if runner.status == .running {
                        try? await runnerManager.stopRunner(runner.id)
                    } else {
                        try? await runnerManager.startRunner(runner.id)
                    }
                }
            }) {
                Image(systemName: runner.status == .running ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help(runner.status == .running ? "Stop" : "Start")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
        .contextMenu {
            if runner.status == .running {
                Button("Stop") {
                    Task { try? await runnerManager.stopRunner(runner.id) }
                }
                if runner.busy, runnerManager.currentWorkflowJob(for: runner.id) != nil {
                    Button("Open Current Job") {
                        runnerManager.openCurrentWorkflowRun(for: runner.id)
                    }
                }
            } else {
                Button("Start") {
                    Task { try? await runnerManager.startRunner(runner.id) }
                }
            }
            Divider()
            Button("Duplicate") {
                Task { try? await runnerManager.duplicateRunner(runner.id) }
            }
            Divider()
            Button("Remove", role: .destructive) {
                Task { try? await runnerManager.removeRunner(runner.id) }
            }
        }
    }

    private var statusColor: Color {
        switch runner.status {
        case .running: return .green
        case .stopped: return .gray
        case .paused: return .orange
        case .error: return .red
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var runnerManager: RunnerManager
    @State private var isAuthenticated = false
    @State private var authStatusText = "Checking..."
    @State private var isLoggingIn = false
    private let openFileLimitFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 1
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    var body: some View {
        TabView {
            // General Tab
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("General")
                        .font(.headline)

                    Toggle("Launch at Login", isOn: Binding(
                        get: { runnerManager.currentSettings.startOnLogin },
                        set: { newValue in
                            var settings = runnerManager.currentSettings
                            settings.startOnLogin = newValue
                            runnerManager.updateSettings(settings)
                        }
                    ))

                    Text("When enabled, Mac Runner starts automatically when you log in and restarts any runners that were previously running.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Check for Updates Automatically", isOn: Binding(
                        get: { runnerManager.currentSettings.autoCheckForUpdates },
                        set: { newValue in
                            var settings = runnerManager.currentSettings
                            settings.autoCheckForUpdates = newValue
                            runnerManager.updateSettings(settings)
                        }
                    ))

                    Text("Checks the latest GitHub release on launch, then uses a 24-hour backoff with a 5-minute response cache for manual refreshes.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Auto-Restart on Crash", isOn: Binding(
                        get: { runnerManager.currentSettings.autoRestartEnabled },
                        set: { newValue in
                            var settings = runnerManager.currentSettings
                            settings.autoRestartEnabled = newValue
                            runnerManager.updateSettings(settings)
                        }
                    ))

                    HStack {
                        Text("Max retries in 10 minutes")
                        Spacer()
                        Stepper(
                            value: Binding(
                                get: { runnerManager.currentSettings.autoRestartMaxRetries },
                                set: { newValue in
                                    var settings = runnerManager.currentSettings
                                    settings.autoRestartMaxRetries = max(1, newValue)
                                    runnerManager.updateSettings(settings)
                                }
                            ),
                            in: 1...20
                        ) {
                            Text("\(runnerManager.currentSettings.autoRestartMaxRetries)")
                                .monospacedDigit()
                        }
                        .labelsHidden()
                    }

                    Text("Crash recovery uses exponential backoff (5s, 10s, 20s, capped at 60s).")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Job Notifications", isOn: Binding(
                        get: { runnerManager.currentSettings.notificationsEnabled },
                        set: { newValue in
                            var settings = runnerManager.currentSettings
                            settings.notificationsEnabled = newValue
                            runnerManager.updateSettings(settings)
                        }
                    ))

                    Text("Show native macOS notifications when a runner starts a job and when that job completes. Clicking a notification opens the GitHub Actions run.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default Open Files Limit")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("Open files limit", value: Binding(
                            get: { runnerManager.currentSettings.openFileLimit },
                            set: { newValue in
                                var settings = runnerManager.currentSettings
                                settings.openFileLimit = max(1, newValue)
                                runnerManager.updateSettings(settings)
                            }
                        ), formatter: openFileLimitFormatter)
                        .textFieldStyle(.roundedBorder)

                        Text("Applied to runners by default across non-isolated, dedicated-user, and container modes unless a runner overrides it.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Extra CI Tools")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("jq, pnpm, ...", text: Binding(
                            get: { runnerManager.currentSettings.tools.extraPackages.joined(separator: ", ") },
                            set: { newValue in
                                var settings = runnerManager.currentSettings
                                settings.tools = ToolProvisioningSettings(
                                    extraPackages: newValue
                                        .components(separatedBy: ",")
                                        .map {
                                            $0.trimmingCharacters(in: .whitespacesAndNewlines)
                                        }
                                )
                                runnerManager.updateSettings(settings)
                            }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Text("New runners always provision gh, detect common language toolchains from repo metadata, and install any extra Homebrew packages listed here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tabItem { Label("General", systemImage: "gear") }

            // GitHub Tab
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("GitHub Authentication")
                        .font(.headline)

                    HStack {
                        Circle()
                            .fill(isAuthenticated ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(isAuthenticated ? "Authenticated" : "Not authenticated")
                    }

                    Text(authStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    if !isAuthenticated {
                        Button(action: {
                            Task { await login() }
                        }) {
                            Label("Sign in with GitHub", systemImage: "person.badge.key")
                        }
                        .disabled(isLoggingIn)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tabItem { Label("GitHub", systemImage: "lock.shield") }

            // About Tab
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        Spacer(minLength: 0)

                        Image(systemName: "figure.run")
                            .font(.system(size: 48))
                            .foregroundColor(.accentColor)

                        Text("Mac Runner")
                            .font(.title2)
                            .bold()

                        Text("Version \(CLIHandler.version)")
                            .foregroundColor(.secondary)

                        if let update = runnerManager.availableUpdate {
                            Text("Update available: \(update.latestVersion)")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        } else {
                            Text(runnerManager.updateStatusMessage)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        Button(action: {
                            Task {
                                await runnerManager.checkForUpdates(force: true)
                            }
                        }) {
                            Label("Check for Updates", systemImage: "arrow.clockwise")
                        }
                        .disabled(runnerManager.isCheckingForUpdates)

                        Text("GitHub Actions self-hosted runner manager for macOS")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Spacer(minLength: 0)
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
            }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 400, minHeight: 420)
        .task {
            await checkAuth()
        }
    }

    private func checkAuth() async {
        isAuthenticated = await GHCLIService.shared.checkAuth()
        authStatusText = await GHCLIService.shared.authStatus()
        await runnerManager.refreshGitHubAuthStatus()
    }

    private func login() async {
        isLoggingIn = true
        defer { isLoggingIn = false }
        try? await GHCLIService.shared.openLogin()
        await checkAuth()
    }
}

#Preview {
    MenuBarView()
        .environmentObject(RunnerManager())
}

/// Lays out subviews left-to-right, wrapping onto additional lines when a row would exceed the available width.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > maxWidth {
                origin.x = 0
                origin.y += rowHeight + spacing
                totalHeight += rowHeight + spacing
                rowHeight = 0
            }
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalHeight += rowHeight

        return CGSize(width: maxWidth.isFinite ? maxWidth : origin.x, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x - bounds.minX + size.width > maxWidth {
                origin.x = bounds.minX
                origin.y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: .unspecified)
            origin.x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
