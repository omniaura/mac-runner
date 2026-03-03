import SwiftUI

struct AddRunnerView: View {
    @EnvironmentObject var runnerManager: RunnerManager
    @Environment(\.dismiss) var dismiss

    @State private var repo = ""
    @State private var name = ""
    @State private var labelsText = "macos, mac-runner"
    @State private var selectedIsolation: IsolationSelection = .global
    @State private var enableGUI = false
    @State private var repoSections: [(header: String, repos: [String])] = []
    @State private var repoSearchText = ""
    @State private var isLoadingRepos = false
    @State private var showRepoPicker = false
    @State private var isAdding = false
    @State private var errorMessage: String?

    enum IsolationSelection: String, CaseIterable, Identifiable {
        case global = "Global (from settings)"
        case none = "None (no isolation)"
        case user = "User (dedicated user)"
        case container = "Container (macOS 26+)"

        var id: String { rawValue }

        var isolationMode: IsolationMode? {
            switch self {
            case .global: return nil
            case .none: return .none
            case .user: return .dedicatedUser(username: IsolationMode.defaultUsername)
            case .container: return .container
            }
        }
    }

    private var filteredSections: [(header: String, repos: [String])] {
        if repoSearchText.isEmpty {
            return repoSections
        }
        let query = repoSearchText.lowercased()
        return repoSections.compactMap { section in
            let filtered = section.repos.filter { $0.lowercased().contains(query) }
            return filtered.isEmpty ? nil : (header: section.header, repos: filtered)
        }
    }

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

                        if showRepoPicker, !repoSections.isEmpty {
                            VStack(spacing: 0) {
                                TextField("Search repos...", text: $repoSearchText)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.caption)
                                    .padding(6)

                                Divider()

                                if filteredSections.isEmpty {
                                    Text("No matching repos")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(8)
                                } else {
                                    ScrollView {
                                        VStack(alignment: .leading, spacing: 0) {
                                            ForEach(filteredSections, id: \.header) { section in
                                                Text(section.header)
                                                    .font(.system(.caption2, design: .monospaced))
                                                    .fontWeight(.semibold)
                                                    .foregroundColor(.secondary)
                                                    .padding(.horizontal, 8)
                                                    .padding(.top, 8)
                                                    .padding(.bottom, 4)

                                                ForEach(section.repos, id: \.self) { r in
                                                    Button(action: {
                                                        repo = r
                                                        showRepoPicker = false
                                                        repoSearchText = ""
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
                                                }

                                                if section.header != filteredSections.last?.header {
                                                    Divider()
                                                        .padding(.top, 4)
                                                }
                                            }
                                        }
                                    }
                                    .frame(maxHeight: 200)
                                }
                            }
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

                    // Isolation Mode
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Isolation Mode")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Picker("Isolation Mode", selection: $selectedIsolation) {
                            ForEach(IsolationSelection.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.menu)

                        // Warning for container isolation
                        if selectedIsolation == .container {
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                    .font(.caption)
                                Text("Requires macOS 26.0+")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // GUI Access
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(isOn: $enableGUI) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Enable GUI Access")
                                    .font(.subheadline)
                                Text("Allow runner to access display (default: headless)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
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
        .frame(width: 400, height: 480)
    }

    private func loadRepos() async {
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        errorMessage = nil

        do {
            let allRepos = try await GHCLIService.shared.listAllRepos()
            var sections: [(header: String, repos: [String])] = []

            if !allRepos.personal.isEmpty {
                sections.append((header: "Personal", repos: allRepos.personal.sorted()))
            }
            for (org, repos) in allRepos.orgRepos where !repos.isEmpty {
                sections.append((header: org, repos: repos.sorted()))
            }

            repoSections = sections
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
                labels: labels.isEmpty ? ["macos"] : labels,
                isolationMode: selectedIsolation.isolationMode,
                enableGUI: enableGUI
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
