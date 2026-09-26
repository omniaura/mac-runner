import AppKit
import XCTest
@testable import MacRunner

@MainActor
final class StatusItemIconTests: XCTestCase {
    private let idle = Runner(name: "idle", repo: "o/r", status: .running, busy: false)
    private let busy = Runner(name: "busy", repo: "o/r", status: .running, busy: true)
    private let stoppedButStale = Runner(name: "stale", repo: "o/r", status: .stopped, busy: true)

    func testStaticWhenNoJobIsRunning() {
        XCTAssertEqual(
            StatusItemIcon.state(runners: [idle, stoppedButStale], updateAvailable: false, reduceMotion: false),
            .staticSymbol(StatusItemIcon.idleSymbol)
        )
        XCTAssertEqual(
            StatusItemIcon.state(runners: [], updateAvailable: true, reduceMotion: false),
            .staticSymbol(StatusItemIcon.updateSymbol)
        )
    }

    func testAnimatesWhileAnyRunnerIsExecutingAJob() {
        XCTAssertEqual(
            StatusItemIcon.state(runners: [idle, busy], updateAvailable: true, reduceMotion: false),
            .animated(frames: StatusItemIcon.runningFrames)
        )
    }

    func testReduceMotionShowsStaticActiveSymbol() {
        XCTAssertEqual(
            StatusItemIcon.state(runners: [busy], updateAvailable: false, reduceMotion: true),
            .staticSymbol(StatusItemIcon.activeSymbol)
        )
    }

    func testAllSymbolsExist() {
        let symbols = StatusItemIcon.runningFrames + [StatusItemIcon.idleSymbol, StatusItemIcon.updateSymbol, StatusItemIcon.activeSymbol]
        for symbol in symbols {
            XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
        }
    }

    func testToolTipSummarizesJobsAndUpdates() {
        XCTAssertEqual(StatusItemIcon.toolTip(runners: [idle], updateAvailable: false), "Mac Runner")
        XCTAssertEqual(StatusItemIcon.toolTip(runners: [busy], updateAvailable: false), "Mac Runner — 1 job running")
        XCTAssertEqual(
            StatusItemIcon.toolTip(runners: [busy, busy], updateAvailable: true),
            "Mac Runner — 2 jobs running — update available"
        )
    }

    func testAnimatorCyclesFramesAndStopsWhenIdle() {
        let button = NSStatusBarButton()
        let animator = StatusItemIconAnimator(button: button)

        animator.apply(.animated(frames: StatusItemIcon.runningFrames), toolTip: "busy")
        let first = button.image
        RunLoop.main.run(until: Date().addingTimeInterval(StatusItemIcon.frameInterval * 1.5))
        XCTAssertNotEqual(button.image, first, "expected the next animation frame")
        XCTAssertEqual(button.toolTip, "busy")

        animator.apply(.staticSymbol(StatusItemIcon.idleSymbol), toolTip: "idle")
        let settled = button.image
        RunLoop.main.run(until: Date().addingTimeInterval(StatusItemIcon.frameInterval * 1.5))
        XCTAssertEqual(button.image, settled, "animation should stop once idle")
    }
}
