import Foundation

enum IsolationError: LocalizedError {
    case userCreationFailed(String)
    case userDeletionFailed(String)
    case sudoersInstallFailed(String)
    case processLaunchFailed(String)
    case killFailed(String)
    case homeSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .userCreationFailed(let msg): return "Failed to create user: \(msg)"
        case .userDeletionFailed(let msg): return "Failed to delete user: \(msg)"
        case .sudoersInstallFailed(let msg): return "Failed to install sudoers entry: \(msg)"
        case .processLaunchFailed(let msg): return "Failed to launch isolated process: \(msg)"
        case .killFailed(let msg): return "Failed to kill process: \(msg)"
        case .homeSetupFailed(let msg): return "Failed to set up home directory: \(msg)"
        }
    }
}

class UserIsolationService {
    nonisolated(unsafe) static let shared = UserIsolationService()

    private let sudoersPath = "/etc/sudoers.d/mac-runner"

    // MARK: - User Management

    func userExists(_ username: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
        process.arguments = [".", "-read", "/Users/\(username)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    func createUser(username: String) throws {
        // Find an available UID in the 400-499 range (system user range)
        let uid = try findAvailableUID()

        let commands: [(String, [String])] = [
            ("Create user record", ["dscl", ".", "-create", "/Users/\(username)"]),
            ("Set UID", ["dscl", ".", "-create", "/Users/\(username)", "UniqueID", String(uid)]),
            ("Set GID (staff=20)", ["dscl", ".", "-create", "/Users/\(username)", "PrimaryGroupID", "20"]),
            ("Set home directory", ["dscl", ".", "-create", "/Users/\(username)", "NFSHomeDirectory", "/Users/\(username)"]),
            ("Set shell", ["dscl", ".", "-create", "/Users/\(username)", "UserShell", "/bin/zsh"]),
            ("Set real name", ["dscl", ".", "-create", "/Users/\(username)", "RealName", "Mac Runner Service"]),
            ("Hide user", ["dscl", ".", "-create", "/Users/\(username)", "IsHidden", "1"]),
            ("Set password to *", ["dscl", ".", "-create", "/Users/\(username)", "Password", "*"]),
        ]

        for (description, args) in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = args
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw IsolationError.userCreationFailed("\(description) failed: \(output)")
            }
        }
    }

    func deleteUser(username: String, removeHome: Bool) throws {
        // Remove user record
        let dscl = Process()
        dscl.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        dscl.arguments = ["dscl", ".", "-delete", "/Users/\(username)"]
        let pipe = Pipe()
        dscl.standardOutput = pipe
        dscl.standardError = pipe
        try dscl.run()
        dscl.waitUntilExit()

        guard dscl.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw IsolationError.userDeletionFailed(output)
        }

        // Remove home directory
        if removeHome {
            let rm = Process()
            rm.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            rm.arguments = ["rm", "-rf", "/Users/\(username)"]
            rm.standardOutput = FileHandle.nullDevice
            rm.standardError = FileHandle.nullDevice
            try rm.run()
            rm.waitUntilExit()
        }
    }

    func setupHomeDirectory(for username: String) throws {
        let homePath = "/Users/\(username)"
        let runnersPath = "\(homePath)/.mac-runner/runners"

        // Create home and runners directory
        let mkdir = Process()
        mkdir.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        mkdir.arguments = ["mkdir", "-p", runnersPath]
        let mkdirPipe = Pipe()
        mkdir.standardOutput = mkdirPipe
        mkdir.standardError = mkdirPipe
        try mkdir.run()
        mkdir.waitUntilExit()

        guard mkdir.terminationStatus == 0 else {
            let output = String(data: mkdirPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw IsolationError.homeSetupFailed("mkdir failed: \(output)")
        }

        // Write .zprofile with Homebrew PATH
        let zprofileContent = """
        # Mac Runner service user profile
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        """
        let zprofilePath = "\(homePath)/.zprofile"

        // Write via sudo tee
        let tee = Process()
        tee.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        tee.arguments = ["tee", zprofilePath]
        let inputPipe = Pipe()
        tee.standardInput = inputPipe
        tee.standardOutput = FileHandle.nullDevice
        tee.standardError = FileHandle.nullDevice
        try tee.run()
        inputPipe.fileHandleForWriting.write(zprofileContent.data(using: .utf8)!)
        inputPipe.fileHandleForWriting.closeFile()
        tee.waitUntilExit()

        // chown the entire home to the service user
        let chown = Process()
        chown.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        chown.arguments = ["chown", "-R", "\(username):staff", homePath]
        chown.standardOutput = FileHandle.nullDevice
        chown.standardError = FileHandle.nullDevice
        try chown.run()
        chown.waitUntilExit()
    }

    // MARK: - Process Management

    func launchAsUser(
        username: String,
        executable: String,
        currentDirectory: String,
        standardOutput: Any? = nil,
        standardError: Any? = nil
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")

        // Use -n (non-interactive) and bash -l to source .zprofile for PATH
        let escapedDir = currentDirectory.replacingOccurrences(of: "'", with: "'\\''")
        let escapedExec = executable.replacingOccurrences(of: "'", with: "'\\''")
        process.arguments = [
            "-n", "-u", username,
            "/bin/bash", "-l", "-c",
            "cd '\(escapedDir)' && '\(escapedExec)'"
        ]

        if let stdout = standardOutput {
            process.standardOutput = stdout
        }
        if let stderr = standardError {
            process.standardError = stderr
        }

        try process.run()
        return process
    }

    func killProcessTree(pid: pid_t, username: String) {
        let descendants = findDescendants(of: pid) + [pid]
        for p in descendants.reversed() {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            kill.arguments = ["-n", "kill", "-TERM", String(p)]
            kill.standardOutput = FileHandle.nullDevice
            kill.standardError = FileHandle.nullDevice
            try? kill.run()
            kill.waitUntilExit()
        }
    }

    private func findDescendants(of pid: pid_t) -> [pid_t] {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let children = output.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
        return children + children.flatMap { findDescendants(of: $0) }
    }

    // MARK: - Sudoers

    func installSudoersEntry(mainUsername: String, serviceUsername: String) throws {
        // Allow the main user to run sudo -u _macrunner for bash and kill without password
        // Restrict bash to specific arguments patterns needed for runner management
        let entry = """
        # Mac Runner: allow \(mainUsername) to manage runner processes as \(serviceUsername)
        \(mainUsername) ALL=(\(serviceUsername)) NOPASSWD: /bin/bash -l -c *
        \(mainUsername) ALL=(\(serviceUsername)) NOPASSWD: /bin/zsh -l -c *
        \(mainUsername) ALL=(root) NOPASSWD: /usr/bin/kill
        \(mainUsername) ALL=(root) NOPASSWD: /bin/mkdir -p /Users/\(serviceUsername)/*
        \(mainUsername) ALL=(root) NOPASSWD: /usr/sbin/chown -R \(serviceUsername)\\:staff /Users/\(serviceUsername)/*
        """

        // Write to a temp file, validate, then move to sudoers.d
        let tempPath = NSTemporaryDirectory() + "mac-runner-sudoers"
        try entry.write(toFile: tempPath, atomically: true, encoding: .utf8)

        // Set correct permissions (sudoers files must be 0440)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["0440", tempPath]
        try chmod.run()
        chmod.waitUntilExit()

        // Validate with visudo
        let visudo = Process()
        visudo.executableURL = URL(fileURLWithPath: "/usr/sbin/visudo")
        visudo.arguments = ["-cf", tempPath]
        let visudoPipe = Pipe()
        visudo.standardOutput = visudoPipe
        visudo.standardError = visudoPipe
        try visudo.run()
        visudo.waitUntilExit()

        guard visudo.terminationStatus == 0 else {
            try? FileManager.default.removeItem(atPath: tempPath)
            let output = String(data: visudoPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw IsolationError.sudoersInstallFailed("Validation failed: \(output)")
        }

        // Move to /etc/sudoers.d/ via sudo
        let mv = Process()
        mv.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        mv.arguments = ["mv", tempPath, sudoersPath]
        let mvPipe = Pipe()
        mv.standardOutput = mvPipe
        mv.standardError = mvPipe
        try mv.run()
        mv.waitUntilExit()

        guard mv.terminationStatus == 0 else {
            let output = String(data: mvPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw IsolationError.sudoersInstallFailed("Failed to install: \(output)")
        }
    }

    func removeSudoersEntry() throws {
        guard FileManager.default.fileExists(atPath: sudoersPath) else { return }

        let rm = Process()
        rm.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        rm.arguments = ["rm", sudoersPath]
        rm.standardOutput = FileHandle.nullDevice
        rm.standardError = FileHandle.nullDevice
        try rm.run()
        rm.waitUntilExit()
    }

    // MARK: - Helpers

    private func findAvailableUID() throws -> Int {
        // Scan 400-499 range for an unused UID
        for uid in 400...499 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/dscl")
            process.arguments = [".", "-search", "/Users", "UniqueID", String(uid)]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return uid
            }
        }
        throw IsolationError.userCreationFailed("No available UID in 400-499 range")
    }
}
