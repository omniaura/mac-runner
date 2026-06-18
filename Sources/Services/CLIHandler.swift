import Foundation

enum CLIHandler {
    static var version: String {
        version(executablePath: CommandLine.arguments.first)
    }

    static func version(executablePath: String?, mainBundle: Bundle = .main) -> String {
        if let bundledVersion = bundleVersion(from: mainBundle) {
            return bundledVersion
        }

        guard let executablePath else {
            return "dev"
        }

        let resolvedPath: String
        if !executablePath.contains("/"),
           let pathResolved = resolveFromPATH(executablePath) {
            resolvedPath = pathResolved
        } else {
            resolvedPath = executablePath
        }

        let executableURL = URL(fileURLWithPath: resolvedPath).resolvingSymlinksInPath()

        if let appBundleURL = enclosingAppBundleURL(for: executableURL),
           let appBundle = Bundle(url: appBundleURL),
           let bundledVersion = bundleVersion(from: appBundle) {
            return bundledVersion
        }

        return "dev"
    }

    private static func resolveFromPATH(_ name: String) -> String? {
        guard let pathEnv = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private static func bundleVersion(from bundle: Bundle) -> String? {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static func enclosingAppBundleURL(for executableURL: URL) -> URL? {
        var currentURL = executableURL.deletingLastPathComponent()

        while currentURL.path != "/" {
            if currentURL.pathExtension == "app" {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL == currentURL {
                break
            }

            currentURL = parentURL
        }

        return nil
    }

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
          add <target>      Add a new runner (repo by default; pass --org for org-level)
          remove <name>     Remove a runner
          start <name>      Start a runner
          stop <name>       Stop a runner
          status            Show runner status summary
          setup             Set up dedicated user isolation
          help              Show this help message
          version           Show version

        ADD OPTIONS:
          --org                Register an organization-level runner (target is the org login)
          --repo               Register a repository-level runner (default)
          --name <name>        Runner name (default: auto-generated)
          --labels <l1,l2>     Comma-separated labels (default: macos)
          --isolation <mode>   Isolation mode: none|user|container (default: global)
          --enable-gui         Enable GUI access (default: headless)

        SETUP OPTIONS:
          --teardown        Remove isolation (delete user, sudoers, reset config)

        EXAMPLES:
          mac-runner auth
          mac-runner add owner/repo --name my-runner --labels macos,arm64
          mac-runner add my-org --org --labels macos,arm64
          mac-runner add owner/repo --isolation container
          mac-runner add owner/repo --isolation user
          mac-runner add owner/repo --enable-gui
          mac-runner list
          mac-runner start my-runner
          mac-runner stop my-runner
          mac-runner remove my-runner
          sudo mac-runner setup
          sudo mac-runner setup --teardown
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

        let globalMode = manager.currentSettings.isolationMode

        // Pre-compute isolation text for column sizing
        let isolationTexts = runners.map { runner -> String in
            let effective = runner.effectiveIsolationMode(global: globalMode)
            let isInherited = runner.isolationMode == nil
            return "\(effective.icon) \(effective.displayName)\(isInherited ? " (global)" : "")"
        }

        // Display the scope alongside the identifier so org-level runners are
        // visually distinguishable from repo-level runners with similar names.
        let targets = runners.map { runner -> String in
            runner.scope == .org ? "\(runner.repo) (org)" : runner.repo
        }

        // Table header
        let nameW = max(runners.map(\.name.count).max() ?? 4, 4)
        let repoW = max(targets.map(\.count).max() ?? 4, 6)
        let isoW = max(isolationTexts.map(\.count).max() ?? 9, 9)

        let header = "  \("NAME".padding(toLength: nameW, withPad: " ", startingAt: 0))  \("TARGET".padding(toLength: repoW, withPad: " ", startingAt: 0))  STATUS      \("ISOLATION".padding(toLength: isoW, withPad: " ", startingAt: 0))  GUI       LABELS"
        print(header)

        for ((runner, isolationText), target) in zip(zip(runners, isolationTexts), targets) {
            let status = "\(runner.status.icon) \(runner.status.rawValue)"
            let labels = runner.labels.joined(separator: ",")
            let guiStatus = runner.enableGUI ? "enabled " : "headless"
            let line = "  \(runner.name.padding(toLength: nameW, withPad: " ", startingAt: 0))  \(target.padding(toLength: repoW, withPad: " ", startingAt: 0))  \(status.padding(toLength: 10, withPad: " ", startingAt: 0))  \(isolationText.padding(toLength: isoW, withPad: " ", startingAt: 0))  \(guiStatus)  \(labels)"
            print(line)
        }
    }

    @MainActor
    private static func handleAdd(args: [String]) async {
        guard let target = args.first else {
            print("Error: repository or organization required")
            print("Usage: mac-runner add <owner/repo> [--name <name>] [--labels <l1,l2>] [--isolation <mode>] [--enable-gui] [--open-files <limit>]")
            print("       mac-runner add <org> --org [--name <name>] [--labels <l1,l2>] [--isolation <mode>] [--enable-gui] [--open-files <limit>]")
            return
        }

        var name = "mac-runner-\(ProcessInfo.processInfo.hostName.prefix(8))-\(Int.random(in: 1000...9999))"
        var labels = ["macos", "mac-runner"]
        var isolationMode: IsolationMode? = nil
        var enableGUI = false
        var openFileLimit: Int? = nil
        var scope: RunnerScope = .repo

        // Parse optional flags
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--org":
                scope = .org
                i += 1
            case "--repo":
                scope = .repo
                i += 1
            case "--name" where i + 1 < args.count:
                name = args[i + 1]
                i += 2
            case "--labels" where i + 1 < args.count:
                labels = args[i + 1].split(separator: ",").map(String.init)
                i += 2
            case "--isolation" where i + 1 < args.count:
                let mode = args[i + 1].lowercased()
                switch mode {
                case "none":
                    isolationMode = .none
                case "user":
                    isolationMode = .dedicatedUser(username: IsolationMode.defaultUsername)
                case "container":
                    isolationMode = .container
                default:
                    print("Error: invalid isolation mode '\(mode)'. Valid options: none, user, container")
                    return
                }
                i += 2
            case "--enable-gui":
                enableGUI = true
                i += 1
            case "--open-files" where i + 1 < args.count:
                guard let parsed = Int(args[i + 1]), parsed > 0 else {
                    print("Error: --open-files must be a positive integer")
                    return
                }
                openFileLimit = parsed
                i += 2
            default:
                i += 1
            }
        }

        // Validate the identifier shape against the chosen scope.
        switch scope {
        case .repo:
            guard target.contains("/") else {
                print("Error: repository required in owner/repo format (or pass --org to register an organization runner)")
                return
            }
        case .org:
            guard !target.contains("/") else {
                print("Error: --org expects an organization login only (no slashes)")
                return
            }
        }

        // Check auth first
        let authState = await GHCLIService.shared.validateAuth()
        guard authState.isAuthenticated else {
            print("Error: \(authState.recoveryMessage)")
            return
        }

        let scopeLabel = scope == .org ? "\(target) (org)" : target
        print("Adding runner '\(name)' for \(scopeLabel)...")
        let manager = RunnerManager()
        do {
            try await manager.addRunner(
                name: name,
                repo: target,
                scope: scope,
                labels: labels,
                isolationMode: isolationMode,
                enableGUI: enableGUI,
                openFileLimit: openFileLimit
            )
            var message = "Runner '\(name)' added"
            if let mode = isolationMode {
                message += " with \(mode.displayName) isolation"
            } else {
                message += " (using global isolation mode)"
            }
            message += enableGUI ? " with GUI access" : " (headless)"
            if let openFileLimit {
                message += " and open file limit \(openFileLimit)"
            }
            message += " and started successfully!"
            print(message)
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
            print("  Global isolation: disabled")
        case .dedicatedUser(let username):
            print("  Global isolation: user (\(username))")
        case .container:
            print("  Global isolation: container")
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
