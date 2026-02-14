import Foundation

/// Utilities for checking system requirements for various features.
enum SystemRequirements {
    /// Minimum macOS version required for container isolation.
    static let containerIsolationMinimumOS = OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)

    /// Checks if the current system supports container isolation.
    ///
    /// Container isolation requires:
    /// - macOS 26.0 or later
    /// - Apple Silicon (arm64 architecture)
    ///
    /// - Returns: `true` if container isolation is supported, `false` otherwise.
    static func supportsContainerIsolation() -> Bool {
        // Check macOS version
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        guard osVersion >= containerIsolationMinimumOS else {
            return false
        }

        // Check for Apple Silicon
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Returns a user-friendly string describing the current system's container isolation support.
    static func containerIsolationStatusMessage() -> String {
        if supportsContainerIsolation() {
            return "Container isolation is available (macOS \(currentOSVersionString()), Apple Silicon)"
        } else {
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            if osVersion < containerIsolationMinimumOS {
                return "Container isolation requires macOS 26 or later (current: \(currentOSVersionString()))"
            } else {
                return "Container isolation requires Apple Silicon"
            }
        }
    }

    /// Returns the current macOS version as a string (e.g., "13.5.0").
    private static func currentOSVersionString() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

// MARK: - OperatingSystemVersion Comparable

extension OperatingSystemVersion: Comparable {
    public static func < (lhs: OperatingSystemVersion, rhs: OperatingSystemVersion) -> Bool {
        if lhs.majorVersion != rhs.majorVersion {
            return lhs.majorVersion < rhs.majorVersion
        }
        if lhs.minorVersion != rhs.minorVersion {
            return lhs.minorVersion < rhs.minorVersion
        }
        return lhs.patchVersion < rhs.patchVersion
    }
}
