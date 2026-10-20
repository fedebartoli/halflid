import Foundation
import HalfLidCore

// MARK: fakes and harness

private let origin = Date(timeIntervalSince1970: 1_800_000_000)

private final class LoopOverride: LidOverride {
    var calls: [Bool] = []
    var failuresLeft = 0
    func setLidCloseIgnored(_ ignored: Bool) throws {
        calls.append(ignored)
        if failuresLeft > 0 {
            failuresLeft -= 1
            throw LidOverrideError.callFailed(-1)
        }
    }
    var lastIgnored: Bool? { calls.last }
}

private final class LoopScreen: ScreenControl {
    var events: [String] = []
    func lockScreen() { events.append("lock") }
    func displayOff() { events.append("display_off") }
    func restoreScreen() { events.append("restore") }
    func sleepIfStillAwake(afterSeconds: Int) { events.append("sleep:\(afterSeconds)") }
    func cancelPendingSleep() {}
}

private final class LoopNotices: NoticeSink {
    var posted: [Notice] = []
    func post(_ notice: Notice) { posted.append(notice) }
}

private final class FakeGuard: GuardHandle {
    var running = false
    var startCount = 0
    var stopCount = 0
    var failsToStart = false
    var isRunning: Bool { running }
    func start() { startCount += 1; running = !failsToStart }
    func stop() { running = false; stopCount += 1 }
}

private func activity(working: Int, waiting: Int, idle: Int = 0) -> CursorActivity {
    var chats: [CursorChat] = []
    for index in 0..<working { chats.append(CursorChat(id: "w\(index)", activity: .working)) }
    for index in 0..<waiting { chats.append(CursorChat(id: "q\(index)", activity: .waitingForUser)) }
    for index in 0..<idle { chats.append(CursorChat(id: "i\(index)", activity: .idle)) }
    return CursorActivity(chats: chats)
}

private let cursorRunning = AgentSignal(agentId: "cursor", processCount: 3, cpuPercent: 60, sleepAssertions: 1)

private final class LoopHarness {
    var now = origin
    var system = SystemSnapshot(lidClosed: false, onACPower: true, batteryPercent: 100, batteryTemperatureC: 30)
    var signals: [AgentSignal] = []
    var cursorResult: Result<CursorActivity, CursorStateError> = .success(activity(working: 0, waiting: 0))
    var cursorCalls = 0
    let override = LoopOverride()
    let screen = LoopScreen()
    let notices = LoopNotices()
    let guardHandle = FakeGuard()
    let heartbeat: String
    var loop: AgentLoop!

    init(preferences: Preferences = Preferences()) {
        heartbeat = FileManager.default.temporaryDirectory.appendingPathComponent("halflid-loop-\(UUID().uuidString).beat").path
        let detector = WorkDetector(signals: { [unowned self] in self.signals }, cursor: { [unowned self] in
            self.cursorCalls += 1
            return try self.cursorResult.get()
        })
        loop = AgentLoop(
            preferences: preferences, detector: detector, system: { [unowned self] in self.system },
            executor: ActionExecutor(override: override, screen: screen, notices: notices),
            guardHandle: guardHandle, heartbeatPath: heartbeat, clock: { [unowned self] in self.now }
        )
    }

    deinit { try? FileManager.default.removeItem(atPath: heartbeat) }

    @discardableResult
    func tick(after seconds: Double = 0) -> AgentLoop.Status {
        now = now.addingTimeInterval(seconds)
        return loop.tick()
    }
}

// MARK: tests

private func instanceLockTests() {
    let path = NSTemporaryDirectory() + "halflid-lock-\(UUID().uuidString)/controller.lock"
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }

    var first: InstanceLock?
    if case .acquired(let held) = InstanceLock.acquire(path: path) { first = held }
    expect(first != nil, "the first controller gets the lock")
    if case .alreadyRunning = InstanceLock.acquire(path: path) {
        expect(true, "a second controller is told one is already running")
    } else {
        expect(false, "a second controller is told one is already running")
    }
    first = nil
    if case .acquired = InstanceLock.acquire(path: path) {
        expect(true, "the lock is free again once the holder is gone")
    } else {
        expect(false, "the lock is free again once the holder is gone")
    }
    if case .unavailable = InstanceLock.acquire(path: "/dev/null/impossible/controller.lock") {
        expect(true, "an unusable lock location is reported, not mistaken for a running controller")
    } else {
        expect(false, "an unusable lock location is reported, not mistaken for a running controller")
    }
}

func runLoopTests() {
    instanceLockTests()
    preferencesTests()
    loopTests()
    simulatedAgentTests()
    runCommandTests()
}

private func preferencesTests() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halflid-prefs-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/preferences.json"

    expect(Preferences.load(path: path) == Preferences(), "missing preferences file gives defaults")

    var changed = Preferences()
    changed.cursorEnabled = false
    changed.cliAgents = ["claude-code"]
    changed.limits.batteryStopPercent = 25
    changed.lockOnClose = false
    try? changed.save(path: path)
    expect(Preferences.load(path: path) == changed, "preferences survive a save and load")

    try? "{\"cursorEnabled\": false}".write(toFile: path, atomically: true, encoding: .utf8)
    var partial = Preferences.load(path: path)
    expect(partial.cursorEnabled == false && partial.lockOnClose && partial.limits == Limits().sanitized(), "a partial file keeps the other defaults")

    try? "{\"limits\": {\"batteryStopPercent\": 25}, \"someFutureKey\": 1}".write(toFile: path, atomically: true, encoding: .utf8)
    partial = Preferences.load(path: path)
    expect(partial.limits.batteryStopPercent == 25 && partial.limits.maxHoursOnBattery == 4, "a partial limits block keeps the other limits; unknown keys are ignored")

    try? "this is not json".write(toFile: path, atomically: true, encoding: .utf8)
    expect(Preferences.load(path: path) == Preferences(), "a damaged file gives defaults")
    try? "{\"cursorEnabled\": \"yes\"}".write(toFile: path, atomically: true, encoding: .utf8)
    expect(Preferences.load(path: path) == Preferences(), "a file with the wrong types gives defaults")

    // Safeguards cannot be switched off by a bad value.
    var risky = Limits()
    risky.batteryStopPercent = 0
    risky.batteryWarnPercent = 1
    risky.maxHoursOnBattery = 0
    risky.maxHoursOnAC = 1000
    risky.batteryTempStopC = 99
    risky.batteryTempWarnC = 99
    risky.batteryTempSustainSeconds = 100_000
    risky.thermalStopAt = .nominal
    risky.reassertSeconds = 5000
    let safe = risky.sanitized()
    expect(safe.batteryStopPercent == 5, "battery stop level has a floor")
    expect(safe.batteryWarnPercent >= safe.batteryStopPercent + 5, "battery warning stays above the stop level")
    expect(safe.maxHoursOnBattery == 0.25 && safe.maxHoursOnAC == 72, "duration limits stay in range")
    expect(safe.batteryTempStopC == 50 && safe.batteryTempWarnC < safe.batteryTempStopC, "battery temperature limits stay in range")
    expect(safe.batteryTempSustainSeconds == 600 && safe.reassertSeconds == 300, "timers stay in range")
    expect(safe.thermalStopAt == .fair, "the thermal limit cannot be set so low that it always stops")
    expect(Limits().sanitized() == Limits(), "default limits are already inside the safe ranges")
    try? "{\"limits\": {\"batteryStopPercent\": 0}}".write(toFile: path, atomically: true, encoding: .utf8)
    expect(Preferences.load(path: path).limits.batteryStopPercent == 5, "loading applies the safe ranges")
}

private func loopTests() {
    // Nothing running: nothing happens.
    do {
        let h = LoopHarness()
        let status = h.tick()
        expect(!status.armed && status.indicator == .idle && !status.report.working, "idle machine: not armed")
        expect(h.override.calls.isEmpty && h.guardHandle.startCount == 0 && h.guardHandle.stopCount == 1, "idle machine: override untouched, no guard running")
    }

    // Cursor working, then only waiting for the user: arms, then releases after the grace period.
    do {
        let h = LoopHarness()
        h.signals = [cursorRunning]
        h.cursorResult = .success(activity(working: 1, waiting: 5))
        var status = h.tick()
        expect(status.armed && status.indicator == .active && status.report.working, "Cursor working: armed")
        expect(h.override.lastIgnored == true && h.guardHandle.running, "arming applies the override and starts the guard")
        expect(FileManager.default.fileExists(atPath: h.heartbeat), "arming writes a heartbeat")
        expect(status.report.cursor?.waitingForUser == 5, "status reports the waiting chats")

        h.cursorResult = .success(activity(working: 0, waiting: 6))
        status = h.tick(after: 100)
        expect(status.armed && !status.report.working, "waiting chats alone do not count as work, but the grace period still holds")
        status = h.tick(after: 25)
        expect(!status.armed && status.indicator == .idle, "released once only waiting chats remain and the grace period is over")
        expect(h.override.lastIgnored == false && !h.guardHandle.running, "release restores the override and stops the guard")
    }

    // No guard, no override: if the guard process cannot start, the Mac is never held awake.
    do {
        let h = LoopHarness()
        h.guardHandle.failsToStart = true
        h.signals = [cursorRunning]
        h.cursorResult = .success(activity(working: 1, waiting: 0))
        let status = h.tick()
        expect(h.override.calls.allSatisfy { $0 == false }, "the override is never applied while the guard cannot start")
        expect(!status.armed && status.indicator == .warning && status.latch == .overrideFailed, "a missing guard is reported as a failure to stay awake")
        expect(!h.screen.events.contains("lock") && !h.screen.events.contains("display_off"), "no screen action without a held override")
        expect(h.notices.posted.contains(.stopped(.overrideFailed)), "the user is told")
        h.guardHandle.failsToStart = false
        let retried = h.tick(after: 61)
        expect(retried.armed && h.override.lastIgnored == true, "once the guard can start, the next attempt succeeds")
    }

    // Module off, Cursor not running, read errors.
    do {
        var off = Preferences()
        off.cursorEnabled = false
        let h = LoopHarness(preferences: off)
        h.signals = [cursorRunning]
        h.cursorResult = .success(activity(working: 3, waiting: 0))
        let status = h.tick()
        expect(!status.armed && h.cursorCalls == 0, "with the Cursor module off its state is never read")
    }
    do {
        let h = LoopHarness()
        h.cursorResult = .success(activity(working: 3, waiting: 0))
        let status = h.tick()
        expect(!status.armed && h.cursorCalls == 0, "Cursor's state is not read while no Cursor process exists")
    }
    do {
        let h = LoopHarness()
        h.signals = [cursorRunning]
        h.cursorResult = .failure(.databaseMissing)
        let status = h.tick()
        expect(!status.armed && status.report.cursorProblem != nil && status.report.cursor == nil, "an unreadable Cursor state is reported and never counted as work")
    }

    // Command-line agents.
    do {
        let h = LoopHarness()
        h.signals = [AgentSignal(agentId: "claude-code", processCount: 2, cpuPercent: 40)]
        var status = h.tick()
        expect(status.armed && status.report.workingAgents == ["claude-code"], "a busy command-line agent arms")
        h.signals = [AgentSignal(agentId: "claude-code", processCount: 2, cpuPercent: 2, newestSessionAgeSeconds: 100)]
        status = h.tick(after: 1)
        expect(status.report.workingAgents.isEmpty && status.armed, "a quiet agent is not working (grace still holds)")
        h.signals = [AgentSignal(agentId: "claude-code", processCount: 1, cpuPercent: 1, newestSessionAgeSeconds: 5)]
        status = h.tick(after: 1)
        expect(status.report.workingAgents == ["claude-code"], "a freshly written session file counts as work")
        h.signals = [AgentSignal(agentId: "claude-code", processCount: 0, cpuPercent: 90, newestSessionAgeSeconds: 1)]
        status = h.tick(after: 1)
        expect(status.report.workingAgents.isEmpty, "no process means not working, whatever the files say")
    }
    do {
        var only = Preferences()
        only.cliAgents = ["codex"]
        let h = LoopHarness(preferences: only)
        h.signals = [AgentSignal(agentId: "claude-code", processCount: 1, cpuPercent: 80)]
        expect(!h.tick().armed, "agents that are not selected are ignored")
        h.signals = [AgentSignal(agentId: "codex", processCount: 1, cpuPercent: 80)]
        expect(h.tick(after: 1).armed, "selected agents are watched")
    }

    // Manual hold.
    do {
        let h = LoopHarness()
        h.loop.hold = .untilStopped
        expect(h.tick().armed, "a manual hold arms without any agent")
        h.loop.hold = .none
        expect(!h.tick(after: 1).armed && h.override.lastIgnored == false, "dropping the hold releases")
    }

    // A timed hold ends by itself and is then gone: no hold and no end time in the past left in the status.
    do {
        let h = LoopHarness()
        let end = origin.addingTimeInterval(60)
        h.loop.hold = .until(end)
        var status = h.tick()
        expect(status.armed && status.hold == .until(end), "a timed hold arms and is shown")
        status = h.tick(after: 58)
        expect(status.armed && status.hold == .until(end), "a timed hold is still shown a moment before its end")
        status = h.tick(after: 3)
        expect(status.hold == .none && h.loop.hold == .none, "a timed hold that has ended is cleared, not left showing a past end time")
        status = h.tick(after: 125)
        expect(!status.armed && h.override.lastIgnored == false, "once the grace period is over the Mac is released")
        h.loop.hold = .until(h.now.addingTimeInterval(30))
        expect(h.tick().armed, "a new timed hold can be started after the first one ended")
    }

    // A failing override is reported, retried later, and never leaves the guard running.
    do {
        let h = LoopHarness()
        h.override.failuresLeft = 1
        h.loop.hold = .untilStopped
        var status = h.tick()
        expect(!status.armed && status.indicator == .warning && status.latch == .overrideFailed, "failed arm is shown as a warning")
        expect(h.notices.posted.contains(.stopped(.overrideFailed)), "failed arm posts a notice")
        expect(!h.guardHandle.running, "no guard is left running after a failed arm")
        expect(h.override.lastIgnored == false, "a failed arm is followed by a release")
        let callsBefore = h.override.calls.count
        status = h.tick(after: 30)
        expect(!status.armed && h.override.calls.count == callsBefore, "no retry before the retry delay")
        status = h.tick(after: 40)
        expect(status.armed && h.override.lastIgnored == true, "retry after the delay succeeds")
    }

    // Screen preferences.
    do {
        var quiet = Preferences()
        quiet.lockOnClose = false
        let h = LoopHarness(preferences: quiet)
        h.loop.hold = .untilStopped
        h.tick()
        h.system.lidClosed = true
        h.tick(after: 5)
        expect(h.screen.events == ["display_off"], "lock can be turned off while the display still turns off")
        var noDisplay = Preferences()
        noDisplay.displayOffOnClose = false
        let g = LoopHarness(preferences: noDisplay)
        g.loop.hold = .untilStopped
        g.tick()
        g.system.lidClosed = true
        g.tick(after: 5)
        expect(g.screen.events == ["lock"], "the display can be left alone while the screen still locks")
    }

    // Settings changed while running.
    do {
        let h = LoopHarness()
        h.system.onACPower = false
        h.system.batteryPercent = 35
        h.loop.hold = .untilStopped
        expect(h.tick().armed, "armed at 35 % on battery with default limits")
        var stricter = Preferences()
        stricter.limits.batteryStopPercent = 40
        h.loop.update(preferences: stricter)
        expect(!h.tick(after: 1).armed, "new limits apply to the running session")
    }

    // Guard supervision and shutdown.
    do {
        let h = LoopHarness()
        h.loop.hold = .untilStopped
        h.tick()
        h.guardHandle.running = false
        h.tick(after: 5)
        expect(h.guardHandle.running && h.guardHandle.startCount == 2, "a guard that died is started again while armed")
        h.loop.shutdown()
        expect(h.override.lastIgnored == false && !h.guardHandle.running, "shutdown releases the override and stops the guard")
        expect(h.screen.events.contains("restore"), "shutdown restores the screen")
        expect(!FileManager.default.fileExists(atPath: h.heartbeat), "shutdown removes the heartbeat")
    }

    // Lid closed while working: lock and display off once; work ends: release and ask for sleep.
    do {
        let h = LoopHarness()
        h.signals = [cursorRunning]
        h.cursorResult = .success(activity(working: 1, waiting: 0))
        h.tick()
        h.system.lidClosed = true
        h.tick(after: 3)
        expect(h.screen.events == ["lock", "display_off"], "lid closed while working: lock and display off")
        h.cursorResult = .success(activity(working: 0, waiting: 1))
        h.tick(after: 100)
        let status = h.tick(after: 30)
        expect(!status.armed && h.screen.events.contains("sleep:90"), "work ended with the lid closed: released and sleep requested")
    }
}

/// A simulated command-line agent: a real busy process matched by name, sampled by the real sampler.
private func simulatedAgentTests() {
    let burner = Process()
    burner.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
    burner.standardOutput = FileHandle.nullDevice
    burner.standardError = FileHandle.nullDevice
    let catalog = AgentCatalog(agents: [AgentDefinition(id: "simulated", processNames: ["yes"], sessionPaths: [])])
    let sampler = AgentSignalSampler(catalog: catalog)
    let detector = WorkDetector(signals: { sampler.sample() }, cursor: { throw CursorStateError.databaseMissing })
    var preferences = Preferences()
    preferences.cursorEnabled = false

    _ = sampler.sample()
    expect(!detector.detect(preferences: preferences).working, "simulated agent: not running means not working")
    guard (try? burner.run()) != nil else {
        expect(false, "simulated agent process could be started")
        return
    }
    defer { if burner.isRunning { burner.terminate() } }
    // A process seen for the first time has no CPU baseline (it reads as 0): the loop's regular ticks provide one.
    Thread.sleep(forTimeInterval: 0.3)
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1.0)
    let busy = detector.detect(preferences: preferences)
    expect(busy.working && busy.workingAgents == ["simulated"], "simulated agent: a busy process is working")
    burner.terminate()
    burner.waitUntilExit()
    Thread.sleep(forTimeInterval: 0.3)
    expect(!detector.detect(preferences: preferences).working, "simulated agent: finished process is not working")
}

/// The real `halflid run` command with the file stand-in for the override: the whole recovery chain with real processes.
private func runCommandTests() {
    let binary = repositoryRoot.appendingPathComponent("build/bin/halflid").path
    guard FileManager.default.isExecutableFile(atPath: binary) else {
        expect(false, "build/bin/halflid exists (scripts/test.sh builds it)")
        return
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halflid-run-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let overridePath = dir + "/override"
    let preferencesPath = dir + "/preferences.json"
    try? "{\"cursorEnabled\": false}".write(toFile: preferencesPath, atomically: true, encoding: .utf8)

    func launch(_ arguments: [String], pipe: Pipe? = nil) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["run", "--hold", "--poll", "1", "--no-screen"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["HALFLID_FAKE_OVERRIDE"] = overridePath
        environment["HALFLID_PREFERENCES"] = preferencesPath
        environment["HALFLID_RESOURCES"] = repositoryRoot.appendingPathComponent("Resources").path
        process.environment = environment
        process.standardOutput = pipe ?? FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        return process
    }
    func waitForState(_ expected: Bool, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if FileLidOverride.state(at: overridePath) == expected { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return FileLidOverride.state(at: overridePath) == expected
    }
    func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        return !process.isRunning
    }

    // Timed run: arms, then restores by itself.
    do {
        try? FileLidOverride(path: overridePath).setLidCloseIgnored(false)
        let pipe = Pipe()
        let process = launch(["--seconds", "4"], pipe: pipe)
        expect(waitForState(true, timeout: 6), "run --hold arms the override")
        expect(waitForExit(process, timeout: 12), "run --seconds ends by itself")
        expect(FileLidOverride.state(at: overridePath) == false, "run restores the override when it ends")
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        expect(output.contains("armed=1") && output.contains("stopped"), "run reports the state change and the stop")
        expect(process.terminationStatus == 0, "run exits cleanly")
    }

    // SIGTERM and SIGHUP restore immediately.
    for (name, number) in [("SIGTERM", SIGTERM), ("SIGHUP", SIGHUP)] {
        try? FileLidOverride(path: overridePath).setLidCloseIgnored(false)
        let process = launch([])
        expect(waitForState(true, timeout: 6), "run arms before \(name)")
        kill(process.processIdentifier, number)
        expect(waitForExit(process, timeout: 6), "run exits on \(name)")
        expect(FileLidOverride.state(at: overridePath) == false, "run restores the override on \(name)")
    }

    // kill -9: no cleanup code runs, the separate guard process must restore.
    do {
        try? FileLidOverride(path: overridePath).setLidCloseIgnored(false)
        let process = launch([])
        expect(waitForState(true, timeout: 6), "run arms before kill -9")
        Thread.sleep(forTimeInterval: 1.5) // the guard is started right after arming
        kill(process.processIdentifier, SIGKILL)
        _ = waitForExit(process, timeout: 3)
        expect(waitForState(false, timeout: 8), "the guard restored the override after kill -9 of the app")
    }
}
