import SwiftUI

struct AddRunnerView: View {
    @EnvironmentObject var runnerManager: RunnerManager
    @Environment(\.dismiss) var dismiss

    @State private var repo = ""
    @State private var name = ""
    @State private var labelsText = "macos, mac-runner"
    @State private var repos: [String] = []
    @State private var isLoadingRepos = false
    @State private var showRepoPicker = false
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Runner")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Form
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Repository
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Repository")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField("owner/repo", text: $repo)
                                .textFieldStyle(.roundedBorder)

                            if isLoadingRepos {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Button("Browse") {
                                    Task { await loadRepos() }
                                }
                            }
                        }

                        if showRepoPicker, !repos.isEmpty {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(repos, id: \.self) { r in
                                        Button(action: {
                                            repo = r
                                            showRepoPicker = false
                                        }) {
                                            HStack {
                                                Text(r)
                                                    .font(.system(.caption, design: .monospaced))
                                                Spacer()
                                                if r == repo {
                                                    Image(systemName: "checkmark")
                                                        .foregroundColor(.accentColor)
                                                        .font(.caption)
                                                }
                                            }
                                            .contentShape(Rectangle())
                                            .padding(.vertical, 4)
                                            .padding(.horizontal, 8)
                                        }
                                        .buttonStyle(.plain)
                                        if r != repos.last {
                                            Divider()
                                        }
                                    }
                                }
                            }
                            .frame(height: min(CGFloat(repos.count) * 28, 140))
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                        }
                    }

                    // Runner Name
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Runner Name")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("Auto-generated if empty", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    // Labels
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Labels (comma-separated)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("macos, arm64, ...", text: $labelsText)
                            .textFieldStyle(.roundedBorder)
                    }

                    if let error = errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                .padding()
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isAdding {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 8)
                }

                Button("Add Runner") {
                    Task { await addRunner() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(repo.isEmpty || isAdding)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 400, height: 400)
    }

    private func loadRepos() async {
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        errorMessage = nil

        do {
            repos = try await GHCLIService.shared.listRepos()
            showRepoPicker = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addRunner() async {
        isAdding = true
        defer { isAdding = false }
        errorMessage = nil

        let runnerName = name.isEmpty
            ? "mac-runner-\(Int.random(in: 1000...9999))"
            : name

        let labels = labelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        do {
            try await runnerManager.addRunner(
                name: runnerName,
                repo: repo,
                labels: labels.isEmpty ? ["macos"] : labels
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
