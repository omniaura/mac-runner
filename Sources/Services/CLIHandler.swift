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
        case "uninstall":
            await handleUninstall(args: Array(args.dropFirst()))
        case "cleanup":
            await handleCleanup(args: Array(args.dropFirst()))
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
          cleanup           Remove idle runner workspaces and CI caches
          uninstall         Remove all runners and every file Mac Runner created
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

        CLEANUP OPTIONS:
          --dry-run         Show what would be removed
          --workspaces-only Keep shared language, Homebrew, and Xcode caches

        UNINSTALL OPTIONS:
          --dry-run         Show what would be removed without deleting anything
          --yes, -y         Skip the confirmation prompt
          --include-app     Also delete MacRunner.app and the mac-runner symlink
          --keep-runners    Leave runners registered on GitHub (delete local files only)

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
          mac-runner cleanup --dry-run
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

    @MainActor
    private static func handleUninstall(args: [String]) async {
        let dryRun = args.contains("--dry-run")
        let assumeYes = args.contains("--yes") || args.contains("-y")
        let includeApplication = args.contains("--include-app")
        let keepRunners = args.contains("--keep-runners")

        let config: RunnerConfig
        do {
            config = try ConfigService().loadConfig()
        } catch {
            print("Error: failed to load config: \(error.localizedDescription)")
            return
        }

        let service = UninstallService()
        let plan = service.plan(
            runners: config.runners,
            globalIsolationMode: config.settings.isolationMode,
            includeApplication: includeApplication
        )

        guard !plan.isEmpty else {
            print("Nothing to uninstall - no Mac Runner files found.")
            return
        }

        printPlan(plan, keepRunners: keepRunners)

        if dryRun {
            let size = ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)
            print("")
            print("Dry run: nothing was deleted. \(plan.items.count) item(s), \(size) would be freed.")
            return
        }

        if !assumeYes {
            print("")
            print("This cannot be undone. Continue? [y/N] ", terminator: "")
            guard let response = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
                  response == "y" || response == "yes" else {
                print("Uninstall cancelled.")
                return
            }
        }

        // Stop anything still running so its workspace is not deleted mid-job.
        //
        // RunnerManager is built only when there is something to stop: constructing it
        // pulls in UNUserNotificationCenter, which traps when the CLI runs outside an app
        // bundle - the exact state a user is in when uninstalling after deleting the app.
        let runningRunners = config.runners.filter { $0.status == .running }
        if !runningRunners.isEmpty {
            let manager = RunnerManager()
            for runner in runningRunners {
                print("Stopping '\(runner.name)'...")
                try? await manager.stopRunner(runner.id)
            }
        }

        // Deregister from GitHub before the credentials are deleted, otherwise the
        // runners linger in repository settings as permanently offline entries.
        var deregistered: [String] = []
        var failedDeregistrations: [String] = []
        if !keepRunners {
            for runner in plan.runnersToDeregister {
                guard let ghId = runner.githubRunnerId else { continue }
                do {
                    try await GHCLIService.shared.deleteRunner(target: runner.target, githubRunnerId: ghId)
                    deregistered.append(runner.name)
                } catch {
                    failedDeregistrations.append("\(runner.name) (\(runner.repo))")
                }
            }
        }

        let report = service.execute(
            plan: plan,
            dryRun: false,
            deregistered: deregistered,
            failedDeregistrations: failedDeregistrations
        )

        printReport(report, service: service, includedApplication: includeApplication, keepRunners: keepRunners)
    }

    private static func printPlan(_ plan: UninstallPlan, keepRunners: Bool) {
        print("Mac Runner uninstall")
        print("")

        if !plan.activeRunnerNames.isEmpty {
            print("Running runners (will be stopped): \(plan.activeRunnerNames.joined(separator: ", "))")
            print("")
        }

        if !keepRunners && !plan.runnersToDeregister.isEmpty {
            print("Will deregister from GitHub:")
            for runner in plan.runnersToDeregister {
                print("  \(runner.name)  (\(runner.repo))")
            }
            print("")
        }

        print("Will delete:")
        let pathWidth = min(plan.items.map(\.path.count).max() ?? 0, 72)
        for item in plan.items {
            let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
            let path = abbreviate(item.path)
            let padded = path.padding(toLength: max(pathWidth, path.count), withPad: " ", startingAt: 0)
            print("  \(padded)  \(size.padding(toLength: 10, withPad: " ", startingAt: 0))  \(item.category.rawValue)")
        }

        let total = ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file)
        print("")
        print("Total: \(plan.items.count) item(s), \(total)")
    }

    private static func printReport(
        _ report: UninstallReport,
        service: UninstallService,
        includedApplication: Bool,
        keepRunners: Bool
    ) {
        let size = ByteCountFormatter.string(fromByteCount: report.reclaimedBytes, countStyle: .file)
        print("")
        print("Removed \(report.removedPaths.count) item(s), freed \(size).")

        if !report.deregisteredRunners.isEmpty {
            print("Deregistered from GitHub: \(report.deregisteredRunners.joined(separator: ", "))")
        }

        if !report.failedDeregistrations.isEmpty {
            print("")
            print("Could not deregister: \(report.failedDeregistrations.joined(separator: ", "))")
            print("These remain listed as offline runners. Remove them from the repository's")
            print("Settings > Actions > Runners page.")
        }

        if !report.failedPaths.isEmpty {
            print("")
            print("Could not remove:")
            for path in report.failedPaths {
                print("  \(abbreviate(path))")
            }
        }

        if keepRunners {
            print("")
            print("Runners were left registered on GitHub (--keep-runners).")
        }

        if !includedApplication {
            print("")
            if service.isHomebrewManaged() {
                print("Local data is gone. To remove the app itself, run:")
                print("  brew uninstall --cask mac-runner")
            } else {
                print("Local data is gone. To remove the app itself, re-run with --include-app")
                print("or delete /Applications/MacRunner.app manually.")
            }
        }
    }

    /// Render a home-relative path as `~/...` so plan output stays readable.
    ///
    /// Matching must land on a path boundary: a bare prefix test rewrites
    /// `/Users/bobby/data` as `~by/data` for home `/Users/bob`. This list is what a user
    /// reads before confirming a destructive action, so every path shown must be exact.
    static func abbreviate(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func handleCleanup(args: [String]) async {
        let dryRun = args.contains("--dry-run")
        let includeSharedCaches = !args.contains("--workspaces-only")
        do {
            let config = try ConfigService().loadConfig()
            let report = try DiskCleanupService().cleanup(
                runners: config.runners,
                globalIsolationMode: config.settings.isolationMode,
                includeSharedCaches: includeSharedCaches,
                dryRun: dryRun
            )
            let size = ByteCountFormatter.string(fromByteCount: report.reclaimedBytes, countStyle: .file)
            print("\(dryRun ? "Would reclaim" : "Reclaimed") \(size) from \(report.removedPaths.count) item(s).")
            if !report.skippedRunnerNames.isEmpty {
                print("Skipped active runners: \(report.skippedRunnerNames.joined(separator: ", "))")
                if includeSharedCaches {
                    print("Shared CI caches were preserved while runners are active.")
                }
            }
        } catch {
            print("Error: \(error.localizedDescription)")
        }
    }
}
