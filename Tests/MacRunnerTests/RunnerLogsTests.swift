import XCTest
@testable import MacRunner

final class RunnerLogsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func path(_ name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    private func write(_ text: String, to name: String) throws {
        try text.write(toFile: path(name), atomically: false, encoding: .utf8)
    }

    func testLastLinesAndPartialReads() throws {
        try write((1...100).map { "line \($0)" }.joined(separator: "\n") + "\n", to: "runner.log")
        XCTAssertEqual(RunnerLogs.lastLines(of: path("runner.log"), count: 3), ["line 98", "line 99", "line 100"])
        XCTAssertEqual(RunnerLogs.lastLines(of: path("runner.log"), count: 500).count, 100)

        // Reading only the tail must drop the partial first line.
        let tail = RunnerLogs.lastLines(of: path("runner.log"), count: 500, maxBytes: 20)
        XCTAssertEqual(tail, ["line 99", "line 100"])
        XCTAssertEqual(RunnerLogs.lastLines(of: path("missing.log"), count: 5), [])
    }

    func testSplitHandlesCRLFAndTrailingNewline() {
        XCTAssertEqual(RunnerLogs.splitLines("a\r\nb\n"), ["a", "b"])
        XCTAssertEqual(RunnerLogs.splitLines("a\n\nb"), ["a", "", "b"])
    }

    func testFilterIsCaseInsensitive() {
        let lines = ["Listening for Jobs", "Running job: build", "ERROR: boom"]
        XCTAssertEqual(RunnerLogs.filter(lines, matching: "error"), ["ERROR: boom"])
        XCTAssertEqual(RunnerLogs.filter(lines, matching: "  "), lines)
    }

    func testOpenForAppendingNeverTruncatesAndSurvivesRotation() throws {
        try write("earlier run\n", to: "runner.log")
        let handle = try RunnerLogs.openForAppending(path("runner.log"))
        handle.write(Data("new run\n".utf8))
        XCTAssertEqual(try String(contentsOfFile: path("runner.log"), encoding: .utf8), "earlier run\nnew run\n")

        // Copy-truncate while the handle is open: later writes land at the start, not past a hole.
        XCTAssertTrue(try ProcessExecutor.run("/bin/bash", arguments: ["-c", RunnerLogs.rotationCommand(path: path("runner.log"))]).succeeded)
        handle.write(Data("after rotation\n".utf8))
        try handle.close()

        XCTAssertEqual(try String(contentsOfFile: path("runner.log"), encoding: .utf8), "after rotation\n")
        XCTAssertEqual(try String(contentsOfFile: path("runner.log.1"), encoding: .utf8), "earlier run\nnew run\n")
    }

    func testRotationKeepsBoundedNumberOfFiles() throws {
        for generation in 1...5 {
            try write(String(repeating: "x", count: 64) + " gen \(generation)\n", to: "runner.log")
            XCTAssertTrue(RunnerLogs.rotateIfNeeded(path("runner.log"), maxBytes: 10, keep: 3))
        }
        XCTAssertFalse(RunnerLogs.rotateIfNeeded(path("runner.log"), maxBytes: 10, keep: 3), "empty log needs no rotation")

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(files, ["runner.log", "runner.log.1", "runner.log.2", "runner.log.3"])
        XCTAssertTrue(try String(contentsOfFile: path("runner.log.1"), encoding: .utf8).contains("gen 5"))
        XCTAssertTrue(try String(contentsOfFile: path("runner.log.3"), encoding: .utf8).contains("gen 3"))
    }

    func testFollowerReadsCompleteLinesAndResetsAfterTruncation() throws {
        try write("old\n", to: "runner.log")
        let follower = LogFollower(path: path("runner.log"), startAtEnd: true)
        XCTAssertEqual(follower.readNewLines(), [])

        let handle = try RunnerLogs.openForAppending(path("runner.log"))
        handle.write(Data("one\ntw".utf8))
        XCTAssertEqual(follower.readNewLines(), ["one"])
        handle.write(Data("o\n".utf8))
        XCTAssertEqual(follower.readNewLines(), ["two"])

        XCTAssertTrue(try ProcessExecutor.run("/bin/bash", arguments: ["-c", ": > '\(path("runner.log"))'"]).succeeded)
        handle.write(Data("fresh\n".utf8))
        XCTAssertEqual(follower.readNewLines(), ["fresh"])
        try handle.close()

        // Replaced by a different file (e.g. moved aside) — start over on the new one.
        try FileManager.default.removeItem(atPath: path("runner.log"))
        try write("replacement\n", to: "runner.log")
        XCTAssertEqual(follower.readNewLines(), ["replacement"])
    }

    func testDiagnosticsSourcesPickNewestFileOfTheirKindByName() throws {
        let diag = directory.appendingPathComponent("_diag", isDirectory: true)
        try FileManager.default.createDirectory(at: diag, withIntermediateDirectories: true)
        let names = ["Runner_20260101-000000-utc.log", "Runner_20260102-000000-utc.log",
                     "Worker_20260102-010000-utc.log", "Worker_20260102-020000-utc.log", "pages"]
        for name in names {
            try "x".write(to: diag.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // The older Runner_ log being written to most recently must not win.
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: diag.appendingPathComponent(names[0]).path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: diag.appendingPathComponent(names[1]).path)

        XCTAssertEqual(RunnerLogs.path(for: .diagnostics, runnerDirectory: directory.path), diag.appendingPathComponent(names[1]).path)
        XCTAssertEqual(RunnerLogs.path(for: .jobDiagnostics, runnerDirectory: directory.path), diag.appendingPathComponent(names[3]).path)
        XCTAssertEqual(RunnerLogs.path(for: .output, runnerDirectory: directory.path), path("runner.log"))
        XCTAssertNil(RunnerLogs.path(for: .diagnostics, runnerDirectory: path("nope")))
    }

    func testPrunesOnlyOldDiagnosticsLogs() throws {
        let diag = directory.appendingPathComponent("_diag", isDirectory: true)
        try FileManager.default.createDirectory(at: diag, withIntermediateDirectories: true)
        let old = diag.appendingPathComponent("Worker_old.log")
        let fresh = diag.appendingPathComponent("Worker_new.log")
        let other = diag.appendingPathComponent("keep.txt")
        for url in [old, fresh, other] {
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        let tenDaysAgo = Date().addingTimeInterval(-10 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: tenDaysAgo], ofItemAtPath: other.path)

        XCTAssertTrue(RunnerLogs.pruneDiagnostics(runnerDirectory: directory.path, days: 7))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertTrue(RunnerLogs.pruneDiagnostics(runnerDirectory: path("no-runner-here")), "missing _diag is fine")
    }

    func testTailThenFollowMissesNothing() throws {
        try write("a\nb\npartial", to: "runner.log")
        let tail = RunnerLogs.tail(of: path("runner.log"), count: 10)
        XCTAssertEqual(tail.lines, ["a", "b"], "a partial last line is left for the follower")

        let handle = try RunnerLogs.openForAppending(path("runner.log"))
        handle.write(Data(" line\nwritten between tail and follow\n".utf8))
        try handle.close()

        let follower = LogFollower(path: path("runner.log"), offset: tail.endOffset)
        XCTAssertEqual(follower.readNewLines(), ["partial line", "written between tail and follow"])
    }

    func testFollowerFlushesAnOversizedUnterminatedLine() throws {
        let handle = try RunnerLogs.openForAppending(path("runner.log"))
        let follower = LogFollower(path: path("runner.log"), offset: 0)
        handle.write(Data(repeating: UInt8(ascii: "x"), count: LogFollower.maxPendingBytes + 1))
        let lines = follower.readNewLines()
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.count, LogFollower.maxPendingBytes + 1)
        handle.write(Data("next\n".utf8))
        XCTAssertEqual(follower.readNewLines(), ["next"])
        try handle.close()
    }

    func testFollowerKeepsUTF8CharactersSplitAcrossReads() throws {
        let bytes = Array("café ✓\n".utf8)
        let split = bytes.firstIndex(of: 0xC3)! + 1  // between the two bytes of "é"
        let handle = try RunnerLogs.openForAppending(path("runner.log"))
        let follower = LogFollower(path: path("runner.log"), offset: 0)

        handle.write(Data(bytes[..<split]))
        XCTAssertEqual(follower.readNewLines(), [])
        handle.write(Data(bytes[split...]))
        XCTAssertEqual(follower.readNewLines(), ["café ✓"])
        try handle.close()
    }

    func testContainerLogWriterAppendsAndClosesOnce() throws {
        let writer = try FileLogWriter(path: path("runner.log"))
        try writer.write(Data("stdout\n".utf8))
        try writer.write(Data("stderr\n".utf8))
        try writer.close()
        try writer.close()
        try writer.write(Data("ignored\n".utf8))
        XCTAssertEqual(try String(contentsOfFile: path("runner.log"), encoding: .utf8), "stdout\nstderr\n")
    }

    func testLogsCommandParsing() {
        XCTAssertEqual(try LogsCommand.parse(["r"]).get(), LogsCommand(runnerName: "r"))
        XCTAssertEqual(
            try LogsCommand.parse(["-f", "r", "-n", "200", "--diag"]).get(),
            LogsCommand(runnerName: "r", lines: 200, follow: true, source: .diagnostics)
        )
        XCTAssertEqual(try LogsCommand.parse(["r", "--job"]).get().source, .jobDiagnostics)
        for args in [[], ["r", "-n", "0"], ["r", "--bogus"], ["a", "b"], ["r", "--lines"], ["r", "--diag", "--job"]] {
            if case .success = LogsCommand.parse(args) {
                XCTFail("expected failure for \(args)")
            }
        }
    }

    @MainActor
    func testViewerModelTailsFiltersAndFollows() throws {
        try write("Listening for Jobs\n", to: "runner.log")
        let runner = Runner(name: "r", repo: "o/r")
        let logPath = path("runner.log")
        let model = LogViewerModel(runner: runner) { source in source == .output ? logPath : nil }
        XCTAssertEqual(model.lines, ["Listening for Jobs"])

        let handle = try RunnerLogs.openForAppending(logPath)
        handle.write(Data("Running job: build\nJob build completed with result: Succeeded\n".utf8))
        try handle.close()
        model.poll()
        XCTAssertEqual(model.lines.count, 3)

        model.query = "job"
        XCTAssertEqual(model.visibleLines, ["Listening for Jobs", "Running job: build", "Job build completed with result: Succeeded"])
        model.query = "succeeded"
        XCTAssertEqual(model.exportText, "Job build completed with result: Succeeded\n")

        model.source = .diagnostics
        XCTAssertEqual(model.lines, [])
        XCTAssertNil(model.path)
    }
}
