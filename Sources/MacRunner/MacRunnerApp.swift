import SwiftUI
import AppKit
import Combine

extension Notification.Name {
    static let openSettings = Notification.Name("openSettings")
}

struct MacRunnerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    let runnerManager = RunnerManager()
    private var settingsWindow: NSWindow?
    private var logWindows: [UUID: NSWindow] = [:]
    private var iconAnimator: StatusItemIconAnimator?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        JobNotificationService.shared.configure()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.action = #selector(togglePopover)
            button.target = self
        }
        iconAnimator = StatusItemIconAnimator(button: statusItem.button)
        updateStatusItemIcon()

        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 430)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView().environmentObject(runnerManager)
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenSettings),
            name: .openSettings,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenRunnerLogs(_:)),
            name: .openRunnerLogs,
            object: nil
        )

        // Busy state changes arrive via objectWillChange (status polling doesn't
        // reassign `runners`), so observe the whole manager.
        runnerManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusItemIcon()
            }
            .store(in: &cancellables)

        NSWorkspace.shared.notificationCenter.publisher(
            for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.updateStatusItemIcon()
        }
        .store(in: &cancellables)

        Task { await runnerManager.autoRestartRunners() }
        runnerManager.startAutomation()
        Task { await runnerManager.checkForUpdates() }
    }

    private func updateStatusItemIcon() {
        let runners = runnerManager.runners
        let updateAvailable = runnerManager.availableUpdate != nil
        iconAnimator?.apply(
            StatusItemIcon.state(
                runners: runners,
                updateAvailable: updateAvailable,
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ),
            toolTip: StatusItemIcon.toolTip(runners: runners, updateAvailable: updateAvailable)
        )
    }

    @objc func togglePopover() {
        if let button = statusItem.button {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    @objc func handleOpenSettings() {
        popover.performClose(nil)

        // Must switch to .regular BEFORE showing the window —
        // macOS ignores makeKeyAndOrderFront for .accessory apps.
        NSApp.setActivationPolicy(.regular)

        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsView().environmentObject(runnerManager)
        )

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Mac Runner Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 400, height: 420))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window

        // Revert to .accessory (hide dock icon) when settings closes
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settingsWindow = nil
                self?.restoreAccessoryPolicyIfNoWindows()
            }
        }
    }

    @objc func handleOpenRunnerLogs(_ notification: Notification) {
        guard let id = notification.object as? UUID,
              let runner = runnerManager.runners.first(where: { $0.id == id }) else { return }
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular)

        if let window = logWindows[id] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let manager = runnerManager
        let model = LogViewerModel(runner: runner) { [weak manager] source in
            guard let manager, let current = manager.runners.first(where: { $0.id == id }) else { return nil }
            return manager.logPath(for: current, source: source)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: LogViewerView(model: model)))
        window.title = "\(runner.name) — Logs"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 860, height: 520))
        window.setFrameAutosaveName("RunnerLogs")
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logWindows[id] = window

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.logWindows.removeValue(forKey: id)
                self?.restoreAccessoryPolicyIfNoWindows()
            }
        }
    }

    /// Hide the dock icon again once no Mac Runner windows remain open.
    private func restoreAccessoryPolicyIfNoWindows() {
        guard settingsWindow == nil, logWindows.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
