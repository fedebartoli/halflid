import AppKit
import HalfLidCore

/// Command-line checks of the panel. They never show a window.
///
///   HalfLidPanel --print                  reads one content line from standard input, prints the panel it would show as text
///   HalfLidPanel --render PATH [--dark] [--state idle|active|warning|hold|stopped|welcome]
///                                         a PNG of the panel with sample content, to look at the layout
///   HalfLidPanel --sample [STATE]         prints the sample content as one line (to feed a real panel by hand)
///   HalfLidPanel --measure                memory footprint before, with and after a panel is built, for several rounds
enum PanelPreview {
    private static let noActions = PanelViewController.Actions(
        hold: { _ in }, stopHold: {}, setWatching: { _, _ in }, openSettings: {}, dismissHint: {}, quit: {}
    )

    private static func resources() -> (catalog: Catalog, agents: AgentCatalog, directory: URL) {
        guard let directory = ResourceLocator.resourcesDirectory(),
              let agents = try? AgentCatalog.load(from: directory.appendingPathComponent("agents.json")) else { fail("resources not found") }
        return (Catalog.load(directory: directory.appendingPathComponent("i18n"), language: Preferences.load().language), agents, directory)
    }

    static func printAndExit() -> Never {
        let (catalog, agents, directory) = resources()
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let line = input.split(separator: 0x0A).first, let content = PanelWire.decode(PanelContent.self, from: Data(line)) else {
            fail("expected one panel content line on standard input")
        }
        PanelViewController(content: content, catalog: catalog, agents: agents, resources: directory, actions: noActions).describe().forEach { print($0) }
        exit(0)
    }

    /// Prints the sample content as one line, the way the menu bar app would send it. For trying the panel by hand:
    /// `(HalfLidPanel --sample active; sleep 5) | HalfLidPanel --anchor 800,1000,24,24`
    static func sampleAndExit() -> Never {
        let (catalog, agents, _) = resources()
        let arguments = CommandLine.arguments
        let state = arguments.firstIndex(of: "--sample").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "active"
        FileHandle.standardOutput.write(PanelWire.line(sampleContent(state: state, catalog: catalog, agents: agents)))
        exit(0)
    }

    static func measureAndExit() -> Never {
        _ = NSApplication.shared
        let (catalog, agents, directory) = resources()
        let content = sampleContent(state: "active", catalog: catalog, agents: agents)
        func megabytes() -> String {
            var usage = rusage_info_current()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
            }
            return result == 0 ? String(format: "%.1f MB", Double(usage.ri_phys_footprint) / 1_048_576) : "?"
        }
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        settle()
        print("before the first panel: \(megabytes())")
        for round in 1...3 {
            autoreleasepool {
                let panel = PanelViewController(content: content, catalog: catalog, agents: agents, resources: directory, actions: noActions)
                panel.loadViewIfNeeded()
                settle()
                print("round \(round) panel built:   \(megabytes())")
            }
            settle()
            print("round \(round) panel released: \(megabytes())")
        }
        exit(0)
    }

    static func renderAndExit(path: String) -> Never {
        _ = NSApplication.shared // AppKit must be initialised before views are drawn
        let (catalog, agents, directory) = resources()
        let arguments = CommandLine.arguments
        let state = arguments.firstIndex(of: "--state").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "active"
        let panel = PanelViewController(
            content: sampleContent(state: state, catalog: catalog, agents: agents), catalog: catalog, agents: agents,
            resources: directory, actions: noActions
        )
        panel.loadViewIfNeeded()

        let size = panel.preferredContentSize
        let backdrop = BackdropView(frame: NSRect(origin: .zero, size: size))
        backdrop.appearance = NSAppearance(named: arguments.contains("--dark") ? .darkAqua : .aqua)
        panel.view.frame = backdrop.bounds
        backdrop.addSubview(panel.view)
        backdrop.layoutSubtreeIfNeeded()

        let scale = 2
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { fail("cannot create the image") }
        bitmap.size = size
        backdrop.cacheDisplay(in: backdrop.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
            fail("cannot write \(path)")
        }
        exit(0)
    }

    /// Fixed sample content, so a rendering shows each state without needing the real conditions.
    static func sampleContent(state: String, catalog: Catalog, agents: AgentCatalog) -> PanelContent {
        let now = Date()
        var preferences = Preferences()
        // Every command-line agent is watched except opencode, so the picture shows a row that is switched off too.
        preferences.cliAgents = agents.agents.map(\.id).filter { $0 != "cursor" && $0 != "opencode" }
        var report = WorkReport(seenAgents: ["cursor", "claude-code"])
        var status = AgentLoop.Status(armed: false, indicator: .idle, report: report, at: now)
        switch state {
        case "idle", "welcome":
            break
        case "warning":
            report = WorkReport(working: true, workingAgents: ["claude-code"], seenAgents: ["cursor", "claude-code"])
            status = AgentLoop.Status(armed: true, indicator: .warning, report: report, armedSeconds: 3_000, at: now)
        case "hold":
            status = AgentLoop.Status(armed: true, indicator: .active, report: report, hold: .until(now.addingTimeInterval(3_600)), armedSeconds: 60, at: now)
        case "stopped":
            status = AgentLoop.Status(armed: false, indicator: .warning, latch: .batteryLow, report: report, at: now)
        default: // active
            let chats = [CursorChat(id: "a", activity: .working)]
            report = WorkReport(working: true, cursor: CursorActivity(chats: chats), workingAgents: ["claude-code"], seenAgents: ["cursor", "claude-code"])
            status = AgentLoop.Status(armed: true, indicator: .active, report: report, armedSeconds: 4_320, at: now)
        }
        let session = SessionSummary(startedAt: now.addingTimeInterval(-4_320), endedAt: now, ending: .finished)
        return PanelPresenter.present(
            status: status, preferences: preferences, agents: agents, lastSession: session, catalog: catalog, welcome: state == "welcome"
        )
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}

/// Stands in for the panel's material when it is drawn without a window.
private final class BackdropView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
}
