import AppKit
import SwiftUI

// Throwaway experiment: AppKit status item; after 3 s a SwiftUI settings window is created, after 9 s it is closed and released.
struct SettingsView: View {
    @State private var flags = Array(repeating: true, count: 12)
    var body: some View {
        Form {
            ForEach(0..<12, id: \.self) { index in
                Toggle("Module \(index + 1)", isOn: $flags[index])
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 480)
    }
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
            window.contentView = NSHostingView(rootView: SettingsView())
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
