import AppKit
import HalfLidCore

/// Reference box so the sampler's closure always sees the current preferences.
final class PreferencesBox {
    var value: Preferences
    init(_ value: Preferences) { self.value = value }
}

/// Reference box for the interface language, which can change while the app runs.
final class CatalogBox {
    var value: Catalog
    init(_ value: Catalog) { self.value = value }
}

/// Does nothing. Used with the file stand-in for the lid override (tests, `--print-menu`) so a test never locks the screen.
private final class NoScreen: ScreenControl {
    func lockScreen() {}
    func displayOff() {}
    func restoreScreen() {}
    func sleepIfStillAwake(afterSeconds: Int) {}
    func cancelPendingSleep() {}
}

/// Owns the agent loop, the preferences and the last session. Main thread only.
final class AgentService {
    static let fakeOverride = ProcessInfo.processInfo.environment["HALFLID_FAKE_OVERRIDE"] != nil

    let agentCatalog: AgentCatalog
    let notifier: Notifier
    private(set) var status: AgentLoop.Status?
    private(set) var lastSession: SessionSummary?
    /// Called after every tick, on the main thread.
    var onChange: (() -> Void)?

    var catalog: Catalog { catalogBox.value }

    private let resources: URL
    private let box: PreferencesBox
    private let catalogBox: CatalogBox
    private let sampler: AgentSignalSampler
    private let loop: AgentLoop
    private var tracker = SessionTracker()
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var lidWatcher: RootDomainWatcher?
    private var lidWasClosed: Bool?
    private var wakeObserver: NSObjectProtocol?
    private var displayObservers: [NSObjectProtocol] = []
    private var preferencesObservation: PreferencesBus.Observation?
    private var controlObserver: NSObjectProtocol?
    private var holdWarned: Date?
    private var published: PublishedStatus?
    /// What the system said about the login item and the notification permission the last time the settings window asked.
    private var openAtLogin: LoginItemState?
    private var openAtLoginError: String?
    private var notificationAccess: NotificationAccessState?

    /// `nil` when the resources or the guard executable cannot be found.
    init?() {
        guard let resources = ResourceLocator.resourcesDirectory(),
              let agents = try? AgentCatalog.load(from: resources.appendingPathComponent("agents.json")),
              let executable = Bundle.main.executableURL else { return nil }
        // The guard is the CLI executable next to this one (inside the app bundle, or in build/bin during development).
        let guardExecutable = executable.deletingLastPathComponent().appendingPathComponent("halflid")

        self.resources = resources
        agentCatalog = agents
        let preferences = Preferences.load()
        let box = PreferencesBox(preferences)
        self.box = box
        let catalogBox = CatalogBox(Catalog.load(directory: resources.appendingPathComponent("i18n"), language: preferences.language))
        self.catalogBox = catalogBox
        let notifier = Notifier(active: !Self.fakeOverride, preferences: { box.value.notifications }, catalog: { catalogBox.value })
        self.notifier = notifier

        // Session folders are walked only for watched command-line agents that are running (see AgentSignalSampler).
        let sampler = AgentSignalSampler(
            catalog: agents,
            scansSessions: { agent, processes in processes > 0 && box.value.watchesCommandLineAgent(agent.id) }
        )
        self.sampler = sampler
        let reader = CursorStateReader()
        let detector = WorkDetector(signals: { sampler.sample() }, cursor: { try reader.read() })
        let screen: ScreenControl = Self.fakeOverride ? NoScreen() : SystemScreenControl()
        let heartbeat = NSTemporaryDirectory() + "halflid-\(getpid()).beat"
        // The override flag is shared with macOS's power daemon, which clears it when a monitor comes or goes and on every wake: the
        // keeper puts it back several times a second while armed (see OverrideKeeper).
        let override = LidOverrideFactory.make()
        loop = AgentLoop(
            preferences: preferences, detector: detector, system: { SystemProbe.snapshot() },
            executor: ActionExecutor(override: override, screen: screen, notices: notifier, keeper: OverrideKeeper(override: override)),
            guardHandle: GuardProcess(executable: guardExecutable, heartbeatPath: heartbeat), heartbeatPath: heartbeat
        )
    }

    var preferences: Preferences { box.value }
    var hold: Hold { loop.hold }

    func start() {
        if !Self.fakeOverride { ScreenRepair.restore() } // repair a dark screen left by an earlier crash
        // The first process sample has no CPU baseline; take it before the first decision so a busy agent is seen at once.
        _ = sampler.sample()
        lastSession = SessionStore.load()
        lidWasClosed = PowerRegistry.lidClosed()
        // Every one of these can make macOS's power daemon rewrite the lid flag, so each also asks the keeper to re-apply it now.
        lidWatcher = RootDomainWatcher(queue: .main) { [weak self] _ in
            self?.loop.overrideMayHaveChanged()
            self?.lidMaybeChanged()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.loop.overrideMayHaveChanged()
            self?.tick()
        }
        let kick: (Notification) -> Void = { [weak self] _ in self?.loop.overrideMayHaveChanged() }
        displayObservers = [
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main, using: kick),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: kick),
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: kick),
        ]
        // The settings window and the command-line tool change the preferences file and ask this process to look again.
        preferencesObservation = PreferencesBus.observe { [weak self] in self?.preferencesFileChanged() }
        controlObserver = ControlChannel.observe { [weak self] command in self?.handle(command) }
        tick()
    }

    func tick(notify: Bool = true) {
        let current = loop.tick()
        status = current
        if let summary = tracker.observe(current) {
            SessionStore.save(summary)
            lastSession = summary
            if summary.ending == .finished { notifier.post(.workFinished(durationSeconds: summary.durationSeconds)) }
        }
        warnBeforeHoldEnds()
        publish(current)
        schedule(armed: current.armed)
        if notify { onChange?() }
    }

    func setHold(_ hold: Hold) {
        loop.hold = hold
        tick()
    }

    /// Turns the watching of one agent on or off (Cursor has its own switch; command-line agents share one list).
    func setWatching(_ agentId: String, _ on: Bool) {
        var changed = preferences
        changed.setWatching(agentId, on, agents: agentCatalog)
        update(preferences: changed)
    }

    /// Saves and applies new preferences, and tells the other processes (the settings window) to reload them.
    func update(preferences: Preferences) {
        apply(preferences, persist: true)
    }

    /// Leaves the Mac in its normal state. Call before quitting.
    func shutdown() {
        timer?.invalidate()
        timer = nil
        if let summary = tracker.finish(at: Date()) { SessionStore.save(summary) }
        loop.shutdown()
        if publishesStatus { StatusFile.remove() }
    }

    // MARK: private

    private func apply(_ preferences: Preferences, persist: Bool) {
        var clean = preferences
        clean.limits = clean.limits.sanitized()
        let languageChanged = clean.language != box.value.language
        box.value = clean
        if persist {
            try? clean.save()
            PreferencesBus.post()
        }
        if languageChanged {
            catalogBox.value = Catalog.load(directory: resources.appendingPathComponent("i18n"), language: clean.language)
        }
        loop.update(preferences: clean)
        tick()
    }

    /// Another process changed the file. Nothing happens when it is what this process already has, so the signal that this
    /// process itself sends after saving does not come back as a second round of work.
    private func preferencesFileChanged() {
        let fresh = Preferences.load()
        guard fresh != box.value else { return }
        apply(fresh, persist: false)
    }

    private func handle(_ command: ControlCommand) {
        // The user can switch the command line off; the settings window is not the command line.
        guard !command.isFromCommandLine || preferences.commandLineControl else { return }
        switch command {
        case .start(let minutes):
            setHold(minutes.map { .until(Date().addingTimeInterval(Double($0) * 60)) } ?? .untilStopped)
        case .stop:
            setHold(.none)
        case .setOpenAtLogin(let enabled):
            setOpenAtLogin(enabled)
        case .requestNotificationAccess:
            notifier.requestAccess { [weak self] state in self?.notificationAccessChanged(state) }
        case .sendTestNotification:
            notifier.requestAccess { [weak self] state in
                self?.notificationAccessChanged(state)
                if state == .allowed { self?.notifier.postTest() }
            }
        case .refreshSystemAccess:
            refreshSystemAccess()
        }
    }

    // MARK: the settings window

    /// Opens the settings window. The login item and the notification permission are read first, so the window shows them
    /// from its first moment.
    func openSettings() {
        refreshSystemAccess()
        SettingsLauncher.open()
    }

    /// The login item and the notification permission belong to this app, not to the settings window, so they are read and
    /// changed here and published for the window to show. They are not looked up unless the window asks.
    private func refreshSystemAccess() {
        openAtLogin = LoginItem.state
        publishAgain()
        notifier.accessState { [weak self] state in self?.notificationAccessChanged(state) }
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        openAtLoginError = nil
        do {
            try LoginItem.set(enabled)
        } catch {
            openAtLoginError = error.localizedDescription
        }
        openAtLogin = LoginItem.state
        publishAgain()
    }

    private func notificationAccessChanged(_ state: NotificationAccessState) {
        notificationAccess = state
        publishAgain()
    }

    private func publishAgain() {
        if let status { publish(status) }
    }

    /// One notification, a few minutes before a timed hold ends (once per hold).
    private func warnBeforeHoldEnds() {
        guard case .until(let end) = loop.hold else {
            holdWarned = nil
            return
        }
        let remaining = end.timeIntervalSinceNow
        guard remaining > 0, remaining <= NotificationPresenter.holdWarningSeconds, holdWarned != end else { return }
        holdWarned = end
        notifier.post(.holdEnding)
    }

    /// Writes what `halflid status` and the settings window show. Only when something changed, so it costs no disk traffic
    /// while nothing happens.
    private func publish(_ status: AgentLoop.Status) {
        guard publishesStatus else { return }
        let presentation = StatusPresenter.present(status, catalog: catalog)
        var holdUntil: Date?
        var holdUntilStopped = false
        switch status.hold {
        case .none: break
        case .untilStopped: holdUntilStopped = true
        case .until(let end): holdUntil = end
        }
        var working: [String] = []
        if (status.report.cursor?.working ?? 0) > 0 { working.append("cursor") }
        working.append(contentsOf: status.report.workingAgents.sorted())
        let next = PublishedStatus(
            pid: getpid(), armed: status.armed, indicator: status.indicator.rawValue, title: presentation.title,
            detail: presentation.detail, holdText: StatusPresenter.holdLine(status.hold, catalog: catalog), holdUntil: holdUntil,
            holdUntilStopped: holdUntilStopped, latch: status.latch?.rawValue, workingAgents: working,
            openAtLogin: openAtLogin, openAtLoginError: openAtLoginError, notificationAccess: notificationAccess
        )
        guard next != published else { return }
        published = next
        StatusFile.write(next)
    }

    /// Tests run with a fake override and must not touch the real status file unless they name one.
    private var publishesStatus: Bool {
        !Self.fakeOverride || ProcessInfo.processInfo.environment["HALFLID_STATUS"] != nil
    }

    private func lidMaybeChanged() {
        let now = PowerRegistry.lidClosed()
        guard now != lidWasClosed else { return }
        lidWasClosed = now
        tick()
    }

    /// Polling is the only recurring cost: faster while the Mac is being held, relaxed otherwise.
    private func schedule(armed: Bool) {
        let interval: TimeInterval = armed ? 5 : 10
        guard interval != timerInterval || timer == nil else { return }
        timer?.invalidate()
        timerInterval = interval
        let next = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        next.tolerance = interval * 0.2
        RunLoop.main.add(next, forMode: .common)
        timer = next
    }
}
