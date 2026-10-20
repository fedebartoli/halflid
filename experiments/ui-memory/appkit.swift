import AppKit

// Throwaway experiment: smallest possible AppKit menu bar app, to measure its memory.
final class Delegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: "Half Lid")
        let menu = NSMenu()
        menu.addItem(withTitle: "Status: idle", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Keep awake", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "Settings", action: nil, keyEquivalent: ",")
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        self.item = item
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate()
app.delegate = delegate
app.run()
