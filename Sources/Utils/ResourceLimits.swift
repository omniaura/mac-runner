import Foundation

enum ResourceLimits {
    static let defaultOpenFileLimit = 65_536

    static func normalizedOpenFileLimit(_ limit: Int?) -> Int? {
        guard let limit, limit > 0 else { return nil }
        return limit
    }

    static func shellPrefix(openFileLimit: Int?) -> String {
        guard let limit = normalizedOpenFileLimit(openFileLimit) else {
            return ""
        }

        return "ulimit -n \(limit) 2>/dev/null || ulimit -n \"$(ulimit -Hn)\" 2>/dev/null || true && "
    }

    static func shellCommand(_ command: String, openFileLimit: Int?) -> String {
        shellPrefix(openFileLimit: openFileLimit) + command
    }
}
