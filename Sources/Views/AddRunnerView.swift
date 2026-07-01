import AppKit
import SwiftUI

struct AddRunnerView: View {
    @EnvironmentObject var runnerManager: RunnerManager
    @Environment(\.dismiss) var dismiss

    @State private var repo = ""
    @State private var scope: RunnerScope = .repo
    @State private var name = ""
    @State private var labelsText = "macos, mac-runner"
    @State private var selectedIsolation: IsolationSelection = .global
    @State private var enableGUI = false
    @State private var openFileLimitText = ""
    @State private var repoSections: [(header: String, repos: [String])] = []
    @State private var orgs: [String] = []
    @State private var repoSearchText = ""
    @State private var isLoadingRepos = false
    @State private var showRepoPicker = false
    @State private var numberOfInstances = 1
    @State private var isAdding = false
    @State private var addingProgress: (current: Int, total: Int)?
    @State private var errorMessage: String?
    @State private var recoveryStatusMessage: String?

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

    private var shouldShowAdminOrgRecovery: Bool {
        guard let errorMessage else { return false }
        return GHCLIService.requiresAdminOrgScope(errorMessage)
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
                    // Target Type (Repository vs Organization)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Target Type")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Picker("Target Type", selection: $scope) {
                            Text("Repository").tag(RunnerScope.repo)
                            Text("Organization").tag(RunnerScope.org)
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: scope) { _, _ in
                            // Clear the identifier so users don't accidentally register
                            // "omniaura/mac-runner" as an org or just "omniaura" as a repo.
                            repo = ""
                            showRepoPicker = false
                        }

                        if scope == .org {
                            HStack(spacing: 6) {
                                Image(systemName: "info.circle")
                                    .foregroundColor(.secondary)
                                    .font(.caption)
                                Text("Requires org admin permission. Jobs from any repo in the org can target this runner.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    // Target identifier (repo or org)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(scope == .org ? "Organization" : "Repository")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack {
                            TextField(scope == .org ? "org-login" : "owner/repo", text: $repo)
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

                        if showRepoPicker {
                            if scope == .repo, !repoSections.isEmpty {
                                repoPickerList
                            } else if scope == .org, !orgs.isEmpty {
                                orgPickerList
                            }
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

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Open Files Limit")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        TextField("Global default (optional)", text: $openFileLimitText)
                            .textFieldStyle(.roundedBorder)

                        Text("Leave blank to inherit the global setting.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    // Number of Instances
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Number of Instances")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack {
                            Stepper(value: $numberOfInstances, in: 1...20) {
                                Text("\(numberOfInstances)")
                                    .font(.system(.body, design: .monospaced))
                                    .frame(minWidth: 24, alignment: .center)
                            }
                        }

                        if numberOfInstances > 1 {
                            let baseName = name.isEmpty ? "mac-runner" : name
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(1...min(numberOfInstances, 5), id: \.self) { i in
                                    Text("\(baseName)-\(i)")
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                                if numberOfInstances > 5 {
                                    Text("... and \(numberOfInstances - 5) more")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }

                    if let error = errorMessage {
                        ErrorRecoveryView(
                            message: error,
                            showAdminOrgRecovery: shouldShowAdminOrgRecovery,
                            recoveryStatusMessage: recoveryStatusMessage,
                            onCopyError: { copyToPasteboard(error) },
                            onCopyCommand: { copyToPasteboard(GitHubAuthRecovery.adminOrgRefreshCommand) },
                            onOpenReauth: openAdminOrgReauth
                        )
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
                    if let progress = addingProgress, progress.total > 1 {
                        Text("\(progress.current)/\(progress.total)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 8)
                }

                Button(numberOfInstances > 1 ? "Add \(numberOfInstances) Runners" : "Add Runner") {
                    Task { await addRunner() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(repo.isEmpty || isAdding)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 680)
    }

    @ViewBuilder
    private var repoPickerList: some View {
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

    @ViewBuilder
    private var orgPickerList: some View {
        let filtered = repoSearchText.isEmpty
            ? orgs
            : orgs.filter { $0.lowercased().contains(repoSearchText.lowercased()) }

        VStack(spacing: 0) {
            TextField("Search orgs...", text: $repoSearchText)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .padding(6)

            Divider()

            if filtered.isEmpty {
                Text("No matching orgs")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(8)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered, id: \.self) { org in
                            Button(action: {
                                repo = org
                                showRepoPicker = false
                                repoSearchText = ""
                            }) {
                                HStack {
                                    Text(org)
                                        .font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    if org == repo {
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

    private func loadRepos() async {
        isLoadingRepos = true
        defer { isLoadingRepos = false }
        errorMessage = nil
        recoveryStatusMessage = nil

        do {
            if scope == .org {
                orgs = try await GHCLIService.shared.listOrgs().sorted()
                showRepoPicker = true
                return
            }

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
        addingProgress = nil
        defer {
            isAdding = false
            addingProgress = nil
        }
        errorMessage = nil
        recoveryStatusMessage = nil

        let baseName = name.isEmpty
            ? "mac-runner-\(Int.random(in: 1000...9999))"
            : name

        let labels = labelsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let trimmedOpenFileLimit = openFileLimitText.trimmingCharacters(in: .whitespaces)
        let openFileLimit: Int?
        if trimmedOpenFileLimit.isEmpty {
            openFileLimit = nil
        } else if let parsed = Int(trimmedOpenFileLimit), parsed > 0 {
            openFileLimit = parsed
        } else {
            errorMessage = "Open files limit must be a positive integer."
            return
        }

        // Surface obvious format mistakes before hitting the network.
        let trimmedRepo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        switch scope {
        case .repo:
            guard trimmedRepo.contains("/") else {
                errorMessage = "Repository must be in 'owner/repo' format."
                return
            }
        case .org:
            guard !trimmedRepo.isEmpty, !trimmedRepo.contains("/") else {
                errorMessage = "Organization must be the org login only (no slashes)."
                return
            }
        }

        do {
            try await runnerManager.addRunners(
                baseName: baseName,
                repo: trimmedRepo,
                scope: scope,
                labels: labels.isEmpty ? ["macos"] : labels,
                count: numberOfInstances,
                isolationMode: selectedIsolation.isolationMode,
                enableGUI: enableGUI,
                openFileLimit: openFileLimit,
                onProgress: { current, total in
                    addingProgress = (current: current, total: total)
                }
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        recoveryStatusMessage = "Copied."
    }

    private func openAdminOrgReauth() {
        do {
            try GHCLIService.shared.openAdminOrgReauth()
            recoveryStatusMessage = "Opened GitHub reauth. The device code is on your clipboard."
        } catch {
            recoveryStatusMessage = "Could not open reauth: \(error.localizedDescription)"
        }
    }
}

private struct ErrorRecoveryView: View {
    let message: String
    let showAdminOrgRecovery: Bool
    let recoveryStatusMessage: String?
    let onCopyError: () -> Void
    let onCopyCommand: () -> Void
    let onOpenReauth: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if showAdminOrgRecovery {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Request the missing org-admin scope:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(GitHubAuthRecovery.adminOrgRefreshCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    HStack {
                        Button {
                            onCopyCommand()
                        } label: {
                            Label("Copy Command", systemImage: "doc.on.doc")
                        }

                        Button {
                            onOpenReauth()
                        } label: {
                            Label("Open Reauth", systemImage: "safari")
                        }

                        Spacer()
                    }
                }
            }

            HStack {
                Button {
                    onCopyError()
                } label: {
                    Label("Copy Error", systemImage: "doc.on.clipboard")
                }

                if let recoveryStatusMessage {
                    Text(recoveryStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
