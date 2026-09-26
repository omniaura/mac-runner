import XCTest
@testable import MacRunner

final class DashboardTests: XCTestCase {
    private func job(_ id: Int, conclusion: String? = nil) -> WorkflowJobSummary {
        WorkflowJobSummary(
            id: id,
            name: "build",
            status: conclusion == nil ? "in_progress" : "completed",
            conclusion: conclusion,
            runnerName: "r",
            run: WorkflowRunSummary(id: id * 10, name: "CI", htmlURL: URL(string: "https://github.com/o/r/actions/runs/\(id * 10)")!)
        )
    }

    func testJobHistoryUpdatesInPlaceAndKeepsStartTime() {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        var history = RunnerManager.updatedJobHistory([], with: job(1), finishedAt: nil, now: start)
        XCTAssertEqual(history.first?.outcome, "running")

        history = RunnerManager.updatedJobHistory(history, with: job(1, conclusion: "failure"), finishedAt: end, now: end)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].startedAt, start)
        XCTAssertEqual(history[0].finishedAt, end)
        XCTAssertEqual(history[0].outcome, "failure")
        XCTAssertEqual(history[0].displayName, "CI · build")
    }

    func testJobHistoryIsNewestFirstAndCapped() {
        var history: [RecentJob] = []
        for id in 1...(RunnerManager.recentJobLimit + 5) {
            history = RunnerManager.updatedJobHistory(history, with: job(id, conclusion: "success"), finishedAt: Date(), now: Date())
        }
        XCTAssertEqual(history.count, RunnerManager.recentJobLimit)
        XCTAssertEqual(history.first?.job.id, RunnerManager.recentJobLimit + 5)
    }

    func testFinishedJobWithoutResultIsPendingNotFailed() {
        let finished = RecentJob(job: job(1), startedAt: Date(), finishedAt: Date())
        XCTAssertEqual(finished.outcome, "pending")
        XCTAssertEqual(RunnerDetailView.icon(for: finished.outcome), "clock")

        let resolved = RunnerManager.updatedJobHistory([finished], with: job(1, conclusion: "success"), finishedAt: nil, now: Date())
        XCTAssertEqual(resolved.first?.outcome, "success", "a later result fills in the same entry")
        XCTAssertEqual(resolved.first?.finishedAt, finished.finishedAt)
    }

    func testDecodesASingleJob() throws {
        let run = WorkflowRunSummary(id: 5, name: "CI", htmlURL: URL(string: "https://github.com/o/r/actions/runs/5")!)
        let decoded = try GHCLIService.decodeJob(Data(#"{"id": 9, "name": "build", "status": "completed", "conclusion": "success", "runner_name": "r"}"#.utf8), run: run)
        XCTAssertEqual(decoded, WorkflowJobSummary(id: 9, name: "build", status: "completed", conclusion: "success", runnerName: "r", run: run))
    }

    func testOutcomeStyling() {
        XCTAssertEqual(RunnerDetailView.icon(for: "success"), "checkmark.circle.fill")
        XCTAssertEqual(RunnerDetailView.icon(for: "failure"), "xmark.circle.fill")
        XCTAssertEqual(RunnerDetailView.icon(for: "running"), "circle.dotted")
    }

    func testAddRunnerNoneIsolationIsNotGlobal() {
        XCTAssertEqual(AddRunnerView.IsolationSelection.none.isolationMode, IsolationMode.none)
        XCTAssertNil(AddRunnerView.IsolationSelection.global.isolationMode)
    }
}
