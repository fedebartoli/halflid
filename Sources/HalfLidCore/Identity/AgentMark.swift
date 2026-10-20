import AppKit

/// The monochrome mark that stands for a coding agent in the interface. The marks are plain SVG files in the resources
/// (`agent-marks/`), read by `SVGShape` and drawn in whatever colour the interface asks for, so they follow light and dark
/// mode. They are separate files on purpose: they can be replaced or removed without touching the code (see NOTICE).
public enum AgentMark {
    /// Loads `agent-marks/<name>.svg`. Names are plain file stems; anything else is refused.
    public static func shape(named name: String, in resources: URL) -> SVGShape? {
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return SVGShape(contentsOf: resources.appendingPathComponent("agent-marks").appendingPathComponent(name + ".svg"))
    }

    /// Draws `shape` as large as fits in `rect`, centred, in `color`. `flipped` says whether the context's y axis points down
    /// (as in a flipped view); the marks are stored y-down.
    public static func draw(_ shape: SVGShape, in rect: CGRect, color: NSColor, flipped: Bool, context: CGContext) {
        let bounds = shape.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let k = min(rect.width / bounds.width, rect.height / bounds.height)
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: k, y: flipped ? k : -k)
        context.translateBy(x: -bounds.midX, y: -bounds.midY)
        context.setFillColor(color.cgColor)
        for piece in shape.pieces {
            context.addPath(piece.path)
            context.fillPath(using: piece.evenOdd ? .evenOdd : .winding)
        }
        context.restoreGState()
    }
}
