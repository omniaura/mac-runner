import Foundation

enum SetupWizard {
    nonisolated(unsafe) private static let isolationService = UserIsolationService.shared

    static func detectedIsolationUsername(
        configuredIsolationMode: IsolationMode,
        defaultUsername: String = IsolationMode.defaultUsername,
        userExists: (String) -> Bool,
        hasSudoersEntry: () -> Bool
    ) -> String? {
        if case .dedicatedUser(let username) = configuredIsolationMode {
            return username
        }

        if userExists(defaultUsername) || hasSudoersEntry() {
            return defaultUsername
        }

        return nil
    }

    // MARK: - Setup

    @MainActor
    static func runSetup() async {
        // Require root — all setup operations need administrator privileges.
        // Running with sudo ensures clean terminal I/O (no mid-flow password
        // prompts) and a cached credential for all child sudo -n calls.
        guard geteuid() == 0 else {
            print("Error: setup requires administrator privileges.")
            print("Run: sudo mac-runner setup")
            return
        }

        let configService = ConfigService()
        let config: RunnerConfig
        do {
            config = try configService.loadConfig()
        } catch {
            print("Error: Failed to load config: \(error.localizedDescription)")
            return
        }

        // Check if already enabled
        if case .dedicatedUser(let username) = config.settings.isolationMode {
            print("Isolation is already enabled (user: \(username)).")
            print("Run 'sudo mac-runner setup --teardown' to disable.")
            return
        }

        let username = IsolationMode.defaultUsername

        // Explain what we're about to do
        print("""
        Mac Runner User Isolation Setup
        ================================

        This will create a dedicated macOS system user '\(username)' to run
        GitHub Actions runners in an isolated session. CI jobs will no longer
        be able to interfere with your desktop (no DMG popups, Finder windows, etc).

        What this does:
          1. Creates a hidden system user '\(username)'
          2. Sets up a home directory at /Users/\(username)
          3. Installs a sudoers entry for passwordless runner management
          4. Updates your mac-runner config to use isolated mode
        """)

        print("Proceed with setup? [y/N] ", terminator: "")
        guard let response = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
              response == "y" || response == "yes" else {
            print("Setup cancelled.")
            return
        }

        // Step 1: Create user (or skip if exists)
        if isolationService.userExists(username) {
            print("User '\(username)' already exists, skipping creation.")
        } else {
            print("Creating system user '\(username)'...")
            do {
                try isolationService.createUser(username: username)
                print("  User created successfully.")
            } catch {
                print("Error: \(error.localizedDescription)")
                return
            }
        }

        // Step 2: Set up home directory
        print("Setting up home directory...")
        do {
            try isolationService.setupHomeDirectory(for: username)
            print("  Home directory configured at /Users/\(username)")
        } catch {
            print("Error: \(error.localizedDescription)")
            return
        }

        // Step 3: Install sudoers entry
        // When running via sudo, NSUserName() returns "root".
        // SUDO_USER contains the actual invoking user.
        let mainUser = ProcessInfo.processInfo.environment["SUDO_USER"] ?? NSUserName()
        if mainUser == "root" {
            print("Skipping sudoers entry (root already has full privileges).")
        } else {
            print("Installing sudoers entry for '\(mainUser)'...")
            do {
                try isolationService.installSudoersEntry(mainUsername: mainUser, serviceUsername: username)
                print("  Sudoers entry installed.")
            } catch {
                print("Error: \(error.localizedDescription)")
                return
            }
        }

        // Step 4: Verify tool access
        print("Verifying tool access...")
        let tools = ["/opt/homebrew/bin/gh", "/usr/bin/git", "/usr/bin/xcodebuild"]
        for tool in tools {
            if FileManager.default.fileExists(atPath: tool) {
                let name = URL(fileURLWithPath: tool).lastPathComponent
                print("  \(name): found")
            }
        }

        // Step 5: Update config
        var updatedSettings = config.settings
        updatedSettings.isolationMode = .dedicatedUser(username: username)
        let updatedConfig = RunnerConfig(runners: config.runners, settings: updatedSettings)
        do {
            try configService.saveConfig(updatedConfig)
        } catch {
            print("Error: Failed to save config: \(error.localizedDescription)")
            return
        }

        print("""

        Setup complete!

        New runners added with 'mac-runner add' will run as '\(username)'.
        Existing runners are NOT migrated — remove and re-add them to use isolation.

        To disable isolation: mac-runner setup --teardown
        """)
    }

    // MARK: - Teardown

    @MainActor
    static func runTeardown() async {
        guard geteuid() == 0 else {
            print("Error: teardown requires administrator privileges.")
            print("Run: sudo mac-runner setup --teardown")
            return
        }

        let configService = ConfigService()
        let config: RunnerConfig
        do {
            config = try configService.loadConfig()
        } catch {
            print("Error: Failed to load config: \(error.localizedDescription)")
            return
        }

        guard let username = detectedIsolationUsername(
            configuredIsolationMode: config.settings.isolationMode,
            userExists: isolationService.userExists,
            hasSudoersEntry: isolationService.hasSudoersEntry
        ) else {
            print("Isolation is not currently enabled.")
            return
        }

        if case .dedicatedUser = config.settings.isolationMode {
            // Config and system state agree; no extra note needed.
        } else {
            print("Found existing isolation artifacts for '\(username)' even though config is not enabled.")
            print("Continuing with teardown cleanup.")
            print("")
        }

        // Check for running runners
        let runningRunners = config.runners.filter { $0.status == .running }
        if !runningRunners.isEmpty {
            print("Error: \(runningRunners.count) runner(s) are still running.")
            print("Stop all runners first: mac-runner stop <name>")
            return
        }

        print("""
        Mac Runner User Isolation Teardown
        ====================================

        This will:
          1. Remove the sudoers entry
          2. Delete the '\(username)' user and home directory
          3. Reset mac-runner to run as your current user

        WARNING: Any runner data in /Users/\(username) will be deleted.
        """)

        print("Proceed with teardown? [y/N] ", terminator: "")
        guard let response = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
              response == "y" || response == "yes" else {
            print("Teardown cancelled.")
            return
        }

        // Step 1: Remove sudoers entry
        print("Removing sudoers entry...")
        do {
            try isolationService.removeSudoersEntry()
            print("  Sudoers entry removed.")
        } catch {
            print("Warning: \(error.localizedDescription)")
        }

        // Step 2: Delete user and home
        if isolationService.userExists(username) {
            print("Deleting user '\(username)' and home directory...")
            do {
                try isolationService.deleteUser(username: username, removeHome: true)
                print("  User deleted.")
            } catch {
                print("Warning: \(error.localizedDescription)")
            }
        }

        // Step 3: Reset config
        var updatedSettings = config.settings
        updatedSettings.isolationMode = .none
        let updatedConfig = RunnerConfig(runners: config.runners, settings: updatedSettings)
        do {
            try configService.saveConfig(updatedConfig)
        } catch {
            print("Error: Failed to save config: \(error.localizedDescription)")
            return
        }

        print("""

        Teardown complete!

        Runners will now execute as your current user.
        """)
    }
}
