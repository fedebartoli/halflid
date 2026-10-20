import SwiftUI

// Throwaway experiment: smallest possible SwiftUI MenuBarExtra app, to measure its memory.
@main
struct Probe: App {
    init() { NSApplication.shared.setActivationPolicy(.accessory) }
    var body: some Scene {
        MenuBarExtra("Half Lid", systemImage: "laptopcomputer") {
            Text("Status: idle")
            Divider()
            Button("Keep awake") {}
            Button("Settings") {}
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}
