import AppKit

/// The small square icon that stands for an agent in lists. All of them share one look: a quiet rounded tile with the agent's
/// monochrome mark on it. An agent without a mark uses the icon of its application when that is installed, and otherwise a
/// tile with its initial.
public enum AgentIcon {
    /// How the icon was made, for tests and diagnostics.
    public enum Source: Equatable, Sendable { case mark, installedApp, monogram }

    public static func source(for agent: AgentDefinition, resources: URL?) -> Source {
        if let name = agent.mark, let resources, AgentMark.shape(named: name, in: resources) != nil { return .mark }
        if installedAppIcon(for: agent) != nil { return .installedApp }
        return .monogram
    }

    /// An image of `side` x `side` points. It is drawn when it is needed, with the appearance of whatever shows it, so the colours
    /// follow light and dark mode. `dimmed` is for an agent that is switched off.
    public static func image(for agent: AgentDefinition, name: String, side: CGFloat, dimmed: Bool = false, resources: URL?) -> NSImage {
        let size = NSSize(width: side, height: side)
        if let markName = agent.mark, let resources, let shape = AgentMark.shape(named: markName, in: resources) {
            return NSImage(size: size, flipped: true) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                drawTile(in: rect)
                let box = rect.insetBy(dx: rect.width * 0.21, dy: rect.height * 0.21)
                AgentMark.draw(shape, in: box, color: dimmed ? .tertiaryLabelColor : .labelColor, flipped: true, context: context)
                return true
            }
        }
        if let icon = installedAppIcon(for: agent, side: side) { return icon }
        let initial = String(name.first.map { Character($0.uppercased()) } ?? "?")
        return NSImage(size: size, flipped: true) { rect in
            drawTile(in: rect)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: rect.height * 0.46, weight: .semibold),
                .foregroundColor: dimmed ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor,
            ]
            let text = NSAttributedString(string: initial, attributes: attributes)
            let measured = text.size()
            text.draw(at: NSPoint(x: rect.midX - measured.width / 2, y: rect.midY - measured.height / 2))
            return true
        }
    }

    private static func drawTile(in rect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.27, yRadius: rect.width * 0.27).fill()
    }

    private static func installedAppIcon(for agent: AgentDefinition, side: CGFloat = 22) -> NSImage? {
        for id in agent.appBundleIds {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            // A fixed bitmap at twice the display size: the system's own icon object loads lazily and can draw a blank
            // placeholder the first time, so the bitmap is requested here, which waits until it is really there.
            var rect = NSRect(x: 0, y: 0, width: side * 2, height: side * 2)
            if let bitmap = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                return NSImage(cgImage: bitmap, size: NSSize(width: side, height: side))
            }
        }
        return nil
    }
}
