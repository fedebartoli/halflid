import AppKit
import HalfLidCore

/// Opens the quick-actions panel under the menu bar icon by starting `HalfLidPanel`, a separate executable that exists only
/// while the panel is open. This process keeps no interface code or memory for it: it sends the content to show, carries out
/// the requests that come back, and notices when the panel is gone.
final class PanelHost {
    private let service: AgentService
    private var session: PanelSession?
    private var generation = 0
    private var refreshTimer: Timer?
    private var lastClosed = Date.distantPast
    /// The first-run welcome has not been seen yet. It is shown with the panel's first opening and then never again.
    private var welcomePending: Bool
    private var welcomeShown = false

    init(service: AgentService) {
        self.service = service
        welcomePending = !service.preferences.welcomeSeen
    }

    var isShown: Bool { session?.isRunning ?? false }

    func toggle(from button: NSStatusBarButton) {
        if isShown {
            close()
            return
        }
        show(from: button)
    }

    /// Opens the panel unless it is already open.
    func show(from button: NSStatusBarButton) {
        guard !isShown else { return }
        // The click that dismissed the panel (a click outside it, on this very icon) must not open it again at once.
        guard Date().timeIntervalSince(lastClosed) > 0.3 else { return }
        guard let executable = Self.panelExecutable() else {
            NSSound.beep()
            return
        }
        service.tick(notify: false) // fresh readings for the moment the user looks
        guard let content = Self.content(for: service, welcome: welcomePending) else { return }
        welcomeShown = welcomePending

        generation += 1
        let id = generation
        let started = PanelSession(
            executable: executable, arguments: ["--anchor", Self.anchorArgument(for: button)],
            onRequest: { [weak self] request in self?.handle(request) },
            onExit: { [weak self] in
                guard let self, self.generation == id else { return }
                self.panelExited()
            }
        )
        do { try started.start() } catch {
            NSSound.beep()
            return
        }
        session = started
        started.send(content)

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.service.tick(notify: false)
            self?.refresh()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func close() {
        session?.close()
    }

    /// Sends the latest state to the panel if it is open. Identical content is not sent again.
    func refresh() {
        guard isShown, let content = Self.content(for: service, welcome: welcomePending) else { return }
        session?.send(content)
    }

    // MARK: private

    private func panelExited() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        session = nil
        lastClosed = Date()
        if welcomeShown { markWelcomeSeen() }
    }

    /// The welcome is shown once: opening the panel is enough, whether or not the button was pressed.
    private func markWelcomeSeen() {
        welcomeShown = false
        welcomePending = false
        var preferences = service.preferences
        guard !preferences.welcomeSeen else { return }
        preferences.welcomeSeen = true
        service.update(preferences: preferences)
    }

    private func handle(_ request: PanelRequest) {
        switch request {
        case .hold(let minutes):
            service.setHold(minutes == 0 ? .untilStopped : .until(Date().addingTimeInterval(Double(minutes) * 60)))
        case .stopHold:
            service.setHold(.none)
        case .setWatching(let agentId, let on):
            service.setWatching(agentId, on)
        case .openSettings:
            service.openSettings()
        case .dismissHint:
            welcomePending = false
            refresh()
        case .quit:
            NSApplication.shared.terminate(nil)
        }
    }

    private static func content(for service: AgentService, welcome: Bool) -> PanelContent? {
        guard let status = service.status else { return nil }
        return PanelPresenter.present(
            status: status, preferences: service.preferences, agents: service.agentCatalog, lastSession: service.lastSession,
            catalog: service.catalog, welcome: welcome
        )
    }

    /// The panel executable sits next to this one (inside the app bundle, or in build/bin during development).
    private static func panelExecutable() -> URL? {
        guard let folder = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let executable = folder.appendingPathComponent("HalfLidPanel")
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    /// The icon's frame in screen coordinates, as "x,y,width,height".
    private static func anchorArgument(for button: NSStatusBarButton) -> String {
        guard let window = button.window else { return "0,0,0,0" }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return [frame.minX, frame.minY, frame.width, frame.height].map { String(format: "%.1f", $0) }.joined(separator: ",")
    }
}

/// Opens the settings window. It is a separate program (`Half Lid Settings.app`, inside this app's bundle) that runs only
/// while the window is open, so the settings interface uses no memory while it is closed.
enum SettingsLauncher {
    /// The settings program, inside the app bundle.
    static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Half Lid Settings.app")
    }

    /// Starts the settings window, or brings the open one to the front. Use `AgentService.openSettings`, which also gets the
    /// window what it needs from this app.
    ///
    /// The window is a regular application started through LaunchServices, as any app the user opens is, which is what lets it
    /// come to the front. A program started directly by this background process is not allowed to take the front from the app
    /// the user is working in, and its window would open behind it.
    static func open() {
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            startDirectly() // development run from build/bin: there is no app bundle to launch
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: helperURL, configuration: configuration) { _, error in
            if error != nil { DispatchQueue.main.async { startDirectly() } }
        }
    }

    private static func startDirectly() {
        guard let folder = Bundle.main.executableURL?.deletingLastPathComponent() else { return }
        let executable = folder.appendingPathComponent("HalfLidSettings")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            NSSound.beep()
            return
        }
        let process = Process()
        process.executableURL = executable
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
