import XCTest
@testable import MacRunner

final class ContainerRunnerTests: XCTestCase {
    private func config(tools: [String] = [], labels: [String] = ["linux", "mac-runner"]) -> ContainerRunnerConfiguration {
        ContainerRunnerConfiguration(
            containerImage: nil,
            workspaceURL: URL(fileURLWithPath: "/tmp/w"),
            repositoryURL: "https://github.com/o/r",
            registrationToken: "TOKEN with spaces'\"",
            runnerName: "ctr 1",
            labels: labels,
            tools: tools,
            runnerDownloadURL: RunnerInstaller.linuxDownloadURL(version: "2.337.0")
        )
    }

    func testDefaultImageIsGitHubsRunnerImage() {
        XCTAssertEqual(ContainerRunnerConfiguration.defaultRunnerImage, "ghcr.io/actions/actions-runner:latest")
        XCTAssertEqual(
            RunnerInstaller.linuxDownloadURL(version: "2.337.0"),
            "https://github.com/actions/runner/releases/download/v2.337.0/actions-runner-linux-arm64-2.337.0.tar.gz"
        )
    }

    func testToolsMapToAptPackages() {
        let mapped = ContainerRunnerScript.aptPackages(for: ["gh", "node", "python", "rust", "jq", "node"])
        XCTAssertTrue(mapped.installGitHubCLI)
        XCTAssertEqual(mapped.packages, ["nodejs", "npm", "python3", "python3-pip", "python3-venv", "cargo", "rustc", "jq"])
        XCTAssertFalse(ContainerRunnerScript.aptPackages(for: []).installGitHubCLI)
    }

    func testEnvironmentCarriesRegistrationDetails() {
        let environment = ContainerRunnerScript.environment(for: config(tools: ["gh", "go"], labels: ["linux", "gpu"]))
        XCTAssertTrue(environment.contains("RUNNER_ALLOW_RUNASROOT=1"))
        XCTAssertTrue(environment.contains("MR_NAME=ctr 1"))
        XCTAssertTrue(environment.contains("MR_LABELS=linux,gpu"))
        XCTAssertTrue(environment.contains("MR_APT_PACKAGES=golang-go"))
        XCTAssertTrue(environment.contains("MR_INSTALL_GH=1"))
        XCTAssertTrue(environment.contains("MR_TOKEN=TOKEN with spaces'\""))
    }

    func testScriptRegistersWithNameLabelsAndHostWorkDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctr-\(UUID().uuidString)", isDirectory: true)
        let runnerHome = root.appendingPathComponent("home-runner", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerHome.appendingPathComponent("_diag"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let argsFile = root.appendingPathComponent("config-args").path
        try "#!/bin/bash\nprintf '%s\\n' \"$@\" > '\(argsFile)'\n".write(to: runnerHome.appendingPathComponent("config.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/bash\necho \"run.sh token=${MR_TOKEN:-unset} ci=${CI:-unset} headless=${HEADLESS:-unset}\"\n".write(to: runnerHome.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        for script in ["config.sh", "run.sh"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: runnerHome.appendingPathComponent(script).path)
        }

        var environment = ContainerRunnerScript.environment(for: config()).reduce(into: [String: String]()) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            result[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        environment["MR_RUNNER_CANDIDATES"] = runnerHome.path
        environment["MR_WORK_DIR"] = root.appendingPathComponent("work").path
        environment["MR_DIAG_DIR"] = root.appendingPathComponent("diag").path
        environment["PATH"] = "/usr/bin:/bin"
        environment["MR_SUDO"] = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", ContainerRunnerScript.script]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0, output)
        XCTAssertTrue(output.contains("run.sh token=unset ci=true headless=true"), "token cleared and headless env set: \(output)")
        let args = try String(contentsOfFile: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(args, [
            "--unattended", "--replace",
            "--url", "https://github.com/o/r", "--token", "TOKEN with spaces'\"",
            "--name", "ctr 1", "--labels", "linux,mac-runner", "--work", root.appendingPathComponent("work").path,
        ])
        let diagLink = try FileManager.default.destinationOfSymbolicLink(atPath: runnerHome.appendingPathComponent("_diag").path)
        XCTAssertEqual(diagLink, root.appendingPathComponent("diag").path)
    }

    func testDefaultLabelsForContainersAreLinux() {
        XCTAssertEqual(Runner.defaultLabels(for: .container), ["linux", "mac-runner"])
        XCTAssertEqual(Runner.defaultLabels(for: IsolationMode.none), ["macos", "mac-runner"])
    }

    func testConfigFileImageRequiresContainerIsolation() throws {
        let ok = try DeclarativeConfig.parse("runners:\n  - name: c\n    repo: o/r\n    isolation: container\n    image: ubuntu:24.04\n").desiredRunners()
        XCTAssertEqual(ok.first?.containerImage, "ubuntu:24.04")
        XCTAssertEqual(ok.first?.labels, ["linux", "mac-runner"])
        XCTAssertThrowsError(try DeclarativeConfig.parse("runners:\n  - name: c\n    repo: o/r\n    image: ubuntu:24.04\n").desiredRunners())
    }

    func testHostnameIsDNSSafe() {
        XCTAssertEqual(ContainerRunnerScript.hostname(for: "e2e-ctr"), "e2e-ctr")
        XCTAssertEqual(ContainerRunnerScript.hostname(for: "My Runner_2.x"), "my-runner-2-x")
        XCTAssertEqual(ContainerRunnerScript.hostname(for: "__"), "mac-runner")
        XCTAssertEqual(ContainerRunnerScript.hostname(for: String(repeating: "a", count: 80)).count, 63)
    }

    func testFailedToolInstallStopsBeforeRegistering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctr-fail-\(UUID().uuidString)", isDirectory: true)
        let runnerHome = root.appendingPathComponent("home-runner", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let registered = root.appendingPathComponent("registered").path
        try "#!/bin/bash\ntouch '\(registered)'\n".write(to: runnerHome.appendingPathComponent("config.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/bash\n".write(to: runnerHome.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/bash\n[ \"$1\" = update ] && exit 0\nexit 100\n".write(to: bin.appendingPathComponent("apt-get"), atomically: true, encoding: .utf8)
        for file in [runnerHome.appendingPathComponent("config.sh"), runnerHome.appendingPathComponent("run.sh"), bin.appendingPathComponent("apt-get")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        var environment = ContainerRunnerScript.environment(for: config(tools: ["jq"])).reduce(into: [String: String]()) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            result[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        environment["MR_RUNNER_CANDIDATES"] = runnerHome.path
        environment["MR_WORK_DIR"] = root.appendingPathComponent("work").path
        environment["MR_DIAG_DIR"] = root.appendingPathComponent("diag").path
        environment["MR_SUDO"] = ""
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"

        let result = try runScript(environment: environment)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("tool installation failed (could not install: jq)"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registered), "must not register without its tools")
    }

    private func runScript(environment: [String: String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", ContainerRunnerScript.script]
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    func testOnlyOfflineRegistrationsAreRemovedByName() {
        let remote = [
            RemoteRunner(id: 1, name: "ctr", status: "online", busy: false, labels: []),
            RemoteRunner(id: 2, name: "other", status: "offline", busy: false, labels: []),
        ]
        XCTAssertNil(RunnerManager.offlineRegistration(named: "ctr", in: remote), "a live runner is never deleted by name")
        XCTAssertEqual(RunnerManager.offlineRegistration(named: "other", in: remote)?.id, 2)
    }

    func testGlobalContainerIsolationAppliesToConfigFiles() throws {
        let config = try DeclarativeConfig.parse("runners:\n  - name: c\n    repo: o/r\n    image: ubuntu:24.04\n")
        let runners = try config.desiredRunners(globalIsolation: .container)
        XCTAssertEqual(runners.first?.labels, ["linux", "mac-runner"])
        XCTAssertEqual(runners.first?.containerImage, "ubuntu:24.04")
        XCTAssertThrowsError(try config.desiredRunners(globalIsolation: IsolationMode.none))
    }

    func testGUIFlagAndDisplayAreInTheEnvironment() {
        var gui = config()
        gui.enableGUI = true
        XCTAssertTrue(ContainerRunnerScript.environment(for: gui).contains("MR_ENABLE_GUI=1"))
        XCTAssertTrue(ContainerRunnerScript.environment(for: gui).contains("MR_DISPLAY=:99"))
        XCTAssertTrue(ContainerRunnerScript.environment(for: config()).contains("MR_ENABLE_GUI=0"))
    }

    /// Runs the startup script's GUI path with a stub Xvfb in a scratch runner.
    private func runGUIStartup(
        xvfbStub: String?,
        xdpyinfoStub: String? = nil,
        extraEnvironment: [String: String] = [:]
    ) throws -> (status: Int32, output: String, registered: Bool) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ctr-gui-\(UUID().uuidString)", isDirectory: true)
        // Unix socket paths are limited to ~104 bytes; keep this one short.
        let x11 = "/tmp/mrx-\(UUID().uuidString.prefix(8))"
        let runnerHome = root.appendingPathComponent("home-runner", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: runnerHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: x11, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(atPath: x11)
        }

        let registered = root.appendingPathComponent("registered").path
        try "#!/bin/bash\ntouch '\(registered)'\n".write(to: runnerHome.appendingPathComponent("config.sh"), atomically: true, encoding: .utf8)
        try "#!/bin/bash\necho \"run.sh DISPLAY=${DISPLAY:-unset}\"\n".write(to: runnerHome.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        var executables = [runnerHome.appendingPathComponent("config.sh"), runnerHome.appendingPathComponent("run.sh")]
        if let xvfbStub {
            try xvfbStub.write(to: bin.appendingPathComponent("Xvfb"), atomically: true, encoding: .utf8)
            executables.append(bin.appendingPathComponent("Xvfb"))
        }
        if let xdpyinfoStub {
            try xdpyinfoStub.write(to: bin.appendingPathComponent("xdpyinfo"), atomically: true, encoding: .utf8)
            executables.append(bin.appendingPathComponent("xdpyinfo"))
        }
        for file in executables {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }

        var gui = self.config()
        gui.enableGUI = true
        var environment = ContainerRunnerScript.environment(for: gui).reduce(into: [String: String]()) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1)
            result[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        environment["MR_RUNNER_CANDIDATES"] = runnerHome.path
        environment["MR_WORK_DIR"] = root.appendingPathComponent("work").path
        environment["MR_DIAG_DIR"] = root.appendingPathComponent("diag").path
        environment["MR_SUDO"] = ""
        environment["MR_APT_PACKAGES"] = ""
        environment["MR_INSTALL_GH"] = "0"
        environment["MR_X11_DIR"] = x11
        environment["PATH"] = "\(bin.path):/usr/bin:/bin"
        environment.merge(extraEnvironment) { _, new in new }

        let result = try runScript(environment: environment)
        return (result.status, result.output, FileManager.default.fileExists(atPath: registered))
    }

    func testGUIStartupExportsDisplayOnceItIsUp() throws {
        // Stub Xvfb: creates the display's socket and keeps it open briefly.
        let result = try runGUIStartup(xvfbStub: Self.xvfbStub(listen: true, signalReady: true))
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("Virtual display :99"), result.output)
        XCTAssertTrue(result.output.contains("run.sh DISPLAY=:99"), result.output)
        XCTAssertTrue(result.registered)
    }

    func testGUIStartupFailsWhenTheDisplayNeverComesUp() throws {
        let result = try runGUIStartup(xvfbStub: "#!/bin/bash\nexit 1\n")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("virtual display :99 did not start"), result.output)
        XCTAssertFalse(result.registered, "must not register a GUI runner without a display")
    }

    func testGUIStartupFailsWithoutXvfbOrApt() throws {
        let result = try runGUIStartup(xvfbStub: nil)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("neither Xvfb nor apt-get"), result.output)
        XCTAssertFalse(result.registered)
    }

    /// A stand-in Xvfb: binds the display socket, optionally listens, and
    /// optionally reports readiness on -displayfd 3 (as the real Xvfb does).
    private static func xvfbStub(listen: Bool, signalReady: Bool, exitAfterSocket: Bool = false) -> String {
        let python = [
            "import os,socket,sys,time",
            "s=socket.socket(socket.AF_UNIX)",
            "s.bind(os.path.join(os.environ['MR_X11_DIR'], 'X' + sys.argv[1].lstrip(':')))",
            listen ? "s.listen(4)" : "pass",
            signalReady ? "os.write(3, b'99\\n')" : "pass",
            exitAfterSocket ? "sys.exit(0)" : "time.sleep(float(os.environ.get('STUB_LIFETIME', '5')))",
        ].joined(separator: "; ")
        return "#!/bin/bash\nexec /usr/bin/python3 -c \"\(python)\" \"$1\"\n"
    }

    /// A stand-in xdpyinfo that really connects to the display's socket.
    private static let connectingXdpyinfo = "#!/bin/bash\nexec /usr/bin/python3 -c \"import os,socket; s=socket.socket(socket.AF_UNIX); s.connect(os.path.join(os.environ['MR_X11_DIR'], 'X' + os.environ['DISPLAY'].lstrip(':')))\"\n"

    func testGUIStartupFailsWhenXvfbExitsAfterCreatingItsSocket() throws {
        let result = try runGUIStartup(xvfbStub: Self.xvfbStub(listen: true, signalReady: false, exitAfterSocket: true))
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("did not start"), result.output)
        XCTAssertFalse(result.registered)
    }

    func testGUIStartupWaitsForXvfbToReportReady() throws {
        // Socket exists and accepts connections, but Xvfb never reported ready.
        let result = try runGUIStartup(xvfbStub: Self.xvfbStub(listen: true, signalReady: false), xdpyinfoStub: Self.connectingXdpyinfo)
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertFalse(result.registered)
    }

    func testGUIStartupRequiresAClientConnectionWhenXdpyinfoIsAvailable() throws {
        let refused = try runGUIStartup(xvfbStub: Self.xvfbStub(listen: false, signalReady: true), xdpyinfoStub: Self.connectingXdpyinfo)
        XCTAssertNotEqual(refused.status, 0, refused.output)
        XCTAssertFalse(refused.registered, "a socket that refuses connections isn't a display")

        let accepted = try runGUIStartup(xvfbStub: Self.xvfbStub(listen: true, signalReady: true), xdpyinfoStub: Self.connectingXdpyinfo)
        XCTAssertEqual(accepted.status, 0, accepted.output)
        XCTAssertTrue(accepted.registered)
    }

    func testGUIStartupDoesNotHangOnAStuckProbe() throws {
        let start = Date()
        // Xvfb stays up far longer than the readiness deadline; the stuck probe must not hold startup.
        let result = try runGUIStartup(
            xvfbStub: Self.xvfbStub(listen: true, signalReady: true),
            xdpyinfoStub: "#!/bin/bash\nsleep 60\n",
            extraEnvironment: ["STUB_LIFETIME": "60"]
        )
        XCTAssertNotEqual(result.status, 0, result.output)
        XCTAssertFalse(result.registered)
        XCTAssertLessThan(Date().timeIntervalSince(start), 20, "readiness gives up after its deadline")
    }
}
