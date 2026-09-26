import IOKit.ps
import XCTest
@testable import MacRunner

final class QuietHoursTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: hour, minute: minute))!
    }

    func testParsesAndNormalizesTimes() {
        XCTAssertEqual(QuietHours.minutes(from: "22:30"), 22 * 60 + 30)
        XCTAssertEqual(QuietHours.minutes(from: "00:00"), 0)
        XCTAssertEqual(QuietHours.normalizedTime("7:5"), "07:05")
        for invalid in ["24:00", "12:60", "12", "ab:cd", "1:2:3", "", "-1:00", "123:00"] {
            XCTAssertNil(QuietHours.minutes(from: invalid), invalid)
        }
    }

    func testSameDayWindow() {
        let window = QuietHours(enabled: true, start: "09:00", end: "17:00")
        XCTAssertFalse(window.contains(at(8, 59), calendar: calendar))
        XCTAssertTrue(window.contains(at(9), calendar: calendar))
        XCTAssertTrue(window.contains(at(16, 59), calendar: calendar))
        XCTAssertFalse(window.contains(at(17), calendar: calendar), "end is exclusive")
    }

    func testOvernightWindow() {
        let window = QuietHours(enabled: true, start: "22:00", end: "06:00")
        XCTAssertTrue(window.contains(at(23), calendar: calendar))
        XCTAssertTrue(window.contains(at(0, 30), calendar: calendar))
        XCTAssertTrue(window.contains(at(5, 59), calendar: calendar))
        XCTAssertFalse(window.contains(at(6), calendar: calendar))
        XCTAssertFalse(window.contains(at(12), calendar: calendar))
        XCTAssertFalse(window.contains(at(21, 59), calendar: calendar))
    }

    func testEqualStartAndEndCoversWholeDay() {
        let window = QuietHours(enabled: true, start: "08:00", end: "08:00")
        XCTAssertTrue(window.contains(at(3), calendar: calendar))
        XCTAssertTrue(window.contains(at(20), calendar: calendar))
    }

    func testDisabledOrMalformedWindowIsNeverActive() {
        XCTAssertFalse(QuietHours(enabled: false, start: "00:00", end: "23:59").isActive(at: at(12), calendar: calendar))
        XCTAssertFalse(QuietHours(enabled: true, start: "nope", end: "23:59").isActive(at: at(12), calendar: calendar))
    }
}

final class AutoPausePolicyTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private lazy var noon = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 12))!
    private let runner = Runner(name: "r", repo: "o/r", status: .running)

    private func reason(_ runner: Runner, _ settings: AppSettings, _ power: PowerState?) -> AutoPauseReason? {
        AutoPausePolicy.reason(for: runner, settings: settings, power: power, now: noon, calendar: calendar)
    }

    func testBatteryPausesOnlyWhenEnabledOnBatteryAndBelowThreshold() {
        let enabled = AppSettings(pauseOnBattery: true, batteryPauseThreshold: 20)
        XCTAssertEqual(reason(runner, enabled, PowerState(isOnBattery: true, batteryLevel: 19)), .lowBattery)
        XCTAssertNil(reason(runner, enabled, PowerState(isOnBattery: true, batteryLevel: 20)))
        XCTAssertNil(reason(runner, enabled, PowerState(isOnBattery: false, batteryLevel: 5)), "charging resumes")
        XCTAssertNil(reason(runner, enabled, nil), "desktop Mac without a battery")
        XCTAssertNil(reason(runner, AppSettings(pauseOnBattery: false), PowerState(isOnBattery: true, batteryLevel: 5)))
    }

    func testGlobalQuietHoursAndPerRunnerOverrides() {
        let settings = AppSettings(quietHours: QuietHours(enabled: true, start: "11:00", end: "13:00"))
        XCTAssertEqual(reason(runner, settings, nil), .quietHours)

        var optedOut = runner
        optedOut.quietHours = QuietHours(enabled: false, start: "00:00", end: "00:00")
        XCTAssertNil(reason(optedOut, settings, nil))

        var ownWindow = runner
        ownWindow.quietHours = QuietHours(enabled: true, start: "20:00", end: "08:00")
        XCTAssertNil(reason(ownWindow, settings, nil), "runner window replaces the global one")

        var onlyRunner = runner
        onlyRunner.quietHours = QuietHours(enabled: true, start: "11:30", end: "12:30")
        XCTAssertEqual(reason(onlyRunner, AppSettings(), nil), .quietHours)
    }

    func testLowBatteryTakesPrecedence() {
        let settings = AppSettings(
            pauseOnBattery: true,
            quietHours: QuietHours(enabled: true, start: "11:00", end: "13:00")
        )
        XCTAssertEqual(reason(runner, settings, PowerState(isOnBattery: true, batteryLevel: 3)), .lowBattery)
    }
}

final class PowerSourceStateTests: XCTestCase {
    func testReadsInternalBattery() {
        let state = PowerSourceMonitor.state(from: [
            [kIOPSTypeKey: "UPS", kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue],
            [
                kIOPSTypeKey: kIOPSInternalBatteryType,
                kIOPSIsPresentKey: true,
                kIOPSCurrentCapacityKey: 42,
                kIOPSMaxCapacityKey: 100,
                kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
            ],
        ])
        XCTAssertEqual(state, PowerState(isOnBattery: true, batteryLevel: 42))
    }

    func testChargingAndScaledCapacity() {
        let state = PowerSourceMonitor.state(from: [[
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: 3000,
            kIOPSMaxCapacityKey: 4000,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
        ]])
        XCTAssertEqual(state, PowerState(isOnBattery: false, batteryLevel: 75))
    }

    func testNoBattery() {
        XCTAssertNil(PowerSourceMonitor.state(from: []))
    }

    @MainActor
    func testLiveReadDoesNotCrash() {
        _ = PowerSourceMonitor().currentState()
    }
}

final class AutoPauseConfigTests: XCTestCase {
    func testOldConfigsDecodeWithDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"pauseOnBattery": true}"#.utf8))
        XCTAssertEqual(settings.batteryPauseThreshold, AppSettings.defaultBatteryPauseThreshold)

        let runner = try JSONDecoder().decode(Runner.self, from: Data("""
        {"id": "\(UUID().uuidString)", "name": "r", "repo": "o/r", "labels": [], "enabled": true, "status": "paused"}
        """.utf8))
        XCTAssertNil(runner.quietHours)
        XCTAssertNil(runner.autoPauseReason)
    }

    func testThresholdIsClamped() throws {
        XCTAssertEqual(AppSettings(batteryPauseThreshold: 1).batteryPauseThreshold, 5)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"batteryPauseThreshold": 400}"#.utf8))
        XCTAssertEqual(decoded.batteryPauseThreshold, 95)
    }

    func testRunnerScheduleRoundTrips() throws {
        let runner = Runner(
            name: "r", repo: "o/r", status: .paused,
            quietHours: QuietHours(enabled: true, start: "22:00", end: "06:00"),
            autoPauseReason: .quietHours
        )
        let decoded = try JSONDecoder().decode(Runner.self, from: JSONEncoder().encode(runner))
        XCTAssertEqual(decoded.quietHours, runner.quietHours)
        XCTAssertEqual(decoded.autoPauseReason, .quietHours)
    }
}

final class AutoPauseCommandTests: XCTestCase {
    func testScheduleParsing() {
        XCTAssertEqual(try ScheduleCommand.parse([]).get(), .show)
        XCTAssertEqual(
            try ScheduleCommand.parse(["--start", "22:00", "--end", "6:00"]).get(),
            .setGlobal(QuietHours(enabled: true, start: "22:00", end: "06:00"))
        )
        XCTAssertEqual(try ScheduleCommand.parse(["--off"]).get(), .disableGlobal)
        XCTAssertEqual(try ScheduleCommand.parse(["--runner", "a", "--global"]).get(), .setRunner(name: "a", nil))
        XCTAssertEqual(
            try ScheduleCommand.parse(["--runner", "a", "--never"]).get(),
            .setRunner(name: "a", QuietHours(enabled: false, start: "00:00", end: "00:00"))
        )
        XCTAssertEqual(
            try ScheduleCommand.parse(["--runner", "a", "--start", "01:00", "--end", "02:00"]).get(),
            .setRunner(name: "a", QuietHours(enabled: true, start: "01:00", end: "02:00"))
        )
    }

    func testScheduleRejectsBadInput() {
        for args in [["--start", "22:00"], ["--start", "25:00", "--end", "01:00"], ["--off", "--start", "1:00", "--end", "2:00"],
                     ["--never"], ["--runner", "a"], ["--bogus"], ["--runner"]] {
            if case .success = ScheduleCommand.parse(args) {
                XCTFail("expected failure for \(args)")
            }
        }
    }

    func testBatteryParsing() {
        XCTAssertEqual(try BatteryCommand.parse([]).get(), .show)
        XCTAssertEqual(try BatteryCommand.parse(["on"]).get(), .set(enabled: true, threshold: nil))
        XCTAssertEqual(try BatteryCommand.parse(["off"]).get(), .set(enabled: false, threshold: nil))
        XCTAssertEqual(try BatteryCommand.parse(["--threshold", "30%"]).get(), .set(enabled: nil, threshold: 30))
        for args in [["--threshold", "2"], ["--threshold"], ["maybe"]] {
            if case .success = BatteryCommand.parse(args) {
                XCTFail("expected failure for \(args)")
            }
        }
    }
}

final class ExternalConfigMergeTests: XCTestCase {
    private let settings = AppSettings()

    private func config(_ runners: [Runner], _ settings: AppSettings? = nil) -> RunnerConfig {
        RunnerConfig(runners: runners, settings: settings ?? self.settings)
    }

    func testExternalEditsAreTakenWhenWeChangedNothing() {
        let runner = Runner(name: "r", repo: "o/r", status: .running, busy: true, lastRestartEvent: "restarted")
        var edited = runner
        edited.labels = ["x"]
        edited.quietHours = QuietHours(enabled: true, start: "01:00", end: "02:00")
        let externalSettings = AppSettings(pauseOnBattery: true)

        let merged = RunnerManager.reconcile(
            disk: config([edited], externalSettings), memory: config([runner]), base: config([runner]), ownedRuntimeIDs: []
        )

        XCTAssertEqual(merged.settings, externalSettings)
        XCTAssertEqual(merged.runners[0].labels, ["x"])
        XCTAssertEqual(merged.runners[0].quietHours, edited.quietHours)
        XCTAssertTrue(merged.runners[0].busy, "runtime-only fields stay ours")
        XCTAssertEqual(merged.runners[0].lastRestartEvent, "restarted")
    }

    func testOurUnsavedEditsSurviveAConcurrentExternalSave() {
        let a = Runner(name: "a", repo: "o/r")
        let b = Runner(name: "b", repo: "o/r")
        let base = config([a, b])

        // We: changed settings, renamed a, removed b, added c.
        var ourA = a
        ourA.quietHours = QuietHours(enabled: false, start: "00:00", end: "00:00")
        let c = Runner(name: "c", repo: "o/r")
        let ourSettings = AppSettings(batteryPauseThreshold: 40)
        // CLI: changed b's labels, added d.
        var cliB = b
        cliB.labels = ["cli"]
        let d = Runner(name: "d", repo: "o/r")

        let merged = RunnerManager.reconcile(
            disk: config([a, cliB, d]), memory: config([ourA, c], ourSettings), base: base, ownedRuntimeIDs: []
        )

        XCTAssertEqual(merged.settings, ourSettings)
        XCTAssertEqual(merged.runners.map(\.name), ["a", "d", "c"], "b stays removed; c and d both kept")
        XCTAssertEqual(merged.runners[0].quietHours, ourA.quietHours)
    }

    func testRunnersRemovedElsewhereDisappear() {
        let a = Runner(name: "a", repo: "o/r")
        let b = Runner(name: "b", repo: "o/r")
        let merged = RunnerManager.reconcile(disk: config([a]), memory: config([a, b]), base: config([a, b]), ownedRuntimeIDs: [])
        XCTAssertEqual(merged.runners.map(\.name), ["a"])
    }

    func testRunStateComesFromDiskUnlessWeOwnOrChangedIt() {
        let paused = Runner(name: "r", repo: "o/r", status: .paused, autoPauseReason: .quietHours)
        var startedByCLI = paused
        startedByCLI.status = .running
        startedByCLI.autoPauseReason = nil
        startedByCLI.autoPauseOverride = .quietHours

        let fromCLI = RunnerManager.reconcile(disk: config([startedByCLI]), memory: config([paused]), base: config([paused]), ownedRuntimeIDs: [])
        XCTAssertEqual(fromCLI.runners[0].status, .running)
        XCTAssertEqual(fromCLI.runners[0].autoPauseOverride, .quietHours, "a CLI manual start's override carries over")

        let owned = RunnerManager.reconcile(disk: config([startedByCLI]), memory: config([paused]), base: config([paused]), ownedRuntimeIDs: [paused.id])
        XCTAssertEqual(owned.runners[0].status, .paused)

        var pausedHere = startedByCLI
        pausedHere.status = .paused
        pausedHere.autoPauseReason = .lowBattery
        pausedHere.autoPauseOverride = nil
        let local = RunnerManager.reconcile(disk: config([paused]), memory: config([pausedHere]), base: config([startedByCLI]), ownedRuntimeIDs: [])
        XCTAssertEqual(local.runners[0].autoPauseReason, .lowBattery, "our state change since the last save wins")
    }

    func testOverrideDecodesAndDefaultsToNil() throws {
        var runner = Runner(name: "r", repo: "o/r")
        XCTAssertNil(try JSONDecoder().decode(Runner.self, from: JSONEncoder().encode(runner)).autoPauseOverride)
        runner.autoPauseOverride = .quietHours
        XCTAssertEqual(try JSONDecoder().decode(Runner.self, from: JSONEncoder().encode(runner)).autoPauseOverride, .quietHours)
    }
}
