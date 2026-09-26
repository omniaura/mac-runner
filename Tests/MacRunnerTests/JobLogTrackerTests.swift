import XCTest
@testable import MacRunner

final class JobLogTrackerTests: XCTestCase {
    func testParsesRunnerOutput() {
        XCTAssertEqual(RunnerLogEvent.parse("2026-09-26 05:22:18Z: Listening for Jobs"), .listening)
        XCTAssertEqual(RunnerLogEvent.parse("2026-09-26 05:22:25Z: Running job: build (macos-14, 3.12)"), .jobStarted(name: "build (macos-14, 3.12)"))
        XCTAssertEqual(
            RunnerLogEvent.parse("2026-09-26 05:22:28Z: Job build (macos-14, 3.12) completed with result: Succeeded"),
            .jobCompleted(name: "build (macos-14, 3.12)", conclusion: "success")
        )
        XCTAssertEqual(
            RunnerLogEvent.parse("2026-09-26 05:22:28Z: Job deploy completed with result: Failed"),
            .jobCompleted(name: "deploy", conclusion: "failure")
        )
        for noise in ["√ Connected to GitHub", "Current runner version: '2.337.0'", "[mac-runner] Running job: fake", "", "Running job: no-timestamp"] {
            XCTAssertNil(RunnerLogEvent.parse(noise), noise)
        }
    }

    func testMapsResultsToAPIConclusions() {
        XCTAssertEqual(RunnerLogEvent.conclusion(for: "Canceled"), "cancelled")
        XCTAssertEqual(RunnerLogEvent.conclusion(for: "Skipped"), "skipped")
        XCTAssertEqual(RunnerLogEvent.conclusion(for: "Abandoned"), "abandoned")
    }

    func testRunningJobFromHistory() {
        XCTAssertEqual(JobLogTracker.runningJob(in: [
            "2026-09-26 05:22:18Z: Listening for Jobs",
            "2026-09-26 05:22:25Z: Running job: a",
            "2026-09-26 05:22:28Z: Job a completed with result: Succeeded",
            "2026-09-26 05:23:00Z: Running job: b",
        ]), "b")
        XCTAssertNil(JobLogTracker.runningJob(in: [
            "2026-09-26 05:23:00Z: Running job: b",
            "2026-09-26 05:30:00Z: Listening for Jobs",
        ]), "a restart ends the job")
    }

    func testFollowsJobsWrittenAfterItStarts() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("joblog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("runner.log").path
        try "2026-09-26 05:22:18Z: Listening for Jobs\n2026-09-26 05:22:25Z: Running job: already\n".write(toFile: path, atomically: true, encoding: .utf8)

        let tracker = JobLogTracker(path: path)
        XCTAssertEqual(tracker.currentJob, "already")
        XCTAssertEqual(tracker.poll(), [], "history isn't replayed")

        let handle = try RunnerLogs.openForAppending(path)
        handle.write(Data("""
        2026-09-26 05:22:30Z: Job already completed with result: Succeeded
        2026-09-26 05:22:31Z: Running job: quick
        2026-09-26 05:22:33Z: Job quick completed with result: Failed
        2026-09-26 05:22:40Z: Running job: interrupted

        """.utf8))
        XCTAssertEqual(tracker.poll(), [
            .completed(name: "already", conclusion: "success"),
            .started(name: "quick"),
            .completed(name: "quick", conclusion: "failure"),
            .started(name: "interrupted"),
        ])
        XCTAssertEqual(tracker.currentJob, "interrupted")

        handle.write(Data("\n√ Connected to GitHub\n2026-09-26 05:25:00Z: Listening for Jobs\n".utf8))
        try handle.close()
        XCTAssertEqual(tracker.poll(), [.completed(name: "interrupted", conclusion: "cancelled")])
        XCTAssertNil(tracker.currentJob)
    }

    func testCompletedJobAndActionsLinks() {
        let run = WorkflowRunSummary(id: 0, name: "", htmlURL: RunnerManager.actionsURL(for: RunnerTarget(scope: .repo, identifier: "o/r")))
        let job = WorkflowJobSummary(id: -1, name: "build", status: "in_progress", conclusion: nil, runnerName: "r", run: run)
        let done = job.completed(conclusion: "success")
        XCTAssertEqual(done.status, "completed")
        XCTAssertEqual(done.conclusion, "success")
        XCTAssertEqual(run.htmlURL.absoluteString, "https://github.com/o/r/actions")
        XCTAssertEqual(
            RunnerManager.actionsURL(for: RunnerTarget(scope: .org, identifier: "acme")).absoluteString,
            "https://github.com/organizations/acme/settings/actions/runners"
        )
        XCTAssertEqual(RecentJob(job: done, startedAt: Date(), finishedAt: Date()).displayName, "build")
    }
}
