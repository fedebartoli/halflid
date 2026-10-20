import Foundation
import HalfLidCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func catalogs() -> (en: Catalog, it: Catalog) {
    let directory = repositoryRoot.appendingPathComponent("Resources/i18n")
    return (Catalog.load(directory: directory, preferred: ["en"]), Catalog.load(directory: directory, preferred: ["it"]))
}

private func status(
    armed: Bool, indicator: Indicator = .active, latch: StopReason? = nil, cursorWorking: Int = 0, agents: [String] = [],
    hold: Hold = .none, cursorProblem: String? = nil, at: Date = t0
) -> AgentLoop.Status {
    var report = WorkReport()
    if cursorWorking > 0 { report.cursor = CursorActivity(chats: (0..<cursorWorking).map { CursorChat(id: "c\($0)", activity: .working) }) }
    report.workingAgents = agents
    report.working = cursorWorking > 0 || !agents.isEmpty
    report.cursorProblem = cursorProblem
    return AgentLoop.Status(armed: armed, indicator: indicator, latch: latch, report: report, hold: hold, at: at)
}

func runPresentationTests() {
    let (en, it) = catalogs()

    // Every text the presenter can ask for exists in both languages (a missing key would show up as the key itself).
    var keys = ["status.idle", "status.idle.detail", "status.cursorProblem", "status.active", "status.active.working", "status.active.grace",
                "status.hold.untilStopped", "status.hold.until", "status.warning", "status.stopped", "duration.short",
                "duration.minutes", "duration.hours", "session.last", "session.ending.finished", "session.ending.quit",
                "menu.keepAwake", "menu.keepAwake.untilStopped", "menu.keepAwake.minutes30", "menu.keepAwake.hour1",
                "menu.keepAwake.hours2", "menu.keepAwake.hours4", "menu.keepAwake.stop", "menu.watch", "menu.lid",
                "menu.lid.lock", "menu.lid.displayOff", "menu.quit", "menu.settings", "panel.agents", "panel.chip.hours",
                "panel.watch", "panel.holdLabel", "agent.state.working", "agent.state.idle", "agent.state.notRunning",
                "agent.state.off"]
    keys += StopReason.allCases.map { "status.stopped.\($0.rawValue)" }
    keys += StopReason.allCases.map { "session.ending.\($0.rawValue)" }
    if let agents = try? AgentCatalog.load(from: repositoryRoot.appendingPathComponent("Resources/agents.json")) {
        keys += agents.agents.map { "agent.\($0.id)" }
    } else {
        expect(false, "agents.json can be loaded for the presentation tests")
    }
    for key in keys {
        expect(en.text(key) != key, "english text exists for \(key)")
        expect(it.text(key) != key, "italian text exists for \(key)")
    }

    // Status text.
    let idle = StatusPresenter.present(status(armed: false, indicator: .idle), catalog: en)
    expect(idle.glyph == .idle && idle.title == "Ready" && idle.detail == "Nothing is running", "idle presentation")
    let problem = StatusPresenter.present(status(armed: false, indicator: .idle, cursorProblem: "x"), catalog: en)
    expect(problem.detail == "Cursor’s state cannot be read", "an unreadable Cursor is said so while idle")
    expect(!(problem.detail ?? "").contains("x"), "the raw error text is not shown")

    let cursorOnly = StatusPresenter.present(status(armed: true, cursorWorking: 2), catalog: en)
    expect(cursorOnly.glyph == .active && cursorOnly.title == "Keeping the Mac awake", "active title and glyph")
    expect(cursorOnly.detail == "Cursor working", "one agent is named once however many chats work")
    let both = StatusPresenter.present(status(armed: true, cursorWorking: 1, agents: ["codex", "claude-code"]), catalog: en)
    expect(both.detail == "Cursor, Claude Code, Codex working", "several agents are listed in a stable order")
    let italian = StatusPresenter.present(status(armed: true, cursorWorking: 1), catalog: it)
    expect(italian.title == "Tengo il Mac sveglio" && italian.detail == "Cursor al lavoro", "italian presentation")

    let grace = StatusPresenter.present(status(armed: true), catalog: en)
    expect(grace.detail == "Work just ended, waiting a little", "armed with nothing working is the grace period")
    let held = StatusPresenter.present(status(armed: true, hold: .untilStopped), catalog: en)
    expect(held.detail == "Held until you stop it", "manual hold without a deadline")
    let timed = StatusPresenter.present(status(armed: true, hold: .until(t0.addingTimeInterval(1800))), catalog: en)
    let timedText = timed.detail ?? ""
    expect(timedText.hasPrefix("Held until ") && timedText.count == "Held until 00:00".count && timedText.contains(":"), "timed hold shows a clock time")
    let warning = StatusPresenter.present(status(armed: true, indicator: .warning, cursorWorking: 1), catalog: en)
    expect(warning.glyph == .warning && warning.detail == "Close to a safety limit", "warning state")
    for reason in StopReason.allCases {
        let stopped = StatusPresenter.present(status(armed: false, indicator: .warning, latch: reason), catalog: en)
        expect(stopped.title == "Stopped to protect the Mac" && stopped.glyph == .warning, "stopped title for \(reason)")
        expect(stopped.detail == en.text("status.stopped.\(reason.rawValue)"), "stopped reason text for \(reason)")
    }

    // Durations.
    expect(StatusPresenter.duration(20, catalog: en) == "under a minute", "duration under a minute")
    expect(StatusPresenter.duration(35 * 60 + 10, catalog: en) == "35 min", "duration in minutes")
    expect(StatusPresenter.duration(72 * 60, catalog: en) == "1 h 12 min", "duration in hours and minutes")
    expect(StatusPresenter.duration(3 * 3600, catalog: en) == "3 h 0 min", "whole hours keep the minutes")

    runPanelTests(en, it)
    runSessionTests(en)
}

private func runPanelTests(_ en: Catalog, _ it: Catalog) {
    guard let agents = try? AgentCatalog.load(from: repositoryRoot.appendingPathComponent("Resources/agents.json")) else {
        expect(false, "agents.json loads for the panel tests")
        return
    }
    expect(agents.agents.first { $0.id == "cursor" }?.appBundleIds == ["com.todesktop.230313mzl4w4u92"], "Cursor's app icon is looked up by its bundle id")
    // An older catalog without `appBundleIds` still loads, with no icon ids.
    let legacy = #"{"agents":[{"id":"x","processNames":["x"],"pathContains":[],"sessionPaths":[],"verified":false}]}"#
    expect((try? JSONDecoder().decode(AgentCatalog.self, from: Data(legacy.utf8)))?.agents.first?.appBundleIds == [], "a catalog without app ids still loads")

    // Cursor is working, Claude Code runs but is idle, Goose is watched but absent, Codex and opencode are switched off.
    var preferences = Preferences()
    preferences.cliAgents = ["claude-code", "goose"]
    var working = status(armed: true, cursorWorking: 1)
    working.report.seenAgents = ["cursor", "claude-code"]
    let content = PanelPresenter.present(status: working, preferences: preferences, agents: agents, lastSession: nil, catalog: en)
    let states = Dictionary(uniqueKeysWithValues: content.agents.map { ($0.id, $0.state) })
    expect(content.agents.map(\.id) == agents.agents.map(\.id), "the panel lists the agents in catalog order")
    expect(states["cursor"] == .working, "Cursor with a working chat is working")
    expect(states["claude-code"] == .idle, "a watched agent that runs without working is idle")
    expect(states["goose"] == .notRunning, "a watched agent that was not seen is not running")
    expect(states["codex"] == .off && states["opencode"] == .off, "agents that are not watched are off")
    expect(content.agents.first { $0.id == "codex" }?.watched == false, "off means not watched")
    expect(content.agents.first { $0.id == "cursor" }?.stateText == "Working", "state text comes from the catalog")
    expect(content.title == "Keeping the Mac awake" && content.detail == "Cursor working", "the panel header is the status text")
    expect(!content.holding, "no manual hold")

    // Cursor switched off wins over its activity; a command-line agent that works shows as working.
    preferences.cursorEnabled = false
    var cli = status(armed: true, agents: ["claude-code"])
    cli.report.seenAgents = ["claude-code", "cursor"]
    let second = PanelPresenter.present(status: cli, preferences: preferences, agents: agents, lastSession: nil, catalog: en)
    let secondStates = Dictionary(uniqueKeysWithValues: second.agents.map { ($0.id, $0.state) })
    expect(secondStates["cursor"] == .off, "Cursor switched off shows as off even if it runs")
    expect(secondStates["claude-code"] == .working, "a working command-line agent shows as working")

    // Holding, and the last session line only while nothing is held.
    let session = SessionSummary(startedAt: t0, endedAt: t0.addingTimeInterval(4_320), ending: .finished, stopReason: nil)
    let holding = PanelPresenter.present(
        status: status(armed: true, hold: .untilStopped), preferences: Preferences(), agents: agents, lastSession: session, catalog: en
    )
    expect(holding.holding && holding.sessionLine == nil, "while holding there is no session line")
    let resting = PanelPresenter.present(
        status: status(armed: false, indicator: .idle), preferences: Preferences(), agents: agents, lastSession: session, catalog: en
    )
    expect(!resting.holding && resting.sessionLine == "Last session: 1 h 12 min (work finished)", "idle shows the last session")
    let italian = PanelPresenter.present(status: working, preferences: preferences, agents: agents, lastSession: nil, catalog: it)
    expect(italian.agents.first { $0.id == "cursor" }?.stateText == "Disattivato", "italian state text")
    expect(content == PanelPresenter.present(status: working, preferences: Preferences().with(cli: ["claude-code", "goose"]), agents: agents, lastSession: nil, catalog: en), "equal inputs give equal content (no redraw needed)")
}

private extension Preferences {
    func with(cli: [String]) -> Preferences {
        var copy = self
        copy.cliAgents = cli
        return copy
    }
}

private func runSessionTests(_ en: Catalog) {
    // A session starts when the Mac is first held and ends when it is released.
    var tracker = SessionTracker()
    expect(tracker.observe(status(armed: false, indicator: .idle, at: t0)) == nil, "no summary before any session")
    expect(tracker.observe(status(armed: true, at: t0.addingTimeInterval(10))) == nil, "no summary while the session starts")
    expect(tracker.observe(status(armed: true, at: t0.addingTimeInterval(70))) == nil, "no summary while it runs")
    let finished = tracker.observe(status(armed: false, indicator: .idle, at: t0.addingTimeInterval(4_330)))
    expect(finished?.ending == .finished && finished?.stopReason == nil, "a normal end is 'finished'")
    expect(finished?.durationSeconds == 4_320, "duration runs from the first armed tick to the release")
    expect(tracker.observe(status(armed: false, indicator: .idle, at: t0.addingTimeInterval(4_400))) == nil, "an end is reported once")
    if let finished { expect(StatusPresenter.sessionLine(finished, catalog: en) == "Last session: 1 h 12 min (work finished)", "session line") }

    // A limit ends the session with its reason, and a later normal session does not inherit it.
    _ = tracker.observe(status(armed: true, at: t0.addingTimeInterval(5_000)))
    let limited = tracker.observe(status(armed: false, indicator: .warning, latch: .batteryLow, at: t0.addingTimeInterval(5_600)))
    expect(limited?.ending == .limit && limited?.stopReason == .batteryLow, "a limit ends the session with its reason")
    if let limited { expect(StatusPresenter.sessionLine(limited, catalog: en) == "Last session: 10 min (battery low)", "limit session line") }
    expect(tracker.observe(status(armed: false, indicator: .warning, latch: .batteryLow, at: t0.addingTimeInterval(5_700))) == nil, "a latch that stays does not repeat the summary")
    _ = tracker.observe(status(armed: true, at: t0.addingTimeInterval(9_000)))
    let later = tracker.observe(status(armed: false, indicator: .idle, at: t0.addingTimeInterval(9_100)))
    expect(later?.ending == .finished && later?.stopReason == nil, "a later normal session does not inherit the old reason")

    // Quitting closes an open session; with none open there is nothing to report.
    expect(tracker.finish(at: t0.addingTimeInterval(9_200)) == nil, "quit without a session reports nothing")
    _ = tracker.observe(status(armed: true, at: t0.addingTimeInterval(10_000)))
    let quit = tracker.finish(at: t0.addingTimeInterval(10_090))
    expect(quit?.ending == .quit && quit?.durationSeconds == 90, "quit closes the open session")
    expect(tracker.finish(at: t0.addingTimeInterval(10_100)) == nil, "quit twice reports once")

    // Persistence: a round trip, and damaged files read as 'no session'.
    let directory = NSTemporaryDirectory() + "halflid-session-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let path = directory + "/last-session.json"
    expect(SessionStore.load(path: path) == nil, "no file means no session")
    if let finished {
        SessionStore.save(finished, path: path)
        expect(SessionStore.load(path: path) == finished, "a saved session loads back unchanged")
    }
    try? "not json".write(toFile: path, atomically: true, encoding: .utf8)
    expect(SessionStore.load(path: path) == nil, "a damaged file reads as no session")
}
