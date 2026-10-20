import AppKit
import HalfLidCore
import Observation
import SwiftUI

/// One language the interface can be switched to.
struct LanguageOption: Identifiable, Hashable {
    var code: String
    /// The language's name in that language, so it can be recognised whatever the current interface language is.
    var name: String
    var id: String { code }
}

/// Everything the settings window shows and changes. The preferences file is the single source of truth: every change is
/// saved at once and announced to the menu bar app, and a change made by another process (the menu, the command line) is
/// picked up the same way, so nothing here needs an "Apply" step.
@MainActor
@Observable
final class SettingsModel {
    var section: SettingsSection

    private(set) var preferences: Preferences
    private(set) var catalog: Catalog
    private(set) var published: PublishedStatus?
    /// What the user just chose for the login item, until the menu bar app has answered: the switch does not jump back and
    /// forth in the meantime.
    private(set) var pendingLogin: Bool?
    private(set) var sleepHolders: [SleepHolder] = []
    private(set) var repairMessage: String?
    private(set) var reportCopied = false

    let agents: AgentCatalog
    let resources: URL?
    let languages: [LanguageOption]

    @ObservationIgnored private var observation: PreferencesBus.Observation?
    @ObservationIgnored private var activation: NSObjectProtocol?
    @ObservationIgnored private var poller: Task<Void, Never>?

    init(section: SettingsSection = .general) {
        self.section = section
        let resources = ResourceLocator.resourcesDirectory()
        self.resources = resources
        let preferences = Preferences.load()
        self.preferences = preferences
        agents = resources.flatMap { try? AgentCatalog.load(from: $0.appendingPathComponent("agents.json")) } ?? AgentCatalog(agents: [])
        let i18n = resources?.appendingPathComponent("i18n")
        catalog = i18n.map { Catalog.load(directory: $0, language: preferences.language) }
            ?? Catalog(language: Catalog.fallbackLanguage, messages: [:], fallback: [:])
        languages = (i18n.map { Catalog.availableLanguages(in: $0) } ?? []).map { code in
            let locale = Locale(identifier: code)
            let name = locale.localizedString(forIdentifier: code) ?? code
            return LanguageOption(code: code, name: name.prefix(1).uppercased(with: locale) + name.dropFirst())
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        published = StatusFile.read()
    }

    // MARK: text

    func text(_ key: String, _ params: [String: String] = [:]) -> String {
        catalog.text(key, params)
    }

    /// `HALFLID_VERSION` stands in for the version of an installed app when the window runs from a build that is not installed:
    /// the pictures of the README (`scripts/screenshots.sh`).
    private static let versionStandIn = ProcessInfo.processInfo.environment["HALFLID_VERSION"]

    var version: String {
        Self.versionStandIn ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "development"
    }

    var build: String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// "Version 0.1.0", or "Development build" when not run from an installed app.
    var versionLabel: String {
        guard Self.versionStandIn != nil || Bundle.main.infoDictionary?["CFBundleShortVersionString"] != nil else {
            return text("settings.version.development")
        }
        guard let build, build != version else { return text("settings.sidebar.version", ["version": version]) }
        return text("settings.about.version", ["version": version, "build": build])
    }

    // MARK: preferences

    /// Starts following changes made by other processes. Call once, when the window appears.
    func startObserving() {
        guard observation == nil else { return }
        observation = PreferencesBus.observe { [weak self] in
            MainActor.assumeIsolated { self?.reloadPreferences() }
        }
        // Coming back from System Settings, where the login item or the notification permission may have been changed.
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSystemAccess() }
        }
        refreshLive()
        refreshSystemAccess()
        // The menu bar app answers through the status file, so the file is read again every moment while the window is open.
        poller = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.refreshStatus()
            }
        }
    }

    func binding<Value>(_ keyPath: WritableKeyPath<Preferences, Value>) -> Binding<Value> {
        Binding(get: { self.preferences[keyPath: keyPath] }, set: { self.set(keyPath, $0) })
    }

    func set<Value>(_ keyPath: WritableKeyPath<Preferences, Value>, _ value: Value) {
        var next = preferences
        next[keyPath: keyPath] = value
        apply(next)
    }

    func isWatching(_ agentId: String) -> Bool {
        preferences.watches(agentId)
    }

    func setWatching(_ agentId: String, _ on: Bool) {
        var next = preferences
        next.setWatching(agentId, on, agents: agents)
        apply(next)
    }

    /// Every setting back to its default, except that the welcome note is not shown again.
    func resetAll() {
        var fresh = Preferences()
        fresh.welcomeSeen = preferences.welcomeSeen
        apply(fresh)
    }

    func resetLimits() {
        set(\.limits, Limits())
    }

    private func apply(_ next: Preferences) {
        var clean = next
        clean.limits = clean.limits.sanitized()
        guard clean != preferences else { return }
        let languageChanged = clean.language != preferences.language
        preferences = clean
        if languageChanged { reloadCatalog() }
        try? clean.save()
        PreferencesBus.post()
    }

    private func reloadPreferences() {
        let fresh = Preferences.load()
        guard fresh != preferences else { return }
        let languageChanged = fresh.language != preferences.language
        preferences = fresh
        if languageChanged { reloadCatalog() }
    }

    private func reloadCatalog() {
        guard let directory = resources?.appendingPathComponent("i18n") else { return }
        catalog = Catalog.load(directory: directory, language: preferences.language)
    }

    // MARK: live state

    /// Reads what the menu bar app published. A few hundred bytes: cheap enough to repeat every second.
    func refreshStatus() {
        let fresh = StatusFile.read()
        if fresh != published { published = fresh }
    }

    /// Also reads what is holding the Mac awake, for the diagnostics pane.
    func refreshLive() {
        refreshStatus()
        let holders = SleepHolder.current()
        if holders != sleepHolders { sleepHolders = holders }
    }

    /// The menu bar app is running (it publishes while it does).
    var menuBarAppRunning: Bool { published != nil }

    // MARK: login item and notifications
    //
    // Both belong to the menu bar app, which the system knows, and not to this window, which is an app of its own. This window
    // asks it to change them and shows what it publishes.

    /// Asks the menu bar app to read the login item and the notification permission again.
    func refreshSystemAccess() {
        ControlChannel.send(.refreshSystemAccess)
    }

    /// `nil` until the menu bar app has answered.
    var login: LoginItemState? { published?.openAtLogin }

    /// The switch as the user should see it.
    var loginSwitchIsOn: Bool { pendingLogin ?? login?.isOn ?? false }

    /// The menu bar app is running and the system lets it register itself.
    var canChangeLogin: Bool { login.map { $0 != .unavailable } ?? false }

    /// The system's own words for why the login item could not be changed.
    var loginMessage: String? {
        guard let reason = published?.openAtLoginError else { return nil }
        return text("settings.general.login.error", ["reason": reason])
    }

    func setOpenAtLogin(_ on: Bool) {
        pendingLogin = on
        ControlChannel.send(.setOpenAtLogin(on))
        Task {
            // Wait a moment for the answer, so the switch lands where the system put it.
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(100))
                refreshStatus()
                if published?.openAtLogin?.isOn == on || published?.openAtLogin == .unavailable || published?.openAtLoginError != nil { break }
            }
            pendingLogin = nil
        }
    }

    func openLoginItemsSettings() {
        SystemLinks.openLoginItemsSettings()
    }

    /// `nil` until the menu bar app has answered.
    var notificationAccess: NotificationAccessState? { published?.notificationAccess }

    /// The menu bar app is running and can use the notification center.
    var canChangeNotifications: Bool { notificationAccess.map { $0 != .unavailable } ?? false }

    /// Turning notifications on is also the moment macOS is asked for permission.
    func setNotifications(enabled: Bool) {
        var next = preferences
        next.notifications.enabled = enabled && notificationAccess != .unavailable
        apply(next)
        if enabled, notificationAccess == .notDetermined { ControlChannel.send(.requestNotificationAccess) }
    }

    func sendTestNotification() {
        ControlChannel.send(.sendTestNotification)
    }

    // MARK: diagnostics

    /// Puts the lid behaviour and the display brightness back to normal.
    func repair() {
        let lidOK = (try? IOKitLidOverride().setLidCloseIgnored(false)) != nil
        let hadSavedBrightness = ScreenRepair.load() != nil
        let brightnessOK = !hadSavedBrightness || ScreenRepair.restore()
        repairMessage = text(lidOK && brightnessOK ? "settings.diagnostics.repair.done" : "settings.diagnostics.repair.failed")
    }

    func copyReport() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(report(), forType: .string)
        reportCopied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            reportCopied = false
        }
    }

    /// A plain-text summary for bug reports. English on purpose, and free of anything personal: no paths, no chat text.
    func report() -> String {
        var lines = ["Half Lid \(version)" + (build.map { " (\($0))" } ?? "")]
        lines.append("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        if let published {
            lines.append("Menu bar app: running (pid \(published.pid))")
            lines.append("State: \(published.indicator), keeping awake: \(published.armed), stopped by: \(published.latch ?? "nothing")")
            lines.append("Working now: \(published.workingAgents.isEmpty ? "none" : published.workingAgents.joined(separator: ", "))")
        } else {
            lines.append("Menu bar app: not running")
        }
        let watched = agents.agents.map(\.id).filter { preferences.watches($0) }
        lines.append("Watching: \(watched.isEmpty ? "none" : watched.joined(separator: ", "))")
        lines.append("Lid closed: lock \(preferences.lockOnClose), display off \(preferences.displayOffOnClose)")
        let limits = preferences.limits
        lines.append("Limits: battery warn \(limits.batteryWarnPercent) % stop \(limits.batteryStopPercent) %, "
            + "max \(limits.maxHoursOnBattery) h battery / \(limits.maxHoursOnAC) h power, thermal \(limits.thermalStopAt.rawValue), "
            + "battery temperature \(limits.batteryTempWarnC)/\(limits.batteryTempStopC) C, grace \(Int(limits.idleGraceSeconds)) s")
        lines.append("Notifications: \(preferences.notifications.enabled), access \(notificationAccess?.rawValue ?? "not reported")")
        lines.append("Open at login: \(login?.rawValue ?? "not reported")")
        lines.append("Language: \(preferences.language ?? "system") (showing \(catalog.language))")
        lines.append("Command-line control: \(preferences.commandLineControl)")
        lines.append("Sleep holders: " + (sleepHolders.isEmpty ? "none" : sleepHolders.map(\.process).joined(separator: ", ")))
        lines.append("Screen functions: lock \(canLockScreen ? "available" : "missing"), brightness \(canSetBrightness ? "available" : "missing")")
        return lines.joined(separator: "\n")
    }

    /// Whether the macOS functions behind the lid-closed screen steps exist on this Mac (they are not documented by Apple).
    var canLockScreen: Bool { SystemScreenControl.canLockScreen }
    var canSetBrightness: Bool { DisplayBrightness.isAvailable }

    /// Path of the `halflid` command-line tool inside the app, for pasting into a terminal or a PATH link.
    var commandLinePath: String? {
        ResourceLocator.commandLineTool()?.path
    }

    func copyCommandLinePath() {
        guard let path = commandLinePath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}
