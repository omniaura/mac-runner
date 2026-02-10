import Foundation

enum CLIHandler {
    static let version = "1.1.0"

    @MainActor
    static func handle(arguments: [String]) async -> Bool {
        // arguments[0] is the binary path; real args start at [1]
        let args = Array(arguments.dropFirst())

        guard let command = args.first else {
            return false // no CLI args → launch GUI
        }

        switch command {
        case "help", "--help", "-h":
            printUsage()
        case "version", "--version", "-v":
            print("mac-runner \(version)")
        case "auth":
            await handleAuth()
        case "list":
            await handleList()
        case "add":
            await handleAdd(args: Array(args.dropFirst()))
        case "remove":
            await handleRemove(args: Array(args.dropFirst()))
        case "start":
            await handleStart(args: Array(args.dropFirst()))
        case "stop":
            await handleStop(args: Array(args.dropFirst()))
        case "status":
            await handleStatus()
        case "setup":
            await handleSetup(args: Array(args.dropFirst()))
        default:
            print("Unknown command: \(command)")
            printUsage()
        }

        return true // handled as CLI
    }

    // MARK: - Commands

    private static func printUsage() {
        print("""
        mac-runner - GitHub Actions self-hosted runner manager

        USAGE:
          mac-runner                     Launch GUI (menu bar app)
          mac-runner <command> [options]  Run CLI command

        COMMANDS:
          auth              Show GitHub authentication status
          list              List configured runners
          add <repo>        Add a new runner
          remove <name>     Remove a runner
          start <name>      Start a runner
          stop <name>       Stop a runner
          status            Show runner status summary
          setup             Set up dedicated user isolation
          help              Show this help message
          version           Show version

        ADD OPTIONS:
          --name <name>     Runner name (default: auto-generated)
          --labels <l1,l2>  Comma-separated labels (default: macos)

        SETUP OPTIONS:
          --teardown        Remove isolation (delete user, sudoers, reset config)

        EXAMPLES:
          mac-runner auth
          mac-runner add owner/repo --name my-runner --labels macos,arm64
          mac-runner list
          mac-runner start my-runner
          mac-runner stop my-runner
          mac-runner remove my-runner
          mac-runner setup
          mac-runner setup --teardown
        """)
    }

    @MainActor
    private static func handleAuth() async {
        let status = await GHCLIService.shared.authStatus()
        print(status)
    }

    @MainActor
    private static func handleList() async {
        let manager = RunnerManager()
        let runners = manager.runners

        if runners.isEmpty {
            print("No runners configured.")
            return
        }

        // Table header
        let nameW = max(runners.map(\.name.count).max() ?? 4, 4)
        let repoW = max(runners.map(\.repo.count).max() ?? 4, 4)

        let header = "  \("NAME".padding(toLength: nameW, withPad: " ", startingAt: 0))  \("REPO".padding(toLength: repoW, withPad: " ", startingAt: 0))  STATUS      LABELS"
        print(header)

        for runner in runners {
            let status = "\(runner.status.icon) \(runner.status.rawValue)"
            let labels = runner.labels.joined(separator: ",")
            let line = "  \(runner.name.padding(toLength: nameW, withPad: " ", startingAt: 0))  \(runner.repo.padding(toLength: repoW, withPad: " ", startingAt: 0))  \(status.padding(toLength: 10, withPad: " ", startingAt: 0))  \(labels)"
            print(line)
        }
    }

    @MainActor
    private static func handleAdd(args: [String]) async {
        guard let repo = args.first, repo.contains("/") else {
            print("Error: repository required in owner/repo format")
            print("Usage: mac-runner add <owner/repo> [--name <name>] [--labels <l1,l2>]")
            return
        }

        var name = "mac-runner-\(ProcessInfo.processInfo.hostName.prefix(8))-\(Int.random(in: 1000...9999))"
        var labels = ["macos", "mac-runner"]

        // Parse optional flags
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--name" where i + 1 < args.count:
                name = args[i + 1]
                i += 2
            case "--labels" where i + 1 < args.count:
                labels = args[i + 1].split(separator: ",").map(String.init)
                i += 2
            default:
                i += 1
            }
        }

        // Check auth first
        let authenticated = await GHCLIService.shared.checkAuth()
        guard authenticated else {
            print("Error: not authenticated with GitHub. Run: gh auth login")
            return
        }

        print("Adding runner '\(name)' for \(repo)...")
        let manager = RunnerManager()
        do {
            try await manager.addRunner(name: name, repo: repo, labels: labels)
            print("Runner '\(name)' added and started successfully!")
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func handleRemove(args: [String]) async {
        guard let name = args.first else {
            print("Error: runner name required")
            print("Usage: mac-runner remove <name>")
            return
        }

        let manager = RunnerManager()
        guard let runner = manager.runner(named: name) else {
            print("Error: runner '\(name)' not found")
            return
        }

        print("Removing runner '\(name)'...")
        do {
            try await manager.removeRunner(runner.id)
            print("Runner '\(name)' removed.")
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func handleStart(args: [String]) async {
        guard let name = args.first else {
            print("Error: runner name required")
            print("Usage: mac-runner start <name>")
            return
        }

        let manager = RunnerManager()
        guard let runner = manager.runner(named: name) else {
            print("Error: runner '\(name)' not found")
            return
        }

        print("Starting runner '\(name)'...")
        do {
            try await manager.startRunner(runner.id)
            print("Runner '\(name)' started.")
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func handleStop(args: [String]) async {
        guard let name = args.first else {
            print("Error: runner name required")
            print("Usage: mac-runner stop <name>")
            return
        }

        let manager = RunnerManager()
        guard let runner = manager.runner(named: name) else {
            print("Error: runner '\(name)' not found")
            return
        }

        print("Stopping runner '\(name)'...")
        do {
            try await manager.stopRunner(runner.id)
            print("Runner '\(name)' stopped.")
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func handleStatus() async {
        let manager = RunnerManager()
        let runners = manager.runners

        let running = runners.filter { $0.status == .running }.count
        let stopped = runners.filter { $0.status == .stopped }.count
        let paused = runners.filter { $0.status == .paused }.count
        let errored = runners.filter { $0.status == .error }.count

        print("mac-runner Status")
        print("  Total runners: \(runners.count)")
        print("  Running: \(running)")
        print("  Stopped: \(stopped)")
        if paused > 0 { print("  Paused: \(paused)") }
        if errored > 0 { print("  Errors: \(errored)") }

        let authenticated = await GHCLIService.shared.checkAuth()
        print("  GitHub auth: \(authenticated ? "authenticated" : "not authenticated")")

        switch manager.currentSettings.isolationMode {
        case .none:
            print("  Isolation: disabled")
        case .dedicatedUser(let username):
            print("  Isolation: enabled (user: \(username))")
        }
    }

    @MainActor
    private static func handleSetup(args: [String]) async {
        if args.contains("--teardown") {
            await SetupWizard.runTeardown()
        } else {
            await SetupWizard.runSetup()
        }
    }
}
