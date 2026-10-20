import Foundation
import HalfLidCore
import IOKit.ps

// Spike CLI: machine-readable output only (JSON or key=value lines). User-facing prose comes from the catalogs.

setvbuf(stdout, nil, _IOLBF, 0)

let resourcesDirectory = ResourceLocator.resourcesDirectory()
let catalog: Catalog = resourcesDirectory.map { Catalog.load(directory: $0.appendingPathComponent("i18n"), language: Preferences.load().language) }
    ?? Catalog(language: "en", messages: [:], fallback: [:])

func fail(_ key: String, _ params: [String: String] = [:], code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data((catalog.text(key, params) + "\n").utf8))
    exit(code)
}

func option(_ name: String, default value: String) -> String {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return value }
    return args[index + 1]
}

func loadAgentCatalog() -> AgentCatalog {
    guard let directory = resourcesDirectory, let loaded = try? AgentCatalog.load(from: directory.appendingPathComponent("agents.json")) else {
        fail("cli.resourcesMissing", code: 1)
    }
    return loaded
}

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) { print(text) }
}

struct ProbeReport: Encodable {
    var system: SystemSnapshot
    var sleepAssertionCount: Int
    var processCount: Int
    var processScanMilliseconds: Double
}

func runProbe() {
    let start = DispatchTime.now()
    let processes = ProcessProbe.snapshot()
    let scanMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    printJSON(ProbeReport(
        system: SystemProbe.snapshot(),
        sleepAssertionCount: AssertionsProbe.read().filter(\.preventsSleep).count,
        processCount: processes.count,
        processScanMilliseconds: (scanMs * 10).rounded() / 10
    ))
}

func runSignals() {
    let seconds = Int(option("--seconds", default: "10")) ?? 10
    let interval = Double(option("--interval", default: "1")) ?? 1
    let sampler = AgentSignalSampler(catalog: loadAgentCatalog())
    let begin = Date()
    _ = sampler.sample(now: begin) // baseline for CPU deltas
    var tick = 0
    while Date().timeIntervalSince(begin) < Double(seconds) {
        Thread.sleep(forTimeInterval: interval)
        tick += 1
        let elapsed = Int(Date().timeIntervalSince(begin).rounded())
        let signals = sampler.sample()
        if signals.isEmpty { print("t=\(elapsed) agents=0") }
        for signal in signals {
            let age = signal.newestSessionAgeSeconds.map { String($0) } ?? "none"
            print("t=\(elapsed) agent=\(signal.agentId) procs=\(signal.processCount) cpu=\(signal.cpuPercent) assertions=\(signal.sleepAssertions) session_age_s=\(age)")
        }
    }
}

func runWatch() {
    let seconds = Double(option("--seconds", default: "30")) ?? 30
    func stamp(_ event: String, _ detail: String = "") {
        let snapshot = SystemProbe.snapshot()
        print("event=\(event) \(detail) lid_closed=\(snapshot.lidClosed.map(String.init) ?? "nil") on_ac=\(snapshot.onACPower.map(String.init) ?? "nil") battery=\(snapshot.batteryPercent.map(String.init) ?? "nil") thermal=\(snapshot.thermal.rawValue)")
    }
    let watcher = RootDomainWatcher { message in stamp("rootdomain", "message=0x" + String(message, radix: 16)) }
    if watcher == nil { print("event=rootdomain_unavailable") }
    let thermalToken = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in stamp("thermal") }
    let source = IOPSNotificationCreateRunLoopSource({ _ in stamp("power_source") }, nil)?.takeRetainedValue()
    if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
    stamp("start")
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    NotificationCenter.default.removeObserver(thermalToken)
    withExtendedLifetime(watcher) {}
}

/// `halflid icon --kind app|menubar|svg --state idle|active|warning --out PATH [--size N] [--scale N]`
func runIcon() {
    let state = GlyphState(rawValue: option("--state", default: "active")) ?? .active
    let kind = option("--kind", default: "app")
    let output = option("--out", default: "")
    guard !output.isEmpty else { fail("cli.usage") }
    let data: Data?
    switch kind {
    case "menubar":
        data = Glyph.menuBarPNG(state: state, scale: Int(option("--scale", default: "2")) ?? 2)
    case "svg":
        data = Glyph.svg(state: state).data(using: .utf8)
    default:
        data = Glyph.appIconPNG(state: state, pixelSize: Int(option("--size", default: "256")) ?? 256)
    }
    guard let data, (try? data.write(to: URL(fileURLWithPath: output))) != nil else { fail("cli.usage", code: 1) }
}

/// `halflid simulate list` or `halflid simulate <scenario>`: prints only the moments where something happens.
func runSimulate() {
    let name = CommandLine.arguments.dropFirst(2).first ?? "list"
    if name == "list" {
        Scenario.allCases.forEach { print($0.rawValue) }
        return
    }
    guard let scenario = Scenario(rawValue: name) else { fail("cli.unknownCommand", ["name": name]) }
    var previous: Indicator?
    for line in Simulator.run(scenario) {
        let changed = line.indicator != previous
        previous = line.indicator
        if line.actions.isEmpty && !changed { continue }
        let actions = line.actions.map(Simulator.describe).joined(separator: ",")
        print("t=\(line.seconds) armed=\(line.armed ? 1 : 0) indicator=\(line.indicator.rawValue) actions=\(actions)")
    }
}

/// `halflid cursor`: which Cursor chats are working, waiting for you, or idle. Read-only, state fields only, ids shortened.
func runCursor() {
    do {
        let activity = try CursorStateReader().read()
        print("working=\(activity.working) waiting=\(activity.waitingForUser) idle=\(activity.idle)")
        for chat in activity.chats where chat.activity != .idle {
            print("\(chat.id) \(chat.activity.rawValue)")
        }
    } catch {
        fail("cli.cursorUnavailable", ["reason": String(describing: error)])
    }
}

nonisolated(unsafe) var guardStopRequested = false

/// Recovery process: releases the lid override when the app dies, hangs, or this process is asked to stop.
/// `halflid guard --parent <pid> --heartbeat <file> [--poll <s>] [--max-age <s>]`
func runGuard() {
    let heartbeat = option("--heartbeat", default: "")
    guard let parent = Int32(option("--parent", default: "")), !heartbeat.isEmpty else { fail("cli.usage") }
    signal(SIGTERM) { _ in guardStopRequested = true }
    signal(SIGINT) { _ in guardStopRequested = true }
    signal(SIGHUP) { _ in guardStopRequested = true } // closing the terminal must release too, not kill the guard first
    // With the file stand-in (tests) the real screen must not be touched.
    let realSystem = ProcessInfo.processInfo.environment["HALFLID_FAKE_OVERRIDE"] == nil
    let override = LidOverrideFactory.make()
    print("override=\(override is FileLidOverride ? "file" : "iokit")")
    let guardian = Guardian(
        parentPid: parent, heartbeatPath: heartbeat, override: override,
        pollSeconds: Double(option("--poll", default: "1")) ?? 1,
        maxHeartbeatAge: Double(option("--max-age", default: "120")) ?? 120,
        afterRelease: { if realSystem { ScreenRepair.restore() } }
    )
    print("outcome=\(guardian.run(shouldStop: { guardStopRequested }).rawValue)")
}

/// `halflid repair`: puts the lid behaviour and the screen brightness back to normal. Safe to run at any time.
func runRepair() {
    let lidOK = (try? IOKitLidOverride().setLidCloseIgnored(false)) != nil
    let hadSavedBrightness = ScreenRepair.load() != nil
    let brightnessRestored = ScreenRepair.restore()
    print("lid_override=\(lidOK ? "normal" : "failed")")
    print("brightness=\(hadSavedBrightness ? (brightnessRestored ? "restored" : "failed") : "nothing_to_restore")")
}

/// Prints notices as key=value lines.
final class PrintNotices: NoticeSink {
    func post(_ notice: Notice) {
        switch notice {
        case .warning(let kind): print("notice=warning kind=\(kind.rawValue)")
        case .stopped(let reason): print("notice=stopped reason=\(reason.rawValue)")
        }
    }
}

/// Stand-in for the screen: prints what would happen. Used with `--no-screen` and when the lid override is faked.
final class PrintScreen: ScreenControl {
    func lockScreen() { print("screen=lock") }
    func displayOff() { print("screen=display_off") }
    func restoreScreen() { print("screen=restore") }
    func sleepIfStillAwake(afterSeconds: Int) { print("screen=sleep_if_still_awake after=\(afterSeconds)") }
    func cancelPendingSleep() {}
}

nonisolated(unsafe) var runSignalSources: [DispatchSourceSignal] = []
nonisolated(unsafe) var runLoopInstance: AgentLoop?
nonisolated(unsafe) var runInstanceLock: InstanceLock?

/// `halflid run [--poll S] [--seconds N] [--hold | --hold-minutes N] [--no-screen]`: the agent loop without an interface.
/// Keeps the Mac awake with the lid closed while a watched agent works, within the safety limits, and puts everything back
/// when work ends or this process is stopped. Prints one key=value line whenever the state changes.
func runAgentLoop() {
    let arguments = CommandLine.arguments
    let environment = ProcessInfo.processInfo.environment
    let poll = max(1, Double(option("--poll", default: "5")) ?? 5)
    let seconds = Double(option("--seconds", default: "0")) ?? 0
    let preferences = Preferences.load()
    let fakeOverride = environment["HALFLID_FAKE_OVERRIDE"] != nil
    let screen: ScreenControl = (arguments.contains("--no-screen") || fakeOverride)
        ? PrintScreen()
        : SystemScreenControl(log: { FileHandle.standardError.write(Data(("log: \($0)\n").utf8)) })

    if !fakeOverride {
        // Two controllers would clear each other's override: only one may run (the app takes the same lock).
        switch InstanceLock.acquire() {
        case .acquired(let held): runInstanceLock = held
        case .alreadyRunning: fail("cli.alreadyRunning", code: 75)
        case .unavailable: break
        }
        ScreenRepair.restore() // repair a black screen left by an earlier crash
    }

    let heartbeat = NSTemporaryDirectory() + "halflid-\(getpid()).beat"
    guard let executable = Bundle.main.executableURL else { fail("cli.screenTest.noGuard") }
    // Session folders are walked only for watched command-line agents that are running (see AgentSignalSampler).
    let sampler = AgentSignalSampler(
        catalog: loadAgentCatalog(),
        scansSessions: { agent, processes in processes > 0 && preferences.watchesCommandLineAgent(agent.id) }
    )
    _ = sampler.sample() // baseline for CPU deltas
    let reader = CursorStateReader()
    let detector = WorkDetector(signals: { sampler.sample() }, cursor: { try reader.read() })
    let override = LidOverrideFactory.make()
    let log: (String) -> Void = { FileHandle.standardError.write(Data(("log: \($0)\n").utf8)) }
    let loop = AgentLoop(
        preferences: preferences, detector: detector, system: { SystemProbe.snapshot() },
        executor: ActionExecutor(
            override: override, screen: screen, notices: PrintNotices(), keeper: OverrideKeeper(override: override, log: log),
            log: log
        ),
        guardHandle: GuardProcess(executable: executable, heartbeatPath: heartbeat), heartbeatPath: heartbeat
    )
    if arguments.contains("--hold") { loop.hold = .untilStopped }
    if let minutes = Double(option("--hold-minutes", default: "")) { loop.hold = .until(Date().addingTimeInterval(minutes * 60)) }
    runLoopInstance = loop

    let started = Date()
    var previous = ""
    func describe(_ status: AgentLoop.Status) -> String {
        let cursor = status.report.cursor.map { "\($0.working)/\($0.waitingForUser)/\($0.idle)" } ?? "none"
        let problem = status.report.cursorProblem == nil ? "" : " cursor_problem=1"
        let agents = status.report.workingAgents.isEmpty ? "none" : status.report.workingAgents.joined(separator: ",")
        let system = status.system
        return "armed=\(status.armed ? 1 : 0) indicator=\(status.indicator.rawValue) working=\(status.report.working ? 1 : 0)"
            + " cursor_w_wait_idle=\(cursor)\(problem) agents_working=\(agents) latch=\(status.latch?.rawValue ?? "none")"
            + " lid_closed=\(system.lidClosed.map { $0 ? 1 : 0 } ?? -1) ac=\(system.onACPower.map { $0 ? 1 : 0 } ?? -1)"
            + " battery=\(system.batteryPercent ?? -1) thermal=\(system.thermal.rawValue)"
    }
    func tick() {
        let line = describe(loop.tick())
        if line != previous {
            print("t=\(Int(Date().timeIntervalSince(started))) \(line)")
            previous = line
        }
    }
    func stop() {
        loop.shutdown()
        print("stopped")
        exit(0)
    }

    for number in [SIGINT, SIGTERM, SIGHUP] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { stop() }
        source.resume()
        runSignalSources.append(source)
    }

    var lidWasClosed = PowerRegistry.lidClosed()
    let watcher = RootDomainWatcher(queue: .main) { _ in
        let now = PowerRegistry.lidClosed()
        if now != lidWasClosed {
            lidWasClosed = now
            tick()
        }
    }
    _ = watcher
    tick()
    let timer = Timer(timeInterval: poll, repeats: true) { _ in tick() }
    RunLoop.main.add(timer, forMode: .common)
    if seconds > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { stop() } }
    withExtendedLifetime(watcher) { RunLoop.main.run() }
}

nonisolated(unsafe) var screenTestStopRequested = false

/// `halflid screen-test`: with the lid override on, wait for the lid to close, then lock, turn the display off, and report
/// what actually happened. Restores everything when the lid opens. A guard process covers a crash of this command.
func runScreenTest() {
    guard PowerRegistry.lidClosed() != nil else { fail("cli.screenTest.noLid") }
    func yesNo(_ value: Bool?) -> String { value.map { $0 ? "yes" : "no" } ?? "unknown" }
    func number(_ value: Float?) -> String { value.map { String(format: "%.2f", $0) } ?? "unknown" }

    signal(SIGINT) { _ in screenTestStopRequested = true }
    signal(SIGTERM) { _ in screenTestStopRequested = true }

    let override = LidOverrideFactory.make()
    let screen = SystemScreenControl(log: { FileHandle.standardError.write(Data(("log: \($0)\n").utf8)) })
    ScreenRepair.restore()

    let beat = NSTemporaryDirectory() + "halflid-screentest-\(getpid()).beat"
    Heartbeat.touch(path: beat)
    let guardProcess = Process()
    guardProcess.executableURL = Bundle.main.executableURL
    guardProcess.arguments = ["guard", "--parent", String(getpid()), "--heartbeat", beat, "--poll", "0.5", "--max-age", "20"]
    guardProcess.standardOutput = FileHandle.nullDevice
    guardProcess.standardError = FileHandle.nullDevice
    do { try guardProcess.run() } catch { fail("cli.screenTest.noGuard") }

    func cleanUp() {
        screen.restoreScreen()
        try? override.setLidCloseIgnored(false)
        if guardProcess.isRunning { guardProcess.terminate() }
        try? FileManager.default.removeItem(atPath: beat)
    }
    do { try override.setLidCloseIgnored(true) } catch {
        cleanUp()
        fail("cli.screenTest.overrideFailed", ["reason": String(describing: error)])
    }

    let brightnessBefore = DisplayBrightness.current()
    print(catalog.text("cli.screenTest.start"))
    let started = Date()
    var closedAt: Date?
    var lockedSeen = false
    var asleepAfter: Double?
    var brightnessDuring: Float?
    var closedSeconds = 0.0

    while !screenTestStopRequested {
        Heartbeat.touch(path: beat)
        let lidClosed = PowerRegistry.lidClosed() ?? false
        if lidClosed && closedAt == nil {
            closedAt = Date()
            print(catalog.text("cli.screenTest.closed"))
            screen.lockScreen()
            screen.displayOff()
        }
        if let closedAt {
            closedSeconds = Date().timeIntervalSince(closedAt)
            if !lidClosed || closedSeconds > 120 { break }
            if ScreenProbe.sessionLocked() == true { lockedSeen = true }
            if ScreenProbe.displayAsleep(), asleepAfter == nil { asleepAfter = closedSeconds }
            if let value = DisplayBrightness.current() { brightnessDuring = min(brightnessDuring ?? value, value) }
        } else if Date().timeIntervalSince(started) > 60 {
            print(catalog.text("cli.screenTest.timeout"))
            cleanUp()
            return
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    cleanUp()
    Thread.sleep(forTimeInterval: 1)
    print("lid_closed_seconds=\(Int(closedSeconds))")
    print("session_locked=\(yesNo(closedAt == nil ? nil : lockedSeen))")
    print("display_asleep=\(yesNo(closedAt == nil ? nil : asleepAfter != nil))")
    print("display_asleep_after_seconds=\(asleepAfter.map { String(format: "%.1f", $0) } ?? "never")")
    print("brightness_before=\(number(brightnessBefore))")
    print("brightness_lowest_while_closed=\(number(brightnessDuring))")
    print("brightness_after=\(number(DisplayBrightness.current()))")
    print(catalog.text("cli.screenTest.done"))
}

nonisolated(unsafe) var sleepTestStopRequested = false

/// `halflid sleep-test`: with the lid override on, wait for the lid to close, lock and turn the display off, release the
/// override 3 s later and report whether (and when) the Mac went to sleep: by itself, through our 15 s fallback, or not at all.
/// Sleep is detected as a gap between wall-clock time and awake time. A guard process covers a crash of this command.
func runSleepTest() {
    guard PowerRegistry.lidClosed() != nil else { fail("cli.screenTest.noLid") }
    func seconds(_ value: Double?) -> String { value.map { String(format: "%.0f", $0) } ?? "none" }

    signal(SIGINT) { _ in sleepTestStopRequested = true }
    signal(SIGTERM) { _ in sleepTestStopRequested = true }

    let releaseAfter = 3.0
    let fallbackSeconds = 15
    let override = LidOverrideFactory.make()
    let screen = SystemScreenControl(log: { FileHandle.standardError.write(Data(("log: \($0)\n").utf8)) })
    ScreenRepair.restore()

    let beat = NSTemporaryDirectory() + "halflid-sleeptest-\(getpid()).beat"
    Heartbeat.touch(path: beat)
    guard let executable = Bundle.main.executableURL else { fail("cli.screenTest.noGuard") }
    let guardProcess = GuardProcess(executable: executable, heartbeatPath: beat)
    guardProcess.start()

    func cleanUp() {
        screen.cancelPendingSleep()
        screen.restoreScreen()
        try? override.setLidCloseIgnored(false)
        guardProcess.stop()
        try? FileManager.default.removeItem(atPath: beat)
    }
    guard guardProcess.isRunning else { cleanUp(); fail("cli.screenTest.noGuard") }
    do { try override.setLidCloseIgnored(true) } catch {
        cleanUp()
        fail("cli.screenTest.overrideFailed", ["reason": String(describing: error)])
    }

    print(catalog.text("cli.sleepTest.start"))
    let started = Date()
    var closedAt: Date?
    var releasedAt: Date?
    var closedSeconds = 0.0
    var sleepStartedAfterRelease: Double?
    var sleepGapSeconds: Double?
    var previousWall = Date()
    var previousAwake = ProcessInfo.processInfo.systemUptime

    while !sleepTestStopRequested {
        let wall = Date()
        let awake = ProcessInfo.processInfo.systemUptime
        // Wall time keeps running while the Mac sleeps, awake time does not: the difference is the time spent asleep.
        let gap = wall.timeIntervalSince(previousWall) - (awake - previousAwake)
        if gap > 3, sleepGapSeconds == nil, let releasedAt {
            sleepGapSeconds = gap
            sleepStartedAfterRelease = max(0, previousWall.timeIntervalSince(releasedAt))
        }
        previousWall = wall
        previousAwake = awake

        Heartbeat.touch(path: beat)
        let lidClosed = PowerRegistry.lidClosed() ?? false
        if lidClosed && closedAt == nil {
            closedAt = wall
            print(catalog.text("cli.sleepTest.closed"))
            screen.lockScreen()
            screen.displayOff()
        }
        if let closedAt {
            closedSeconds = wall.timeIntervalSince(closedAt)
            if releasedAt == nil, closedSeconds >= releaseAfter {
                try? override.setLidCloseIgnored(false)
                releasedAt = Date()
                screen.sleepIfStillAwake(afterSeconds: fallbackSeconds)
            }
            if !lidClosed || closedSeconds > 120 { break }
        } else if wall.timeIntervalSince(started) > 60 {
            print(catalog.text("cli.sleepTest.timeout"))
            cleanUp()
            return
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    cleanUp()
    Thread.sleep(forTimeInterval: 1)
    let result: String
    if closedAt == nil { result = "lid_never_closed" }
    else if releasedAt == nil { result = "lid_opened_too_soon" }
    else if sleepGapSeconds == nil { result = "stayed_awake" }
    else if (sleepStartedAfterRelease ?? 0) < Double(fallbackSeconds) - 2 { result = "slept_by_itself" }
    else { result = "slept_by_fallback" }
    print("result=\(result)")
    print("lid_closed_seconds=\(Int(closedSeconds))")
    print("release_after_close_seconds=\(Int(releaseAfter))")
    print("fallback_after_release_seconds=\(fallbackSeconds)")
    print("slept_after_release_seconds=\(seconds(sleepStartedAfterRelease))")
    print("slept_for_seconds=\(seconds(sleepGapSeconds))")
    print(catalog.text("cli.sleepTest.done"))
}

/// "1.0 (1)" from the app bundle this tool lives in, or "development" for a build outside a bundle.
func versionText() -> String {
    let info = Bundle.main.infoDictionary
    guard let version = info?["CFBundleShortVersionString"] as? String else { return "halflid development" }
    let build = (info?["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
    return "halflid \(version)\(build)"
}

switch CommandLine.arguments.dropFirst().first {
case "probe": runProbe()
case "signals": runSignals()
case "watch": runWatch()
case "icon": runIcon()
case "simulate": runSimulate()
case "guard": runGuard()
case "cursor": runCursor()
case "screen-test": runScreenTest()
case "sleep-test": runSleepTest()
case "repair": runRepair()
case "run": runAgentLoop()
case "status": exit(UserCommands.status(catalog: catalog, arguments: CommandLine.arguments))
case "start": exit(UserCommands.start(catalog: catalog, arguments: CommandLine.arguments))
case "stop": exit(UserCommands.stop(catalog: catalog))
case "version", "--version": print(versionText())
case "help", "--help", "-h": print(catalog.text("cli.usage"))
case let name?: fail("cli.unknownCommand", ["name": name])
case nil: fail("cli.usage")
}
