import AppKit
import HalfLidCore

// HalfLidPanel: the quick-actions panel of the menu bar app, run only while the panel is open.
// Normal use: started by HalfLidApp as `HalfLidPanel --anchor x,y,w,h` (the menu bar icon's frame in screen coordinates).
// The check modes (--print, --render, --measure) are described in PanelPreview.swift.

let arguments = CommandLine.arguments
if arguments.contains("--print") { PanelPreview.printAndExit() }
if arguments.contains("--measure") { PanelPreview.measureAndExit() }
if arguments.contains("--sample") { PanelPreview.sampleAndExit() }
if let index = arguments.firstIndex(of: "--render"), arguments.indices.contains(index + 1) {
    PanelPreview.renderAndExit(path: arguments[index + 1])
}

guard let resources = ResourceLocator.resourcesDirectory(),
      let agents = try? AgentCatalog.load(from: resources.appendingPathComponent("agents.json")) else {
    FileHandle.standardError.write(Data("resources not found\n".utf8))
    exit(1)
}
let catalog = Catalog.load(directory: resources.appendingPathComponent("i18n"), language: Preferences.load().language)

func anchorFromArguments() -> NSRect {
    if let index = arguments.firstIndex(of: "--anchor"), arguments.indices.contains(index + 1) {
        let numbers = arguments[index + 1].split(separator: ",").compactMap { Double($0) }
        if numbers.count == 4 { return NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) }
    }
    let mouse = NSEvent.mouseLocation // no anchor given: appear under the pointer
    return NSRect(x: mouse.x - 12, y: mouse.y - 12, width: 24, height: 24)
}

let application = NSApplication.shared
let delegate = PanelApp(catalog: catalog, agents: agents, resources: resources, anchor: anchorFromArguments())
application.delegate = delegate
application.setActivationPolicy(.accessory) // no Dock icon, no menu bar
application.run()
