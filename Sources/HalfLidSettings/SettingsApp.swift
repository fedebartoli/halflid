import AppKit
import HalfLidCore
import SwiftUI

/// The settings window of Half Lid. It is a separate program from the menu bar app and exists only while the window is open
/// (see docs/DECISIONS.md, section 6): closing the window ends the process and gives back all of its memory.
@main
struct HalfLidSettingsApp: App {
    @NSApplicationDelegateAdaptor(SettingsAppDelegate.self) private var delegate
    @State private var model: SettingsModel

    init() {
        let requested = Self.requestedSection()
        // One settings window only: a second start asks the first one to come to the front, then ends.
        guard SingleInstance.claim(section: requested) else { exit(0) }
        let model = SettingsModel(section: requested ?? .general)
        _model = State(initialValue: model)
        SettingsAppDelegate.onShow = { section in
            if let section { model.section = section }
        }
    }

    var body: some Scene {
        Window(model.text("settings.title"), id: "settings") {
            SettingsRoot(model: model)
        }
        .defaultSize(width: Self.startingSize.width, height: Self.startingSize.height)
        .windowResizability(.contentMinSize)
        .commands {
            // This menu's Quit would otherwise read "Quit Half Lid" and suggest it ends the menu bar app too.
            CommandGroup(replacing: .appTermination) {
                Button(model.text("settings.menu.close")) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            CommandGroup(after: .sidebar) {
                Divider()
                ForEach(Array(SettingsSection.allCases.enumerated()), id: \.element) { index, section in
                    Button(model.text(section.titleKey)) { model.section = section }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
        }
    }

    /// The size the window opens with. `HALFLID_WINDOW_SIZE=780x820` asks for another one, so that a long pane can be photographed
    /// whole (`scripts/screenshots.sh`).
    private static var startingSize: CGSize {
        let asked = (ProcessInfo.processInfo.environment["HALFLID_WINDOW_SIZE"] ?? "").split(separator: "x").compactMap { Double($0) }
        guard asked.count == 2, asked.allSatisfy({ (400...2_000).contains($0) }) else { return CGSize(width: 780, height: 580) }
        return CGSize(width: asked[0], height: asked[1])
    }

    /// `--section general|agents|...`: where the window opens (the menu bar app can ask for a particular pane).
    private static func requestedSection() -> SettingsSection? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--section"), arguments.indices.contains(index + 1) else { return nil }
        return SettingsSection(rawValue: arguments[index + 1])
    }
}

final class SettingsAppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app once the model exists: shows the given pane when another start asks for this window.
    @MainActor static var onShow: ((SettingsSection?) -> Void)?
    private var showObserver: NSObjectProtocol?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The bundle says "no Dock icon" for the menu bar app; this window is a normal app window with a menu bar of its own.
        NSApp.setActivationPolicy(.regular)
        // `--appearance light|dark` is for checking both looks during development; normally the system's choice applies.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--appearance"), arguments.indices.contains(index + 1) {
            NSApp.appearance = NSAppearance(named: arguments[index + 1] == "dark" ? .darkAqua : .aqua)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate()
        placeOnSharpestScreenIfAsked()
        showObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstance.showNotification, object: nil, queue: .main
        ) { note in
            let section = (note.userInfo?["section"] as? String).flatMap(SettingsSection.init(rawValue:))
            MainActor.assumeIsolated {
                Self.onShow?(section)
                NSApp.activate()
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// `HALFLID_WINDOW_SCREEN=sharpest` puts the first window on the screen with the most pixels to the point, wherever the system
    /// would have opened it, so that the pictures made by `scripts/screenshots.sh` are as sharp as a Retina screen shows them.
    private func placeOnSharpestScreenIfAsked() {
        guard ProcessInfo.processInfo.environment["HALFLID_WINDOW_SCREEN"] == "sharpest" else { return }
        var looks = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            looks += 1
            MainActor.assumeIsolated {
                // The window is made by SwiftUI at a moment of its own choosing: look for it until it is there.
                guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else {
                    if looks >= 50 { timer.invalidate() }
                    return
                }
                timer.invalidate()
                guard let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }),
                      screen != window.screen else { return }
                let area = screen.visibleFrame
                window.setFrameTopLeftPoint(NSPoint(x: area.midX - window.frame.width / 2, y: area.maxY - 24))
            }
        }
    }
}

/// Makes sure only one settings window exists.
enum SingleInstance {
    static let showNotification = Notification.Name("io.github.fedebartoli.halflid.settings.show")
    nonisolated(unsafe) private static var held: InstanceLock?

    /// `true` when this process is the first; otherwise the first one is asked to show itself and `false` is returned.
    static func claim(section: SettingsSection?) -> Bool {
        // `HALFLID_SETTINGS_LOCK` moves the lock, so a run against sample files neither waits for nor wakes a real window.
        let path = ProcessInfo.processInfo.environment["HALFLID_SETTINGS_LOCK"]
            ?? NSString(string: "~/Library/Application Support/HalfLid/settings.lock").expandingTildeInPath
        switch InstanceLock.acquire(path: path) {
        case .acquired(let lock):
            held = lock
            return true
        case .alreadyRunning:
            DistributedNotificationCenter.default().postNotificationName(
                showNotification, object: nil, userInfo: section.map { ["section": $0.rawValue] }, deliverImmediately: true
            )
            usleep(150_000) // the request is handed to the system before this process ends
            return false
        case .unavailable:
            return true // cannot create the lock file: show the window rather than refuse
        }
    }
}
