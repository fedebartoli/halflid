import Foundation
import HalfLidCore

/// Runs the real `HalfLidApp --print-menu` with the file stand-in for the lid override and a scratch preferences file, so
/// nothing on the machine is touched. Checks what the menu would show.
private func printMenu(
    mode: String = "--print-menu", arguments: [String] = [], preferences: String, directory: String
) -> (lines: [String], status: Int32)? {
    let binary = repositoryRoot.appendingPathComponent("build/bin/HalfLidApp").path
    guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
    try? preferences.write(toFile: directory + "/preferences.json", atomically: true, encoding: .utf8)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    // The language is always explicit: without it the menu follows the language of whoever runs the tests.
    let language = arguments.contains("-AppleLanguages") ? [] : ["-AppleLanguages", "(en)"]
    process.arguments = [mode] + arguments + language
    var environment = ProcessInfo.processInfo.environment
    environment["HALFLID_FAKE_OVERRIDE"] = directory + "/override"
    environment["HALFLID_PREFERENCES"] = directory + "/preferences.json"
    environment["HALFLID_LAST_SESSION"] = directory + "/last-session.json"
    environment["HALFLID_RESOURCES"] = repositoryRoot.appendingPathComponent("Resources").path
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    return (lines.filter { !$0.isEmpty }, process.terminationStatus)
}

func runAppTests() {
    let directory = NSTemporaryDirectory() + "halflid-app-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }

    // Nothing is watched, so nothing can start the Mac holding itself awake: the idle menu.
    let quiet = #"{"cursorEnabled": false, "cliAgents": []}"#
    guard let idle = printMenu(preferences: quiet, directory: directory) else {
        expect(false, "build/bin/HalfLidApp exists and runs (scripts/test.sh builds it)")
        return
    }
    expect(idle.status == 0, "the app prints its menu and exits cleanly")
    expect(idle.lines.first == "# Ready", "idle menu starts with the status header")
    expect(idle.lines.contains("~ Nothing is running"), "idle menu explains the state")
    expect(idle.lines.contains("Keep awake"), "idle menu offers to keep the Mac awake")
    for option in ["Until I stop it", "For 30 minutes", "For 1 hour", "For 2 hours", "For 4 hours"] {
        expect(idle.lines.contains("  " + option), "keep awake offers: \(option)")
    }
    expect(!idle.lines.contains("Stop keeping awake"), "no stop entry while nothing is held")
    expect(idle.lines.contains("Watch") && idle.lines.contains("  Cursor") && idle.lines.contains("  Claude Code"), "watch lists the agents")
    expect(!idle.lines.contains(where: { $0.contains("[x] Cursor") || $0.contains("[x] Codex") }), "switched-off agents are not checked")
    expect(idle.lines.contains("  [x] Lock the screen") && idle.lines.contains("  [x] Turn the display off"), "the lid options are on by default")
    expect(idle.lines.last == "Quit Half Lid", "quit is the last entry")
    expect(!idle.lines.contains(where: { $0.contains("diag.") || $0.hasPrefix("status.") || $0.hasPrefix("menu.") }), "no catalog key leaks into the menu")

    // Watched agents are checked; unwatched ones are not.
    let watching = #"{"cursorEnabled": false, "cliAgents": ["claude-code"], "lockOnClose": false}"#
    if let watched = printMenu(preferences: watching, directory: directory) {
        expect(watched.lines.contains("  [x] Claude Code") && !watched.lines.contains("  [x] Codex"), "only watched command-line agents are checked")
        expect(watched.lines.contains("  Lock the screen") && watched.lines.contains("  [x] Turn the display off"), "a switched-off lid option is unchecked")
    } else {
        expect(false, "menu with a watched agent can be printed")
    }

    // A manual hold: the header, the reason, and a stop entry instead of the duration list.
    if let held = printMenu(arguments: ["--hold"], preferences: quiet, directory: directory) {
        expect(held.lines.first == "# Keeping the Mac awake", "holding: the header says so")
        expect(held.lines.contains("~ Held until you stop it"), "holding: the reason is shown")
        expect(held.lines.contains("Stop keeping awake"), "holding: a stop entry is offered")
        expect(!held.lines.contains("Keep awake"), "holding: the duration list is gone")
        expect(FileLidOverride.state(at: directory + "/override") == false, "the app released the stand-in override when it exited")
    } else {
        expect(false, "menu while holding can be printed")
    }

    // The same menu in Italian.
    if let italian = printMenu(arguments: ["-AppleLanguages", "(it)"], preferences: quiet, directory: directory) {
        expect(italian.lines.first == "# Pronto", "the menu follows the system language")
        expect(italian.lines.contains("Tieni sveglio") && italian.lines.contains("Impostazioni…") && italian.lines.last == "Esci da Half Lid", "italian entries")
    } else {
        expect(false, "italian menu can be printed")
    }
    expect(idle.lines.contains("Settings…"), "the menu offers the settings window")

    runPanelAppTests()
}

/// Runs the real `HalfLidPanel --print`: the content the menu bar app would send goes in on standard input, the views the
/// panel would show come out as text. No window is opened and nothing on the machine is touched.
private func printPanel(
    watching cliAgents: [String] = [], cursorEnabled: Bool = false, hold: Hold = .none, language: String = "en"
) -> (lines: [String], status: Int32)? {
    let binary = repositoryRoot.appendingPathComponent("build/bin/HalfLidPanel").path
    guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
    let resources = repositoryRoot.appendingPathComponent("Resources")
    guard let agents = try? AgentCatalog.load(from: resources.appendingPathComponent("agents.json")) else { return nil }
    let catalog = Catalog.load(directory: resources.appendingPathComponent("i18n"), preferred: [language])
    var preferences = Preferences()
    preferences.cursorEnabled = cursorEnabled
    preferences.cliAgents = cliAgents
    let held = hold != .none
    let status = AgentLoop.Status(armed: held, indicator: held ? .active : .idle, hold: hold, armedSeconds: held ? 0 : nil)
    let content = PanelPresenter.present(status: status, preferences: preferences, agents: agents, lastSession: nil, catalog: catalog)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["--print", "-AppleLanguages", "(\(language))"]
    var environment = ProcessInfo.processInfo.environment
    environment["HALFLID_RESOURCES"] = resources.path
    // The panel reads the language chosen in the settings; a file that does not exist keeps the machine's own choice out.
    environment["HALFLID_PREFERENCES"] = NSTemporaryDirectory() + "halflid-no-such-preferences-\(UUID().uuidString).json"
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    try? input.fileHandleForWriting.write(contentsOf: PanelWire.line(content))
    try? input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    return (lines, process.terminationStatus)
}

private func runPanelAppTests() {
    guard let idle = printPanel() else {
        expect(false, "build/bin/HalfLidPanel exists and runs (scripts/test.sh builds it)")
        return
    }
    expect(idle.status == 0, "the panel prints and exits cleanly")
    expect(idle.lines.first == "Half Lid", "the panel starts with the name of the app")
    expect(idle.lines.prefix(3).elementsEqual(["Half Lid", "button: Settings…", "Ready"]), "the app name, then the settings button, then the status")
    expect(idle.lines.contains("Nothing is running"), "the panel gives the reason next to the status")
    expect(idle.lines.contains("Keep awake for") && idle.lines.contains("[30 min | 1 h | 2 h | 4 h | Until I stop it]"), "the panel offers the durations")
    expect(!idle.lines.contains("button: Stop keeping awake"), "no stop button while nothing is held")
    expect(idle.lines.contains("Agents") && idle.lines.contains("Cursor") && idle.lines.contains("Claude Code"), "the panel lists the agents")
    expect(idle.lines.contains("(off) Watch Cursor") && idle.lines.contains("(off) Watch Claude Code"), "every agent has a switch, off when not watched")
    expect(idle.lines.contains("Off"), "an agent that is not watched says so")
    expect(idle.lines.contains("button: Quit Half Lid"), "the footer has quit")
    expect(!idle.lines.contains(where: { $0.hasPrefix("panel.") || $0.hasPrefix("menu.") || $0.hasPrefix("agent.") || $0.hasPrefix("status.") }), "no catalog key leaks into the panel")

    if let watching = printPanel(watching: ["claude-code"]) {
        expect(watching.lines.contains("(on) Watch Claude Code") && watching.lines.contains("(off) Watch Codex"), "the switches follow the preferences")
    } else {
        expect(false, "the panel with a watched agent can be printed")
    }

    if let held = printPanel(hold: .untilStopped) {
        expect(held.lines.contains("Keeping the Mac awake") && held.lines.contains("Held until you stop it"), "holding: the status says so")
        expect(held.lines.contains("button: Stop keeping awake") && !held.lines.contains("Keep awake for"), "holding: the stop button replaces the durations")
    } else {
        expect(false, "the panel while holding can be printed")
    }

    if let italian = printPanel(language: "it") {
        expect(italian.lines.first == "Half Lid" && italian.lines.contains("Pronto") && italian.lines.contains("Tieni sveglio per") && italian.lines.contains("(off) Osserva Cursor"), "italian panel")
    } else {
        expect(false, "the italian panel can be printed")
    }
}
