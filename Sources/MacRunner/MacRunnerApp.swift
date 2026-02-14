import SwiftUI
import AppKit

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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "figure.run", accessibilityDescription: "Mac Runner")
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: 400)
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

        Task { await runnerManager.autoRestartRunners() }
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
        window.setContentSize(NSSize(width: 400, height: 300))
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
            self?.settingsWindow = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
