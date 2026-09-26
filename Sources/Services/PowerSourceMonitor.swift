import Foundation
import IOKit.ps

extension Notification.Name {
    static let powerSourceDidChange = Notification.Name("MacRunnerPowerSourceDidChange")
}

/// Reads the internal battery's state via IOKit and posts `.powerSourceDidChange`
/// when it changes.
@MainActor
final class PowerSourceMonitor {
    private var runLoopSource: CFRunLoopSource?

    /// Current battery state, or nil when the Mac has no internal battery.
    func currentState() -> PowerState? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        let descriptions = sources.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        return Self.state(from: descriptions)
    }

    /// Picks the internal battery out of IOKit power source descriptions.
    nonisolated static func state(from descriptions: [[String: Any]]) -> PowerState? {
        guard let battery = descriptions.first(where: {
            ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
                && ($0[kIOPSIsPresentKey] as? Bool ?? true)
        }) else {
            return nil
        }

        let current = battery[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = battery[kIOPSMaxCapacityKey] as? Int ?? 100
        let level = max > 0 ? Int((Double(current) / Double(max) * 100).rounded()) : current
        let onBattery = (battery[kIOPSPowerSourceStateKey] as? String) == kIOPSBatteryPowerValue

        return PowerState(isOnBattery: onBattery, batteryLevel: Swift.min(Swift.max(level, 0), 100))
    }

    func startObserving() {
        guard runLoopSource == nil else { return }
        let callback: IOPowerSourceCallbackType = { _ in
            NotificationCenter.default.post(name: .powerSourceDidChange, object: nil)
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, nil)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }
}
