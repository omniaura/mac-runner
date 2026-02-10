import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var runnerManager: RunnerManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "figure.run")
                    .font(.title2)
                Text("Mac Runner")
                    .font(.headline)
                Spacer()
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
                // Open add runner sheet
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
                // Open settings
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

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(runner.name)
                    .font(.headline)

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

            Text(runner.status.rawValue.capitalized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.gray.opacity(0.05))
        .cornerRadius(8)
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
    var body: some View {
        Text("Settings")
            .frame(minWidth: 400, minHeight: 300)
    }
}

#Preview {
    MenuBarView()
        .environmentObject(RunnerManager())
}
