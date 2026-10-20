import AppKit

// Throwaway experiment: AppKit status item; after 3 s an AppKit settings window (12 switches) is created, after 9 s closed and released.
func settingsContent() -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    for index in 1...12 {
        let label = NSTextField(labelWithString: "Module \(index)")
        let toggle = NSSwitch()
        toggle.state = .on
        let row = NSStackView(views: [label, NSView(), toggle])
        row.orientation = .horizontal
        row.widthAnchor.constraint(equalToConstant: 380).isActive = true
        stack.addArrangedSubview(row)
    }
    return stack
}

final class Delegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem?
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Half Lid")
        let menu = NSMenu()
        menu.addItem(withTitle: "Status: idle", action: nil, keyEquivalent: "")
        item.menu = menu
        self.item = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 480), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = settingsContent()
            window.isReleasedWhenClosed = false
            window.orderFrontRegardless()
            self?.window = window
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) { [weak self] in
            self?.window?.contentView = nil
            self?.window?.close()
            self?.window = nil
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
