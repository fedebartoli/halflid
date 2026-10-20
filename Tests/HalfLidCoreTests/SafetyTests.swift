import Foundation
import HalfLidCore

// MARK: helpers

private let origin = Date(timeIntervalSince1970: 1_800_000_000)

private func snapshot(
    lidClosed: Bool = false, onAC: Bool = true, percent: Int = 100, temperature: Double? = 31, thermal: ThermalLevel = .nominal
) -> SystemSnapshot {
    SystemSnapshot(lidClosed: lidClosed, onACPower: onAC, batteryPercent: percent, batteryTemperatureC: temperature, thermal: thermal)
}

@discardableResult
private func step(
    _ controller: inout Controller, _ seconds: Double, working: Bool = true, hold: Hold = .none, _ system: SystemSnapshot = snapshot()
) -> Decision {
    controller.step(ControllerInput(now: origin.addingTimeInterval(seconds), agentWorking: working, hold: hold, system: system))
}

private final class FakeOverride: LidOverride {
    var calls: [Bool] = []
    var failuresLeft = 0
    func setLidCloseIgnored(_ ignored: Bool) throws {
        calls.append(ignored)
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw LidOverrideError.callFailed(-1)
        }
    }
}

private final class FakeScreen: ScreenControl {
    var events: [String] = []
    func lockScreen() { events.append("lock") }
    func displayOff() { events.append("display_off") }
    func restoreScreen() { events.append("restore") }
    func sleepIfStillAwake(afterSeconds: Int) { events.append("sleep:\(afterSeconds)") }
    func cancelPendingSleep() { events.append("cancel_sleep") }
}

private final class FakeNotices: NoticeSink {
    var posted: [Notice] = []
    func post(_ notice: Notice) { posted.append(notice) }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private func scratchDirectory() -> String {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("halflid-safety-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
    return !process.isRunning
}

private func startSleeper() -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["60"]
    try? process.run()
    return process
}

// MARK: tests

func runSafetyTests() {
    controllerBasics()
    controllerLimits()
    controllerLidSequence()
    controllerOverrideFailure()
    simulationTimelines()
    executorTests()
    overrideAndHeartbeatTests()
    screenRepairTests()
    guardianTests()
    guardProcessTests()
}

private func screenRepairTests() {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/brightness.saved"

    expect(ScreenRepair.load(path: path) == nil, "no saved brightness at first")
    expect(!ScreenRepair.restore(path: path, apply: { _ in true }), "nothing to restore without a saved value")
    ScreenRepair.save(0.62, path: path)
    expect(ScreenRepair.load(path: path) == 0.62, "saved brightness reads back")
    var applied: Float?
    let restored = ScreenRepair.restore(path: path, apply: { applied = $0; return true })
    expect(restored && applied == 0.62, "restore applies the saved brightness")
    expect(ScreenRepair.load(path: path) == nil, "a restored value is forgotten")
    ScreenRepair.save(0.4, path: path)
    expect(!ScreenRepair.restore(path: path, apply: { _ in false }), "a failed restore reports failure")
    expect(ScreenRepair.load(path: path) == 0.4, "a failed restore keeps the saved value for the next attempt")

    // The real controller must be harmless without saved state, and a scheduled sleep must be cancellable.
    let control = SystemScreenControl(statePath: path + ".missing")
    control.restoreScreen()
    control.sleepIfStillAwake(afterSeconds: 3600)
    control.cancelPendingSleep()
    expect(true, "screen control without state does nothing")

    // The guard runs its extra repair after releasing.
    let beat = dir + "/beat"
    let overridePath = dir + "/override"
    let app = startSleeper()
    kill(app.processIdentifier, SIGKILL)
    _ = waitForExit(app, timeout: 3)
    Heartbeat.touch(path: beat)
    let repaired = Box(false)
    let guardian = Guardian(
        parentPid: app.processIdentifier, heartbeatPath: beat, override: FileLidOverride(path: overridePath),
        pollSeconds: 0.05, maxHeartbeatAge: 30, afterRelease: { repaired.value = true }
    )
    _ = guardian.run()
    expect(repaired.value, "guard runs the extra repair after releasing the override")
    expect(FileLidOverride.state(at: overridePath) == false, "guard released the override before the repair")
}

private func controllerBasics() {
    var c = Controller()
    var d = step(&c, 0, working: false)
    expect(!d.armed && d.indicator == .idle && d.actions.isEmpty, "idle controller does nothing")

    d = step(&c, 5)
    expect(d.armed && d.indicator == .active && d.actions == [.arm], "work starts: arm once")
    d = step(&c, 6)
    expect(d.armed && d.actions.isEmpty, "armed controller does not repeat arm")

    d = step(&c, 30, working: false)
    expect(d.armed, "grace period keeps the Mac awake after work stops")
    d = step(&c, 125, working: false)
    expect(d.armed, "still armed just before the grace period ends (last work at 6 s)")
    d = step(&c, 126, working: false)
    expect(!d.armed && d.actions == [.disarm] && d.indicator == .idle, "released once the grace period is over")

    // Work resuming inside the grace period never releases.
    var g = Controller()
    step(&g, 0)
    step(&g, 100, working: false)
    d = step(&g, 150)
    expect(d.armed && !d.actions.contains(.disarm), "work resuming inside the grace period keeps it armed")

    // Manual holds.
    var h = Controller()
    d = step(&h, 0, working: false, hold: .untilStopped)
    expect(d.armed && d.actions == [.arm], "manual hold arms without an agent")
    d = step(&h, 40_000, working: false, hold: .untilStopped)
    expect(d.armed, "hold until stopped lasts as long as the 12 h cap allows")
    d = step(&h, 43_200, working: false, hold: .untilStopped)
    expect(!d.armed && d.latch == .maxDuration, "the duration cap applies to manual holds too")
    var h2 = Controller()
    step(&h2, 0, working: false, hold: .untilStopped)
    d = step(&h2, 100, working: false, hold: .none)
    expect(!d.armed && d.actions == [.disarm], "dropping the hold releases immediately (no grace without agent work)")

    var t = Controller()
    let deadline = origin.addingTimeInterval(100)
    d = step(&t, 0, working: false, hold: .until(deadline))
    expect(d.armed, "timed hold arms")
    d = step(&t, 99, working: false, hold: .until(deadline))
    expect(d.armed, "timed hold still active before the deadline")
    d = step(&t, 101, working: false, hold: .until(deadline))
    expect(!d.armed, "timed hold ends at the deadline")

    // Periodic re-assertion while armed.
    var r = Controller()
    step(&r, 0)
    d = step(&r, 59)
    expect(!d.actions.contains(.reassert), "no re-assertion before a minute")
    d = step(&r, 60)
    expect(d.actions == [.reassert], "re-assertion after a minute")
    d = step(&r, 61)
    expect(d.actions.isEmpty, "re-assertion is not repeated on the next step")
}

private func controllerLimits() {
    // Battery: warn once at 30 %, stop at 20 % on battery, resume when plugged in.
    var c = Controller()
    step(&c, 0, snapshot(onAC: false, percent: 50))
    var d = step(&c, 5, snapshot(onAC: false, percent: 30))
    expect(d.armed && d.actions == [.notify(.warning(.batteryLow))] && d.indicator == .warning, "battery warning at 30 %")
    d = step(&c, 10, snapshot(onAC: false, percent: 29))
    expect(d.actions.isEmpty, "battery warning is not repeated")
    d = step(&c, 15, snapshot(onAC: false, percent: 20))
    expect(!d.armed && d.latch == .batteryLow, "stop at 20 % on battery")
    expect(d.actions == [.disarm, .notify(.stopped(.batteryLow))], "stop releases then notifies")
    d = step(&c, 20, snapshot(onAC: false, percent: 22))
    expect(!d.armed && d.latch == .batteryLow, "no resume at 22 % on battery (hysteresis)")
    d = step(&c, 25, snapshot(onAC: true, percent: 22))
    expect(d.armed && d.actions.contains(.arm) && d.latch == nil, "resume once the charger is connected")

    // On AC the battery level does not matter.
    var a = Controller()
    d = step(&a, 0, snapshot(onAC: true, percent: 5))
    expect(d.armed && d.latch == nil, "low battery on AC does not stop")

    // A session that ends while latched clears the latch.
    var e = Controller()
    step(&e, 0, snapshot(onAC: false, percent: 15))
    d = step(&e, 10, working: false, snapshot(onAC: false, percent: 15))
    expect(d.latch == .batteryLow && !d.armed, "latch holds during the grace period")
    d = step(&e, 200, working: false, snapshot(onAC: false, percent: 15))
    expect(d.latch == nil && !d.armed, "latch is cleared when no work is wanted")

    // Thermal: stop at serious, cool-down before resuming.
    var t = Controller()
    step(&t, 0)
    d = step(&t, 10, snapshot(thermal: .fair))
    expect(d.armed, "fair thermal state is tolerated")
    d = step(&t, 20, snapshot(thermal: .serious))
    expect(!d.armed && d.latch == .thermal && d.actions == [.disarm, .notify(.stopped(.thermal))], "stop at serious thermal state")
    d = step(&t, 50, snapshot(thermal: .fair))
    expect(!d.armed, "no resume during the thermal cool-down")
    d = step(&t, 80, snapshot(thermal: .serious))
    expect(!d.armed && d.latch == .thermal, "still stopped while serious")
    d = step(&t, 140, snapshot(thermal: .fair))
    expect(d.armed && d.actions.contains(.arm), "resume after the cool-down once below serious")
    d = step(&t, 150, snapshot(thermal: .critical))
    expect(!d.armed && d.latch == .thermal, "critical also stops")

    // Battery temperature: sustained 60 s above 45 C stops, brief spikes do not.
    var b = Controller()
    step(&b, 0, snapshot(temperature: 46))
    d = step(&b, 30, snapshot(temperature: 46))
    expect(d.armed, "a 30 s spike does not stop")
    step(&b, 40, snapshot(temperature: 40))
    d = step(&b, 100, snapshot(temperature: 46))
    expect(d.armed, "the sustain timer restarts after a dip")
    d = step(&b, 160, snapshot(temperature: 46))
    expect(!d.armed && d.latch == .batteryTemperature, "60 s sustained above 45 C stops")
    d = step(&b, 170, snapshot(temperature: 42))
    expect(!d.armed, "no resume at 42 C (hysteresis down to 40 C)")
    d = step(&b, 180, snapshot(temperature: 40))
    expect(d.armed, "resume at 40 C")

    var w = Controller()
    step(&w, 0, snapshot(temperature: 43))
    d = step(&w, 59, snapshot(temperature: 43))
    expect(!d.actions.contains(.notify(.warning(.batteryTemperature))), "no temperature warning before 60 s")
    d = step(&w, 60, snapshot(temperature: 43))
    expect(d.actions.contains(.notify(.warning(.batteryTemperature))) && d.armed, "temperature warning after 60 s above 42 C")

    var u = Controller()
    d = step(&u, 0, snapshot(temperature: nil))
    expect(d.armed, "an unreadable temperature never stops by itself")

    // Maximum duration: 4 h on battery, 12 h on AC.
    var m = Controller()
    step(&m, 0, snapshot(onAC: false, percent: 80))
    d = step(&m, 4 * 3600 - 1, snapshot(onAC: false, percent: 80))
    expect(d.armed, "armed just before 4 h on battery")
    d = step(&m, 4 * 3600, snapshot(onAC: false, percent: 80))
    expect(!d.armed && d.latch == .maxDuration, "stop after 4 h on battery")
    d = step(&m, 4 * 3600 + 10, snapshot(lidClosed: true, onAC: false, percent: 80))
    expect(!d.armed, "stays stopped while the lid is closed")
    d = step(&m, 4 * 3600 + 20, snapshot(lidClosed: false, onAC: false, percent: 80))
    expect(d.armed && d.latch == nil, "opening the lid starts a new session")

    var n = Controller()
    step(&n, 0)
    d = step(&n, 11 * 3600 + 3599)
    expect(d.armed, "armed after 11 h 59 m on AC")
    d = step(&n, 12 * 3600)
    expect(!d.armed && d.latch == .maxDuration, "stop after 12 h on AC")

    // Custom limits are honoured.
    var limits = Limits()
    limits.batteryStopPercent = 40
    var k = Controller(limits: limits)
    d = step(&k, 0, snapshot(onAC: false, percent: 40))
    expect(!d.armed, "custom battery stop level applies")
}

private func controllerLidSequence() {
    var c = Controller()
    var d = step(&c, 0, snapshot(lidClosed: false))
    expect(d.actions == [.arm], "armed with the lid open: no screen actions")

    d = step(&c, 10, snapshot(lidClosed: true))
    expect(d.actions == [.lockScreen, .displayOff], "lid closed while armed: lock then display off")
    d = step(&c, 15, snapshot(lidClosed: true))
    expect(d.actions.isEmpty, "the lock sequence runs once")
    d = step(&c, 70, snapshot(lidClosed: true))
    expect(d.actions.contains(.displayOff) && !d.actions.contains(.lockScreen), "display is turned off again after a minute, no second lock")
    d = step(&c, 80, snapshot(lidClosed: false))
    expect(d.actions == [.restoreScreen], "lid opened: restore the screen")

    var idle = Controller()
    d = step(&idle, 0, working: false, snapshot(lidClosed: true))
    expect(d.actions.isEmpty, "lid closed while not armed: nothing to do, the Mac sleeps by itself")

    // Release with the lid closed asks for sleep as a fallback.
    var r = Controller()
    d = step(&r, 0, snapshot(lidClosed: true))
    expect(d.actions == [.arm, .lockScreen, .displayOff], "armed with the lid already closed")
    d = step(&r, 120, working: false, snapshot(lidClosed: true))
    expect(d.actions == [.disarm, .ensureSleep(afterSeconds: Limits().sleepFallbackSeconds)], "release with the lid closed schedules a sleep")
    d = step(&r, 200, working: false, snapshot(lidClosed: false))
    expect(d.actions == [.restoreScreen], "opening the lid after release still restores the screen")

    var o = Controller()
    step(&o, 0)
    d = step(&o, 120, working: false)
    expect(d.actions == [.disarm], "release with the lid open needs no sleep request")

    // A safety stop with the lid closed also schedules sleep.
    var s = Controller()
    step(&s, 0, snapshot(lidClosed: true, thermal: .nominal))
    d = step(&s, 10, snapshot(lidClosed: true, thermal: .serious))
    expect(d.actions.contains(.disarm) && d.actions.contains(.ensureSleep(afterSeconds: 90)), "thermal stop with the lid closed schedules sleep")
}

private func controllerOverrideFailure() {
    var c = Controller()
    var d = step(&c, 0)
    expect(d.armed, "armed before the failure")
    c.armFailed(at: origin.addingTimeInterval(1))
    expect(!c.isArmed && c.currentLatch == .overrideFailed, "armFailed drops the armed state")
    d = step(&c, 10)
    expect(!d.armed && d.latch == .overrideFailed, "no immediate retry")
    d = step(&c, 61)
    expect(d.armed && d.actions.contains(.arm), "retry after the retry delay")
}

private func simulationEvents(_ scenario: Scenario) -> [String] {
    Simulator.run(scenario).flatMap { line in
        line.actions.filter { $0 != .reassert }.map { "\(line.seconds):\(Simulator.describe($0))" }
    }
}

private func simulationTimelines() {
    expect(simulationEvents(.agentSession) == ["10:arm", "715:disarm"], "scenario agent-session")
    expect(
        simulationEvents(.lidClose) == ["0:arm", "60:lock", "60:display_off", "120:display_off", "180:restore_screen", "355:disarm"],
        "scenario lid-close"
    )
    expect(
        simulationEvents(.batteryDrain) == ["0:arm", "30:warn:batteryLow", "330:disarm", "330:stopped:batteryLow", "540:arm"],
        "scenario battery-drain"
    )
    expect(simulationEvents(.thermal) == ["0:arm", "200:disarm", "200:stopped:thermal", "300:arm"], "scenario thermal")
    expect(
        simulationEvents(.batteryTemperature) == [
            "0:arm", "120:warn:batteryTemperature", "240:disarm", "240:stopped:batteryTemperature", "360:arm",
        ],
        "scenario battery-temperature"
    )
    expect(
        simulationEvents(.maxDuration) == ["0:arm", "14400:disarm", "14400:stopped:maxDuration", "15300:arm"],
        "scenario max-duration"
    )

    // Invariant for every scenario: arm and disarm alternate and match the reported state.
    for scenario in Scenario.allCases {
        var armed = false
        var consistent = true
        for line in Simulator.run(scenario) {
            for action in line.actions {
                if action == .arm { consistent = consistent && !armed; armed = true }
                if action == .disarm { consistent = consistent && armed; armed = false }
            }
            consistent = consistent && armed == line.armed
        }
        expect(consistent, "scenario \(scenario.rawValue): arm/disarm alternate and match the state")
    }
}

private func executorTests() {
    // Arm applies the override and then the screen actions.
    do {
        let override = FakeOverride(), screen = FakeScreen(), notices = FakeNotices()
        let executor = ActionExecutor(override: override, screen: screen, notices: notices)
        let ok = executor.apply([.arm, .lockScreen, .displayOff])
        expect(ok && override.calls == [true], "arm sets the override")
        expect(screen.events == ["cancel_sleep", "lock", "display_off"], "arming cancels a pending sleep request, then the screen actions run")
    }
    // A re-assertion does not cancel a pending sleep request (it only happens while armed).
    do {
        let override = FakeOverride(), screen = FakeScreen(), notices = FakeNotices()
        let executor = ActionExecutor(override: override, screen: screen, notices: notices)
        executor.apply([.reassert])
        expect(override.calls == [true] && screen.events.isEmpty, "reassert only re-applies the override")
    }
    // A failed arm skips the screen actions and reports the failure.
    do {
        let override = FakeOverride(), screen = FakeScreen(), notices = FakeNotices()
        override.failuresLeft = 1
        let executor = ActionExecutor(override: override, screen: screen, notices: notices)
        let ok = executor.apply([.arm, .lockScreen, .displayOff])
        expect(!ok, "a failed arm is reported")
        expect(screen.events.isEmpty, "no lock or display off when the override could not be applied")
        expect(notices.posted == [.stopped(.overrideFailed)], "a failed arm posts a notice")
    }
    // Release retries before giving up.
    do {
        let override = FakeOverride(), screen = FakeScreen(), notices = FakeNotices()
        override.failuresLeft = 2
        let executor = ActionExecutor(override: override, screen: screen, notices: notices)
        executor.apply([.disarm])
        expect(override.calls == [false, false, false], "release is retried until it succeeds")
    }
    do {
        let override = FakeOverride(), screen = FakeScreen(), notices = FakeNotices()
        override.failuresLeft = 10
        let executor = ActionExecutor(override: override, screen: screen, notices: notices)
        executor.apply([.disarm])
        expect(override.calls.count == 3, "release gives up after three attempts")
    }
    // Restore, sleep and notices always run.
    do {
        let override = FakeOverride(), screen = FakeScreen(), notices = FakeNotices()
        override.failuresLeft = 1
        let executor = ActionExecutor(override: override, screen: screen, notices: notices)
        executor.apply([.arm, .restoreScreen, .ensureSleep(afterSeconds: 90), .notify(.warning(.batteryLow))])
        expect(screen.events == ["restore", "sleep:90"], "restore and sleep fallback run even when arm failed")
        expect(notices.posted.contains(.warning(.batteryLow)), "notices pass through")
    }
}

private func overrideAndHeartbeatTests() {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let path = dir + "/override"
    expect(FileLidOverride.state(at: path) == nil, "missing override file reads as unknown")
    let override = FileLidOverride(path: path)
    try? override.setLidCloseIgnored(true)
    expect(FileLidOverride.state(at: path) == true, "file override records ignored")
    try? override.setLidCloseIgnored(false)
    expect(FileLidOverride.state(at: path) == false, "file override records normal")
    expect(LidOverrideFactory.make(environment: ["HALFLID_FAKE_OVERRIDE": path]) is FileLidOverride, "factory honours the fake override variable")
    expect(LidOverrideFactory.make(environment: [:]) is IOKitLidOverride, "factory defaults to the real override")

    let beat = dir + "/beat"
    expect(Heartbeat.age(path: beat) == nil, "missing heartbeat has no age")
    Heartbeat.touch(path: beat)
    expect((Heartbeat.age(path: beat) ?? 99) < 2, "fresh heartbeat is young")
    let later = Heartbeat.age(path: beat, now: Date().addingTimeInterval(100)) ?? 0
    expect(later > 98 && later < 102, "heartbeat age grows with time")

    expect(GuardLogic.shouldRelease(parentAlive: false, heartbeatAge: 1, maxHeartbeatAge: 120), "release when the app is gone")
    expect(GuardLogic.shouldRelease(parentAlive: true, heartbeatAge: nil, maxHeartbeatAge: 120), "release when the heartbeat file is missing")
    expect(GuardLogic.shouldRelease(parentAlive: true, heartbeatAge: 200, maxHeartbeatAge: 120), "release when the heartbeat is stale")
    expect(!GuardLogic.shouldRelease(parentAlive: true, heartbeatAge: 5, maxHeartbeatAge: 120), "keep while the app is alive and beating")
}

private func guardianTests() {
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let overridePath = dir + "/override"
    let beatPath = dir + "/beat"

    func run(_ scenario: (Process, Guardian, Box<GuardOutcome?>, DispatchSemaphore) -> Void, maxAge: Double = 30, shouldStop: @escaping () -> Bool = { false }) {
        try? FileLidOverride(path: overridePath).setLidCloseIgnored(true)
        Heartbeat.touch(path: beatPath)
        let app = startSleeper()
        defer { if app.isRunning { app.terminate() } }
        let guardian = Guardian(
            parentPid: app.processIdentifier, heartbeatPath: beatPath, override: FileLidOverride(path: overridePath),
            pollSeconds: 0.05, maxHeartbeatAge: maxAge
        )
        let outcome = Box<GuardOutcome?>(nil)
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            outcome.value = guardian.run(shouldStop: shouldStop)
            done.signal()
        }
        scenario(app, guardian, outcome, done)
    }

    // The app is killed with SIGKILL: no cleanup code runs in it, the guard must release.
    run { app, _, outcome, done in
        Thread.sleep(forTimeInterval: 0.3)
        expect(FileLidOverride.state(at: overridePath) == true, "guard leaves the override alone while the app lives")
        kill(app.processIdentifier, SIGKILL)
        _ = waitForExit(app, timeout: 3)
        expect(done.wait(timeout: .now() + 5) == .success, "guard notices the dead app")
        expect(outcome.value == .parentExited, "outcome is parentExited")
        expect(FileLidOverride.state(at: overridePath) == false, "override is released after the app was killed")
        expect(!FileManager.default.fileExists(atPath: beatPath), "guard removes the heartbeat file of a dead app")
    }

    // The app hangs: heartbeat stops.
    run { _, _, outcome, done in
        Thread.sleep(forTimeInterval: 0.2)
        expect(FileLidOverride.state(at: overridePath) == true, "override held while the heartbeat is fresh")
        let old = Date().addingTimeInterval(-500)
        try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: beatPath)
        expect(done.wait(timeout: .now() + 5) == .success, "guard notices the stale heartbeat")
        expect(outcome.value == .heartbeatStale, "outcome is heartbeatStale")
        expect(FileLidOverride.state(at: overridePath) == false, "override is released after the heartbeat went stale")
        expect(FileManager.default.fileExists(atPath: beatPath), "heartbeat file is kept when the app may still be alive")
    }

    // The guard is asked to stop: it releases as well.
    let stop = Box(false)
    run({ _, _, outcome, done in
        Thread.sleep(forTimeInterval: 0.2)
        stop.value = true
        expect(done.wait(timeout: .now() + 5) == .success, "guard stops when asked")
        expect(outcome.value == .terminated, "outcome is terminated")
        expect(FileLidOverride.state(at: overridePath) == false, "override is released when the guard is stopped")
    }, shouldStop: { stop.value })
}

/// The real `halflid guard` process, with the file stand-in for the override.
private func guardProcessTests() {
    let binary = repositoryRoot.appendingPathComponent("build/bin/halflid").path
    guard FileManager.default.isExecutableFile(atPath: binary) else {
        expect(false, "build/bin/halflid exists (scripts/test.sh builds it)")
        return
    }
    let dir = scratchDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let overridePath = dir + "/override"
    let beatPath = dir + "/beat"

    func launchGuard(parent: pid_t, pipe: Pipe) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["guard", "--parent", String(parent), "--heartbeat", beatPath, "--poll", "0.1", "--max-age", "30"]
        var environment = ProcessInfo.processInfo.environment
        environment["HALFLID_FAKE_OVERRIDE"] = overridePath
        environment["HALFLID_RESOURCES"] = repositoryRoot.appendingPathComponent("Resources").path
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        return process
    }

    // kill -9 on the app: the separate guard process restores normal behaviour within seconds.
    do {
        try? FileLidOverride(path: overridePath).setLidCloseIgnored(true)
        Heartbeat.touch(path: beatPath)
        let app = startSleeper()
        let pipe = Pipe()
        let guardProcess = launchGuard(parent: app.processIdentifier, pipe: pipe)
        Thread.sleep(forTimeInterval: 0.5)
        expect(guardProcess.isRunning, "guard process stays up while the app lives")
        expect(FileLidOverride.state(at: overridePath) == true, "override untouched while the app lives")
        kill(app.processIdentifier, SIGKILL)
        _ = waitForExit(app, timeout: 3)
        expect(waitForExit(guardProcess, timeout: 5), "guard process exits after the app was killed")
        expect(FileLidOverride.state(at: overridePath) == false, "guard process restored normal behaviour after kill -9")
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        expect(output.contains("outcome=parentExited"), "guard process reports parentExited")
    }

    // SIGTERM to the guard: immediate release.
    do {
        try? FileLidOverride(path: overridePath).setLidCloseIgnored(true)
        Heartbeat.touch(path: beatPath)
        let app = startSleeper()
        defer { if app.isRunning { app.terminate() } }
        let pipe = Pipe()
        let guardProcess = launchGuard(parent: app.processIdentifier, pipe: pipe)
        Thread.sleep(forTimeInterval: 0.5)
        kill(guardProcess.processIdentifier, SIGTERM)
        expect(waitForExit(guardProcess, timeout: 5), "guard process exits on SIGTERM")
        expect(FileLidOverride.state(at: overridePath) == false, "guard process restored normal behaviour on SIGTERM")
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        expect(output.contains("outcome=terminated"), "guard process reports terminated")
    }

    // Missing arguments are a usage error, not a silent success.
    do {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["guard"]
        var environment = ProcessInfo.processInfo.environment
        environment["HALFLID_FAKE_OVERRIDE"] = overridePath
        environment["HALFLID_RESOURCES"] = repositoryRoot.appendingPathComponent("Resources").path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        expect(process.terminationStatus != 0, "guard without arguments exits with an error")
    }
}
