import AppKit

/// What the menu bar icon should show for the current runner state.
enum StatusItemIcon: Equatable {
    /// Cycles through `frames` while at least one runner is executing a job.
    case animated(frames: [String])
    case staticSymbol(String)

    static let idleSymbol = "figure.run"
    static let updateSymbol = "arrow.down.circle.fill"
    /// Shown instead of the animation when Reduce Motion is on.
    static let activeSymbol = "figure.run.circle.fill"
    static let runningFrames = ["figure.run", "figure.walk"]
    static let frameInterval: TimeInterval = 0.4

    static func state(runners: [Runner], updateAvailable: Bool, reduceMotion: Bool) -> StatusItemIcon {
        if activeJobCount(in: runners) > 0 {
            return reduceMotion ? .staticSymbol(activeSymbol) : .animated(frames: runningFrames)
        }
        return .staticSymbol(updateAvailable ? updateSymbol : idleSymbol)
    }

    static func activeJobCount(in runners: [Runner]) -> Int {
        runners.filter { $0.status == .running && $0.busy }.count
    }

    static func toolTip(runners: [Runner], updateAvailable: Bool) -> String {
        let jobs = activeJobCount(in: runners)
        var parts = ["Mac Runner"]
        if jobs > 0 {
            parts.append(jobs == 1 ? "1 job running" : "\(jobs) jobs running")
        }
        if updateAvailable {
            parts.append("update available")
        }
        return parts.joined(separator: " — ")
    }
}

/// Drives the status item button's image, animating while jobs run.
@MainActor
final class StatusItemIconAnimator {
    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var frameIndex = 0
    private var current: StatusItemIcon?

    init(button: NSStatusBarButton?) {
        self.button = button
    }

    func apply(_ icon: StatusItemIcon, toolTip: String) {
        button?.toolTip = toolTip
        guard icon != current else { return }
        current = icon
        timer?.invalidate()
        timer = nil

        switch icon {
        case .staticSymbol(let name):
            setImage(name)
        case .animated(let frames):
            frameIndex = 0
            setImage(frames[0])
            timer = Timer.scheduledTimer(withTimeInterval: StatusItemIcon.frameInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.frameIndex = (self.frameIndex + 1) % frames.count
                    self.setImage(frames[self.frameIndex])
                }
            }
        }
    }

    private func setImage(_ symbolName: String) {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Mac Runner")
        image?.isTemplate = true
        button?.image = image
    }
}
