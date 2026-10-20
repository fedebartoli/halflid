import AppKit
import HalfLidCore

/// Half Lid's menu bar agent: a status item and a native menu, no windows. Heavier screens run in a separate on-demand
/// process so this one stays small (see docs/DECISIONS.md, section 6).
@main
final class HalfLidApp: NSObject, NSApplicationDelegate {
    private var service: AgentService!
    private var menuController: MenuController!
    private var panel: PanelHost!
    private var statusItem: NSStatusItem!
    private var shownGlyph: GlyphState?
    private var lock: InstanceLock?
    private var signalSources: [DispatchSourceSignal] = []

    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--print-menu") {
            printMenuAndExit()
        }
        let application = NSApplication.shared
        let delegate = HalfLidApp()
        application.delegate = delegate
        application.setActivationPolicy(.accessory) // no Dock icon, no main menu
        application.run()
    }

    /// `HalfLidApp --print-menu`: builds the service, takes one reading, prints the menu as text and exits. Used by the
    /// tests; nothing is installed, shown or changed beyond what one tick does.
    private static func printMenuAndExit() -> Never {
        guard let service = AgentService() else {
            FileHandle.standardError.write(Data("resources not found\n".utf8))
            exit(1)
        }
        service.tick(notify: false)
        if CommandLine.arguments.contains("--hold") { service.setHold(.untilStopped) }
        let menu = MenuController(service: service)
        MenuController.describe(menu.menu).forEach { print($0) }
        service.shutdown()
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !AgentService.fakeOverride {
            switch InstanceLock.acquire() {
            case .acquired(let held): lock = held
            case .alreadyRunning:
                FileHandle.standardError.write(Data("another Half Lid is already running\n".utf8))
                NSApplication.shared.terminate(nil)
                return
            case .unavailable: break // cannot create the lock file: go on rather than refuse to protect the Mac
            }
        }
        guard let service = AgentService() else {
            FileHandle.standardError.write(Data("resources not found\n".utf8))
            NSApplication.shared.terminate(nil)
            return
        }
        self.service = service
        menuController = MenuController(service: service)
        panel = PanelHost(service: service)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "HalfLidStatusItem" // keeps the position the user gave the icon among the others
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        service.onChange = { [weak self] in
            self?.refreshIcon()
            self?.panel.refresh()
        }

        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        service.start()
        refreshIcon()

        service.notifier.onActivate = { [weak self] in self?.showPanel() }
        if !AgentService.fakeOverride, !service.preferences.welcomeSeen {
            // First launch: open the panel once under the icon, so it is clear where the app lives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.showPanel() }
        }
    }

    /// Launching the app again while it runs (from Finder or Spotlight) is how someone who cannot find the icon asks for it.
    /// The icon is put back if it was removed, and the panel opens.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.showPanel() }
        return false
    }

    private func showPanel() {
        guard let button = statusItem?.button else { return }
        panel.show(from: button)
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel?.close()
        service?.shutdown()
    }

    /// Click opens the quick-actions panel. Right-click or Control-click opens the classic menu, which stays available for
    /// keyboard and assistive technology users and as a fallback.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        guard wantsMenu else {
            if let button = statusItem.button { panel.toggle(from: button) }
            return
        }
        panel.close()
        statusItem.menu = menuController.menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil // back to "click opens the panel"
    }

    /// Redraws the icon only when the state changed.
    private func refreshIcon() {
        guard let status = service.status, let button = statusItem.button else { return }
        let presentation = StatusPresenter.present(status, catalog: service.catalog)
        let label = service.catalog.text("app.name") + ": " + presentation.title
        button.setAccessibilityLabel(label)
        button.toolTip = label
        guard presentation.glyph != shownGlyph else { return }
        shownGlyph = presentation.glyph
        button.image = Glyph.menuBarImage(state: presentation.glyph)
    }
}
