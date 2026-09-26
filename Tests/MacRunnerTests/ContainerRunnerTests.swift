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
        try "#!/bin/bash\necho \"run.sh token=${MR_TOKEN:-unset}\"\n".write(to: runnerHome.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
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
        XCTAssertTrue(output.contains("run.sh token=unset"), "token is cleared before run.sh: \(output)")
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
}
