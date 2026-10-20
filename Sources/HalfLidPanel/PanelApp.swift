import AppKit
import HalfLidCore

/// The panel process. It reads the content to show from standard input (one JSON line per update), sends the user's choices
/// to standard output (one JSON line per request), and exits as soon as it is dismissed or its input closes. So while the
/// panel is closed this process does not exist and uses nothing.
final class PanelApp: NSObject, NSApplicationDelegate {
    private let catalog: Catalog
    private let agents: AgentCatalog
    private let resources: URL
    private let anchor: NSRect
    private var window: PanelWindow?
    private var controller: PanelViewController?
    private var monitors: [Any] = []

    init(catalog: Catalog, agents: AgentCatalog, resources: URL, anchor: NSRect) {
        self.catalog = catalog
        self.agents = agents
        self.resources = resources
        self.anchor = anchor
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let stdin = FileHandle.standardInput
        var buffer = LineBuffer()
        stdin.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { // the menu bar process closed its end (it quit, or closed the panel)
                handle.readabilityHandler = nil
                DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
                return
            }
            let contents = buffer.append(data).compactMap { PanelWire.decode(PanelContent.self, from: $0) }
            DispatchQueue.main.async { contents.forEach { self?.show($0) } }
        }
    }

    // MARK: content

    private func show(_ content: PanelContent) {
        if let controller {
            controller.apply(content)
            return
        }
        let controller = PanelViewController(content: content, catalog: catalog, agents: agents, resources: resources, actions: actions())
        controller.loadViewIfNeeded()
        let window = PanelWindow(contentViewController: controller)
        controller.onResize = { [weak window] size in window?.resize(to: size) }
        window.place(below: anchor)
        self.controller = controller
        self.window = window

        NSApplication.shared.activate(ignoringOtherApps: true)
        window.show()
        installDismissal(for: window)
    }

    private func actions() -> PanelViewController.Actions {
        PanelViewController.Actions(
            hold: { [weak self] minutes in self?.send(.hold(minutes: minutes)) },
            stopHold: { [weak self] in self?.send(.stopHold) },
            setWatching: { [weak self] id, on in self?.send(.setWatching(agentId: id, on: on)) },
            openSettings: { [weak self] in
                self?.send(.openSettings)
                self?.dismiss()
            },
            dismissHint: { [weak self] in self?.send(.dismissHint) },
            quit: { [weak self] in
                self?.send(.quit)
                self?.dismiss()
            }
        )
    }

    private func send(_ request: PanelRequest) {
        try? FileHandle.standardOutput.write(contentsOf: PanelWire.line(request))
    }

    // MARK: dismissal

    /// The panel goes away on a click anywhere else, on Esc, and when another application takes focus.
    private func installDismissal(for window: PanelWindow) {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in self?.dismiss() }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            self?.dismiss()
            return nil
        }) {
            monitors.append(monitor)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            self?.dismiss()
        }
    }

    private func dismiss() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
        NSApplication.shared.terminate(nil)
    }
}
