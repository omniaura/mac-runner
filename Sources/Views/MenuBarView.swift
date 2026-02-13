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
        .frame(width: 300, height: 400)
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

    private var runnerList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(runnerManager.runners) { runner in
                    RunnerRow(runner: runner)
                        .environmentObject(runnerManager)
                }
            }
            .padding()
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
        HStack {
            Button(action: {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }) {
                Label("Settings", systemImage: "gear")
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Label("Quit", systemImage: "xmark.circle")
            }
            .buttonStyle(.plain)
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

                Text(runner.repo)
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 4) {
                    ForEach(runner.labels, id: \.self) { label in
                        Text(label)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(4)
                    }
                }
            }

            Spacer()

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
                    .foregroundColor(runner.status == .running ? .red : .green)
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

    var body: some View {
        TabView {
            // General Tab
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

                Spacer()
            }
            .padding()
            .tabItem { Label("General", systemImage: "gear") }

            // GitHub Tab
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

                Spacer()
            }
            .padding()
            .tabItem { Label("GitHub", systemImage: "lock.shield") }

            // About Tab
            VStack(spacing: 12) {
                Image(systemName: "figure.run")
                    .font(.system(size: 48))
                    .foregroundColor(.accentColor)

                Text("Mac Runner")
                    .font(.title2)
                    .bold()

                Text("Version \(CLIHandler.version)")
                    .foregroundColor(.secondary)

                Text("GitHub Actions self-hosted runner manager for macOS")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding()
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 400, minHeight: 300)
        .task {
            await checkAuth()
        }
    }

    private func checkAuth() async {
        isAuthenticated = await GHCLIService.shared.checkAuth()
        authStatusText = await GHCLIService.shared.authStatus()
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
