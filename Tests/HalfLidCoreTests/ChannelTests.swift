import Foundation
import HalfLidCore

/// Preferences added with the settings window, the signals between Half Lid's processes, the command-line control and the
/// notification text. None of this touches the real preferences file or the real status file.
func runChannelTests() {
    let directory = NSTemporaryDirectory() + "halflid-channel-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }

    checkPreferences(directory: directory)
    checkControlCommands()
    checkSettingsCommands()
    checkStatusFile(directory: directory)
    checkSystemAccess()
    checkBundleLayout(directory: directory)
    checkPreferencesBus()
    checkNotifications()
    checkWelcome()
}

// MARK: preferences

private func checkPreferences(directory: String) {
    let defaults = Preferences()
    expect(defaults.notifications.enabled == false, "notifications are off until the user turns them on")
    expect(defaults.notifications.onStop && defaults.notifications.onWarning && defaults.notifications.onHoldEnding, "the important notices are on once notifications are enabled")
    expect(defaults.notifications.onWorkFinished == false, "'work finished' is opt-in")
    expect(defaults.language == nil && defaults.welcomeSeen == false && defaults.commandLineControl, "new settings start at their defaults")

    // A file from before these settings existed keeps working, and keeps what it said.
    let path = directory + "/old.json"
    try? #"{"lockOnClose": false, "limits": {"batteryStopPercent": 25}}"#.write(toFile: path, atomically: true, encoding: .utf8)
    let old = Preferences.load(path: path)
    expect(old.lockOnClose == false && old.limits.batteryStopPercent == 25, "an older file keeps its values")
    expect(old.notifications == NotificationPreferences() && old.language == nil && old.commandLineControl, "an older file gets defaults for the new settings")

    // Partial notification settings merge with the defaults instead of resetting the group.
    try? #"{"notifications": {"enabled": true}}"#.write(toFile: path, atomically: true, encoding: .utf8)
    let partial = Preferences.load(path: path).notifications
    expect(partial.enabled && partial.onStop && !partial.onWorkFinished, "a partial notifications group keeps the other defaults")

    var changed = Preferences()
    changed.notifications.enabled = true
    changed.notifications.onWorkFinished = true
    changed.language = "de"
    changed.welcomeSeen = true
    changed.commandLineControl = false
    try? changed.save(path: path)
    expect(Preferences.load(path: path) == changed, "the new settings survive a save and load")

    // Which agents are watched: Cursor has its own switch, the others share one list.
    let agents = AgentCatalog(agents: ["cursor", "claude-code", "codex", "goose"].map { AgentDefinition(id: $0) })
    var watch = Preferences()
    expect(watch.watches("cursor") && watch.watches("codex"), "everything is watched by default")
    watch.setWatching("codex", false, agents: agents)
    expect(watch.cliAgents == ["claude-code", "goose"], "turning one off writes out the rest of the list")
    expect(!watch.watches("codex") && watch.watches("claude-code") && watch.watches("cursor"), "only the chosen agent stops being watched")
    watch.setWatching("codex", true, agents: agents)
    expect(watch.cliAgents == ["claude-code", "codex", "goose"], "turning it back on adds it back, sorted")
    watch.setWatching("cursor", false, agents: agents)
    expect(!watch.watches("cursor") && !watch.cursorEnabled && watch.cliAgents == ["claude-code", "codex", "goose"], "Cursor has its own switch and leaves the list alone")
    expect(!watch.watchesCommandLineAgent("cursor"), "Cursor is never a command-line agent")
}

// MARK: command-line control

private func checkControlCommands() {
    let commands: [ControlCommand] = [.stop, .start(minutes: nil), .start(minutes: 1), .start(minutes: 90), .start(minutes: 10_080)]
    for command in commands {
        expect(ControlCommand(userInfo: command.userInfo) == command, "a command survives its notification payload: \(command)")
        expect(PropertyListSerialization.propertyList(command.userInfo, isValidFor: .binary), "the payload is a property list: \(command)")
    }
    expect(ControlCommand(userInfo: nil) == nil, "no payload is not a command")
    expect(ControlCommand(userInfo: [:]) == nil, "an empty payload is not a command")
    expect(ControlCommand(userInfo: ["verb": "reboot"]) == nil, "an unknown verb is ignored")
    expect(ControlCommand(userInfo: ["verb": 7]) == nil, "a verb of the wrong type is ignored")
    expect(ControlCommand(userInfo: ["verb": "start", "minutes": 0]) == nil, "zero minutes is refused")
    expect(ControlCommand(userInfo: ["verb": "start", "minutes": -5]) == nil, "negative minutes are refused")
    expect(ControlCommand(userInfo: ["verb": "start", "minutes": 10_081]) == nil, "more than a week is refused")
    expect(ControlCommand(userInfo: ["verb": "start", "minutes": "soon"]) == nil, "minutes of the wrong type are refused")
    expect(ControlCommand(userInfo: ["verb": "start", "minutes": 45]) == .start(minutes: 45), "a timed start is accepted")
}

/// What the settings window asks of the menu bar app (the login item and the notification permission belong to the latter).
private func checkSettingsCommands() {
    let commands: [ControlCommand] = [.setOpenAtLogin(true), .setOpenAtLogin(false), .requestNotificationAccess, .sendTestNotification, .refreshSystemAccess]
    for command in commands {
        expect(ControlCommand(userInfo: command.userInfo) == command, "a settings command survives its notification payload: \(command)")
        expect(PropertyListSerialization.propertyList(command.userInfo, isValidFor: .binary), "the payload is a property list: \(command)")
        expect(!command.isFromCommandLine, "the switch for the command line does not apply to the settings window: \(command)")
    }
    expect(ControlCommand.start(minutes: 5).isFromCommandLine && ControlCommand.stop.isFromCommandLine, "start and stop are the command line")
    expect(ControlCommand(userInfo: ["verb": "openAtLogin"]) == nil, "the login item needs to be told which way")
    expect(ControlCommand(userInfo: ["verb": "openAtLogin", "enabled": "yes"]) == nil, "the login item switch must be a boolean")
    expect(ControlCommand(userInfo: ["verb": "openAtLogin", "enabled": true]) == .setOpenAtLogin(true), "a well-formed login item request is accepted")

    // A run against sample files must not reach the real menu bar app through the Mac-wide notification center.
    expect(!ControlChannel.isMuted(environment: [:]), "requests are sent normally")
    expect(ControlChannel.isMuted(environment: ["HALFLID_NO_CONTROL": "1"]), "a run against sample files sends nothing")
}

// MARK: status file

private func checkStatusFile(directory: String) {
    let path = directory + "/status.json"
    expect(StatusFile.read(path: path) == nil, "no file, no status")

    var status = PublishedStatus(pid: getpid(), armed: true, indicator: "active", title: "Keeping the Mac awake", workingAgents: ["Codex"])
    status.holdText = "Held until 15:42"
    status.holdUntil = Date(timeIntervalSince1970: 1_800_000_000)
    StatusFile.write(status, path: path)
    expect(StatusFile.read(path: path) == status, "the status survives a write and read")
    expect(StatusFile.read(path: path)?.openAtLogin == nil && StatusFile.read(path: path)?.notificationAccess == nil, "the system's answers are absent until asked for")

    // What the menu bar app reports to the settings window.
    var answered = status
    answered.openAtLogin = .requiresApproval
    answered.openAtLoginError = "Operation not permitted"
    answered.notificationAccess = .notDetermined
    StatusFile.write(answered, path: path)
    let reread = StatusFile.read(path: path)
    expect(reread == answered, "the login item and the notification permission survive a write and read")
    expect(reread?.openAtLogin?.isOn == true, "waiting for approval still counts as switched on")

    // A status written by a version that did not know these fields is still readable.
    let legacy = #"{"pid": \#(getpid()), "armed": false, "indicator": "idle", "title": "Ready", "holdUntilStopped": false, "workingAgents": []}"#
    try? legacy.write(toFile: path, atomically: true, encoding: .utf8)
    expect(StatusFile.read(path: path)?.title == "Ready", "a status without the newer fields is still read")
    StatusFile.write(status, path: path)

    // A crash leaves the file behind; the pid says nobody is there any more.
    var stale = status
    stale.pid = 2_000_000
    StatusFile.write(stale, path: path)
    expect(StatusFile.read(path: path) == nil, "a status from a process that is gone is ignored")

    try? "garbage".write(toFile: path, atomically: true, encoding: .utf8)
    expect(StatusFile.read(path: path) == nil, "a damaged file is ignored")

    StatusFile.write(status, path: path)
    StatusFile.remove(path: path)
    expect(!FileManager.default.fileExists(atPath: path), "the status file can be removed")
}

// MARK: identity

private func checkSystemAccess() {
    expect(LoginItemState.enabled.isOn && LoginItemState.requiresApproval.isOn, "enabled and waiting for approval are both 'on'")
    expect(!LoginItemState.disabled.isOn && !LoginItemState.unavailable.isOn, "disabled and unavailable are 'off'")
    for state in [LoginItemState.enabled, .requiresApproval, .disabled, .unavailable] {
        let data = try? JSONEncoder().encode([state])
        expect(data.flatMap { try? JSONDecoder().decode([LoginItemState].self, from: $0) } == [state], "\(state) is stable in the status file")
    }
    // The identity the system knows is the menu bar app's; the packaging script is where it is given.
    let script = (try? String(contentsOf: repositoryRoot.appendingPathComponent("scripts/make-app.sh"), encoding: .utf8)) ?? ""
    expect(script.contains("<key>CFBundleIdentifier</key><string>\(AppIdentity.menuBarBundleIdentifier)</string>"), "the menu bar app's bundle identifier is the one the code names")
    expect(script.contains("io.github.fedebartoli.halflid.settings"), "the settings app has an identity of its own")
}

// MARK: places inside the app

/// The settings window is an app nested in the main app and does not have the resources or the command-line tool next to it.
private func checkBundleLayout(directory: String) {
    let fileManager = FileManager.default
    func make(_ path: String, executable: Bool = false) -> URL {
        let url = URL(fileURLWithPath: directory + "/" + path)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fileManager.createFile(atPath: url.path, contents: Data("x".utf8), attributes: [.posixPermissions: executable ? 0o755 : 0o644])
        return url
    }
    func same(_ a: URL?, _ b: URL) -> Bool { a?.resolvingSymlinksInPath().path == b.resolvingSymlinksInPath().path }

    let app = "layout/Half Lid.app/Contents"
    _ = make("\(app)/Resources/i18n/en.json")
    let tool = make("\(app)/MacOS/halflid", executable: true)
    let resident = make("\(app)/MacOS/HalfLidApp", executable: true)
    let helper = make("\(app)/Helpers/Half Lid Settings.app/Contents/MacOS/HalfLidSettings", executable: true)
    let helperResources = URL(fileURLWithPath: directory + "/\(app)/Helpers/Half Lid Settings.app/Contents/Resources")
    try? fileManager.createDirectory(at: helperResources, withIntermediateDirectories: true)
    let outerResources = URL(fileURLWithPath: directory + "/\(app)/Resources")

    expect(same(ResourceLocator.resourcesDirectory(environment: [:], mainBundleResources: outerResources, executable: resident), outerResources), "the menu bar app finds its resources")
    expect(same(ResourceLocator.resourcesDirectory(environment: [:], mainBundleResources: helperResources, executable: helper), outerResources), "the settings app finds the main app's resources, not its own empty folder")
    expect(same(ResourceLocator.commandLineTool(executable: resident), tool), "the menu bar app finds the command-line tool next to it")
    expect(same(ResourceLocator.commandLineTool(executable: helper), tool), "the settings app finds the command-line tool in the main app")

    // A development run: everything next to each other in build/bin, resources in the repository.
    _ = make("dev/Resources/i18n/en.json")
    let devTool = make("dev/build/bin/halflid", executable: true)
    let devSettings = make("dev/build/bin/HalfLidSettings", executable: true)
    expect(same(ResourceLocator.resourcesDirectory(environment: [:], mainBundleResources: nil, executable: devSettings), URL(fileURLWithPath: directory + "/dev/Resources")), "a development build finds the repository's resources")
    expect(same(ResourceLocator.commandLineTool(executable: devSettings), devTool), "a development build finds the tool next to it")

    let lonely = make("lonely/HalfLidSettings", executable: true)
    expect(ResourceLocator.commandLineTool(executable: lonely) == nil, "no tool, no path")
    expect(ResourceLocator.commandLineTool(executable: nil) == nil, "no executable, no path")
}

// MARK: preferences signal

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    let semaphore = DispatchSemaphore(value: 0)
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func hit() { lock.lock(); value += 1; lock.unlock(); semaphore.signal() }
}

private func checkPreferencesBus() {
    let counter = Counter()
    let queue = DispatchQueue(label: "halflid.tests.bus")
    var observation = PreferencesBus.observe(on: queue) { counter.hit() }
    expect(observation != nil, "the preferences signal can be observed")
    PreferencesBus.post()
    expect(counter.semaphore.wait(timeout: .now() + 3) == .success, "a posted signal reaches an observer")
    expect(counter.count == 1, "one post is one delivery")

    observation = nil
    PreferencesBus.post()
    expect(counter.semaphore.wait(timeout: .now() + 0.5) == .timedOut, "a released observation hears nothing more")
    expect(counter.count == 1, "no delivery after release")
}

// MARK: notifications

private func checkNotifications() {
    var wanted = NotificationPreferences()
    let events: [NotificationEvent] = [.stopped(.thermal), .warning(.batteryLow), .holdEnding, .workFinished(durationSeconds: 3_600)]
    expect(events.allSatisfy { !NotificationPresenter.isWanted($0, by: wanted) }, "nothing is posted while notifications are off")

    wanted.enabled = true
    expect(NotificationPresenter.isWanted(.stopped(.batteryLow), by: wanted), "a stop is wanted by default")
    expect(NotificationPresenter.isWanted(.warning(.batteryTemperature), by: wanted), "a warning is wanted by default")
    expect(NotificationPresenter.isWanted(.holdEnding, by: wanted), "the end of a timed hold is wanted by default")
    expect(!NotificationPresenter.isWanted(.workFinished(durationSeconds: 60), by: wanted), "'work finished' is not wanted by default")

    wanted.onWorkFinished = true
    wanted.onStop = false
    expect(NotificationPresenter.isWanted(.workFinished(durationSeconds: 60), by: wanted), "'work finished' once asked for")
    expect(!NotificationPresenter.isWanted(.stopped(.maxDuration), by: wanted), "a switched-off kind is not posted")

    expect(NotificationEvent(.stopped(.thermal)) == .stopped(.thermal) && NotificationEvent(.warning(.batteryLow)) == .warning(.batteryLow), "controller notices become events")

    // A newer notice of one kind replaces the older one; different kinds do not.
    let ids = Set(StopReason.allCases.map { NotificationPresenter.identifier(for: .stopped($0)) })
    expect(ids.count == 1, "every stop shares one identifier")
    expect(NotificationPresenter.identifier(for: .warning(.batteryLow)) != NotificationPresenter.identifier(for: .warning(.batteryTemperature)), "warnings of different kinds do not replace each other")
    expect(Set(events.map(NotificationPresenter.identifier(for:))).count == events.count, "each kind of event has its own identifier")

    // Text exists, with no catalog key leaking through, in every language that is shipped.
    let directory = repositoryRoot.appendingPathComponent("Resources/i18n")
    for language in Catalog.availableLanguages(in: directory) {
        let catalog = Catalog.load(directory: directory, language: language)
        var all: [NotificationEvent] = StopReason.allCases.map { .stopped($0) }
        all += WarningKind.allCases.map { .warning($0) }
        all += [.holdEnding, .workFinished(durationSeconds: 5_400)]
        for event in all {
            let text = NotificationPresenter.text(for: event, catalog: catalog)
            expect(!text.title.isEmpty && !text.body.isEmpty, "\(language): \(event) has a title and a body")
            expect(!text.title.contains("notify.") && !text.body.contains("notify.") && !text.body.contains("status."), "\(language): \(event) shows no catalog key")
            expect(!text.body.contains("{"), "\(language): \(event) has no unfilled placeholder")
        }
    }
    let english = Catalog.load(directory: directory, language: "en")
    let finished = NotificationPresenter.text(for: .workFinished(durationSeconds: 5_400), catalog: english)
    expect(finished.body.contains("1") && finished.body.contains("30"), "the duration is in the 'work finished' text: \(finished.body)")
}

// MARK: welcome hint

private func checkWelcome() {
    let directory = repositoryRoot.appendingPathComponent("Resources/i18n")
    let agents = AgentCatalog(agents: [AgentDefinition(id: "cursor"), AgentDefinition(id: "codex")])
    let status = AgentLoop.Status(armed: false, indicator: .idle)
    for language in Catalog.availableLanguages(in: directory) {
        let catalog = Catalog.load(directory: directory, language: language)
        let first = PanelPresenter.present(status: status, preferences: Preferences(), agents: agents, lastSession: nil, catalog: catalog, welcome: true)
        let later = PanelPresenter.present(status: status, preferences: Preferences(), agents: agents, lastSession: nil, catalog: catalog)
        expect(first.hint != nil && later.hint == nil, "\(language): the welcome appears only when asked for")
        expect(!(first.hint?.text ?? "").isEmpty && !(first.hint?.dismissLabel ?? "").isEmpty, "\(language): the welcome has text and a dismiss label")
        expect(!(first.hint?.text ?? "").hasPrefix("panel."), "\(language): the welcome shows no catalog key")
    }
}
