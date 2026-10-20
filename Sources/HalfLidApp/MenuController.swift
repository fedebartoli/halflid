import AppKit
import HalfLidCore

/// Builds the menu from the current state each time it opens, so it never shows stale or hidden entries and costs nothing
/// while closed. Native NSMenu only: no windows, no SwiftUI.
final class MenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let service: AgentService

    init(service: AgentService) {
        self.service = service
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        service.tick(notify: false) // fresh readings for the moment the user looks
        rebuild()
    }

    func rebuild() {
        let text = service.catalog
        menu.removeAllItems()

        if let status = service.status {
            let presentation = StatusPresenter.present(status, catalog: text)
            menu.addItem(NSMenuItem.sectionHeader(title: presentation.title))
            if let detail = presentation.detail { menu.addItem(note(detail)) }
            if !status.armed, let session = service.lastSession {
                menu.addItem(note(StatusPresenter.sessionLine(session, catalog: text)))
            }
        }
        menu.addItem(.separator())

        if service.hold == .none {
            let parent = NSMenuItem(title: text.text("menu.keepAwake"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for (key, minutes) in [("menu.keepAwake.untilStopped", 0), ("menu.keepAwake.minutes30", 30), ("menu.keepAwake.hour1", 60),
                                   ("menu.keepAwake.hours2", 120), ("menu.keepAwake.hours4", 240)] {
                let item = NSMenuItem(title: text.text(key), action: #selector(holdChosen(_:)), keyEquivalent: "")
                item.target = self
                item.tag = minutes
                submenu.addItem(item)
            }
            parent.submenu = submenu
            menu.addItem(parent)
        } else {
            let stop = NSMenuItem(title: text.text("menu.keepAwake.stop"), action: #selector(holdStopped), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
        }
        menu.addItem(.separator())

        menu.addItem(watchMenu(text))
        menu.addItem(lidMenu(text))
        menu.addItem(.separator())

        let settings = NSMenuItem(title: text.text("menu.settings"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: text.text("menu.quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// Plain text line in the secondary colour. Disabled, so it cannot be mistaken for an action.
    private func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: title, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.menuFont(ofSize: 0)]
        )
        item.isEnabled = false
        return item
    }

    private func watchMenu(_ text: Catalog) -> NSMenuItem {
        let parent = NSMenuItem(title: text.text("menu.watch"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let cursor = NSMenuItem(title: text.text("agent.cursor"), action: #selector(toggleCursor), keyEquivalent: "")
        cursor.target = self
        cursor.state = service.preferences.cursorEnabled ? .on : .off
        submenu.addItem(cursor)
        for agent in service.agentCatalog.agents where agent.id != "cursor" {
            let item = NSMenuItem(title: text.text("agent.\(agent.id)"), action: #selector(toggleAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.id
            item.state = service.preferences.watchesCommandLineAgent(agent.id) ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }

    private func lidMenu(_ text: Catalog) -> NSMenuItem {
        let parent = NSMenuItem(title: text.text("menu.lid"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        let lock = NSMenuItem(title: text.text("menu.lid.lock"), action: #selector(toggleLock), keyEquivalent: "")
        lock.target = self
        lock.state = service.preferences.lockOnClose ? .on : .off
        submenu.addItem(lock)
        let display = NSMenuItem(title: text.text("menu.lid.displayOff"), action: #selector(toggleDisplayOff), keyEquivalent: "")
        display.target = self
        display.state = service.preferences.displayOffOnClose ? .on : .off
        submenu.addItem(display)
        parent.submenu = submenu
        return parent
    }

    // MARK: actions

    @objc private func holdChosen(_ sender: NSMenuItem) {
        service.setHold(sender.tag == 0 ? .untilStopped : .until(Date().addingTimeInterval(Double(sender.tag) * 60)))
    }

    @objc private func holdStopped() {
        service.setHold(.none)
    }

    @objc private func toggleCursor() {
        service.setWatching("cursor", !service.preferences.cursorEnabled)
    }

    @objc private func toggleAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        service.setWatching(id, !service.preferences.watchesCommandLineAgent(id))
    }

    @objc private func openSettings() {
        service.openSettings()
    }

    @objc private func toggleLock() {
        var preferences = service.preferences
        preferences.lockOnClose.toggle()
        service.update(preferences: preferences)
    }

    @objc private func toggleDisplayOff() {
        var preferences = service.preferences
        preferences.displayOffOnClose.toggle()
        service.update(preferences: preferences)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: description (used by `--print-menu`)

    /// The menu as plain text, one line per entry, for a command-line check of what the app would show.
    static func describe(_ menu: NSMenu, indent: String = "") -> [String] {
        var lines: [String] = []
        for item in menu.items {
            if item.isSeparatorItem { lines.append(indent + "---"); continue }
            let mark = item.state == .on ? "[x] " : ""
            let kind = item.isSectionHeader ? "# " : (item.isEnabled || item.submenu != nil ? "" : "~ ")
            lines.append(indent + kind + mark + item.title)
            if let submenu = item.submenu { lines.append(contentsOf: describe(submenu, indent: indent + "  ")) }
        }
        return lines
    }
}
