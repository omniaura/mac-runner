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
