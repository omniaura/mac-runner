import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    /// Posted with the runner's UUID as `object` to open its log window.
    static let openRunnerLogs = Notification.Name("openRunnerLogs")
}

/// Loads and live-tails one runner's log for the log viewer.
@MainActor
final class LogViewerModel: ObservableObject {
    static let maxLines = 5000

    @Published var source: RunnerLogs.Source = .output {
        didSet { if source != oldValue { reload() } }
    }
    @Published var query = ""
    @Published var follow = true
    @Published private(set) var lines: [String] = []
    @Published private(set) var path: String?

    private let runner: Runner
    private let resolvePath: (RunnerLogs.Source) -> String?
    private var follower: LogFollower?
    private var timer: Timer?

    init(runner: Runner, resolvePath: @escaping (RunnerLogs.Source) -> String?) {
        self.runner = runner
        self.resolvePath = resolvePath
        reload()
    }

    var runnerName: String { runner.name }

    var visibleLines: [String] {
        RunnerLogs.filter(lines, matching: query)
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reload() {
        path = resolvePath(source)
        guard let path, FileManager.default.fileExists(atPath: path) else {
            lines = []
            follower = nil
            return
        }
        let tail = RunnerLogs.tail(of: path, count: Self.maxLines)
        lines = tail.lines
        follower = LogFollower(path: path, offset: tail.endOffset)
    }

    func poll() {
        // Diagnostics move to a new file each time the runner restarts or runs a job.
        let latest = resolvePath(source)
        if latest != path || follower == nil {
            reload()
            return
        }
        let newLines = follower?.readNewLines() ?? []
        guard !newLines.isEmpty else { return }
        lines.append(contentsOf: newLines)
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }

    var exportText: String {
        visibleLines.joined(separator: "\n") + "\n"
    }

    func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportText, forType: .string)
    }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.log, .plainText]
        panel.nameFieldStringValue = "\(runner.name)-\(source.rawValue).log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? exportText.write(to: url, atomically: true, encoding: .utf8)
    }

    func revealInFinder() {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

struct LogViewerView: View {
    @ObservedObject var model: LogViewerModel
    private let bottomID = "log-bottom"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Log", selection: $model.source) {
                    ForEach(RunnerLogs.Source.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                TextField("Filter", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140)

                Toggle("Follow", isOn: $model.follow)
                    .toggleStyle(.checkbox)

                Button(action: model.copyToPasteboard) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the shown lines")

                Button(action: model.export) {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .help("Save the shown lines to a file")

                Button(action: model.revealInFinder) {
                    Image(systemName: "folder")
                }
                .help("Show the log file in Finder")
                .disabled(model.path == nil)
            }
            .padding(10)

            Divider()

            if model.lines.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text(model.source == .output ? "No output logged yet" : "No \(model.source.displayName.lowercased()) logs yet")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                logLines
            }

            Divider()

            HStack {
                let visible = model.visibleLines.count
                Text(model.query.isEmpty ? "\(model.lines.count) lines" : "\(visible) of \(model.lines.count) lines match")
                Spacer()
                if let path = model.path {
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .frame(minWidth: 640, minHeight: 360)
        .onAppear(perform: model.start)
        .onDisappear(perform: model.stop)
    }

    private var logLines: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.visibleLines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .padding(8)
                    // A two-axis ScrollView centers smaller content; pin it top-leading.
                    .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .topLeading)
                }
                .onAppear { proxy.scrollTo(bottomID, anchor: .bottom) }
                .onChange(of: model.lines.count) {
                    if model.follow { proxy.scrollTo(bottomID, anchor: .bottom) }
                }
                .onChange(of: model.query) {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
        }
    }
}
