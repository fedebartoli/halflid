import AppKit

public enum GlyphState: String, Codable, Sendable, CaseIterable {
    /// Lid closed: Half Lid is resting.
    case idle
    /// Lid half open: the Mac is being kept awake.
    case active
    /// Lid half open with a dot beyond the tip: stopped by a safety limit.
    case warning
}

/// The Half Lid mark, drawn in code from the traced drawings in `LidGlyph` so it is sharp at any size and the app needs no
/// image files.
public enum Glyph {
    /// Size, in points, of the menu bar image: the same canvas for all three states, so the item never changes width.
    public static let menuBarSize = NSSize(width: 24, height: 16)

    // MARK: menu bar

    /// Template image for the menu bar: it only carries shape, macOS tints it for light, dark and highlighted states.
    public static func menuBarImage(state: GlyphState) -> NSImage {
        let image = NSImage(size: menuBarSize, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            drawMenuBar(state: state, in: rect, color: .black, context: context)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Menu bar mark as a PNG (black on transparent) at `scale` pixels per point, for previews and tests. The real menu bar
    /// uses `menuBarImage`.
    public static func menuBarPNG(state: GlyphState, scale: Int = 2) -> Data? {
        let size = menuBarSize
        return renderPNG(pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale, pointSize: size) { context in
            drawMenuBar(state: state, in: CGRect(origin: .zero, size: size), color: .black, context: context)
        }
    }

    /// The same unit scale in every state, the mark placed on whole device pixels. Each state is centred on its own body, so
    /// the closed mark (a short, wide shape) sits in the middle of the bar instead of low in its box. The base starts half a
    /// point in, which keeps the hinge (a hair outside the base's own start) and the dot (beyond its end) inside the canvas.
    private static func drawMenuBar(state: GlyphState, in rect: CGRect, color: NSColor, context: CGContext) {
        let shapes = LidGlyph.shapes(for: state)
        let k = rect.width / LidGlyph.menuBarDesignWidth
        let backing = max(1, context.ctm.a)
        func snapped(_ value: CGFloat) -> CGFloat { (value * backing).rounded() / backing }
        let origin = CGPoint(x: snapped(rect.minX + 0.5), y: snapped(rect.midY - shapes.bodyBounds.midY * k))
        fill(shapes, transform: CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: k, y: k), body: color, dot: color, in: context)
    }

    // MARK: general drawing

    /// Draws the mark inside `rect`, as large as fits and centred.
    public static func draw(state: GlyphState, in rect: CGRect, body: NSColor, dot: NSColor? = nil, context: CGContext) {
        let shapes = LidGlyph.shapes(for: state)
        let bounds = shapes.bounds
        let k = min(rect.width / bounds.width, rect.height / bounds.height)
        let transform = CGAffineTransform(
            translationX: rect.midX - bounds.midX * k, y: rect.midY - bounds.midY * k
        ).scaledBy(x: k, y: k)
        fill(shapes, transform: transform, body: body, dot: dot ?? body, in: context)
    }

    private static func fill(_ shapes: LidGlyph.Shapes, transform: CGAffineTransform, body: NSColor, dot: NSColor, in context: CGContext) {
        context.saveGState()
        context.concatenate(transform)
        context.setFillColor(body.cgColor)
        context.addPath(shapes.body)
        context.fillPath(using: .winding)
        if let dotPath = shapes.dot {
            context.setFillColor(dot.cgColor)
            context.addPath(dotPath)
            context.fillPath(using: .winding)
        }
        context.restoreGState()
    }

    // MARK: app icon

    /// Colours of the app icon: a flat graphite tile, an off-white mark, an amber dot. No gradient, no glow.
    static let iconTile = NSColor(srgbRed: 0.145, green: 0.153, blue: 0.165, alpha: 1)
    static let iconMark = NSColor(srgbRed: 0.94, green: 0.93, blue: 0.90, alpha: 1)
    static let iconWarning = NSColor(srgbRed: 0.93, green: 0.67, blue: 0.24, alpha: 1)

    /// App icon: the mark on a flat rounded square.
    public static func appIconPNG(state: GlyphState = .active, pixelSize: Int) -> Data? {
        renderPNG(pixelsWide: pixelSize, pixelsHigh: pixelSize, pointSize: NSSize(width: pixelSize, height: pixelSize)) { context in
            let side = CGFloat(pixelSize)
            let inset = side * 0.0977 // macOS icon grid: an 824-point tile inside 1024
            let tile = CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
            context.setFillColor(iconTile.cgColor)
            context.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.2237, cornerHeight: tile.width * 0.2237, transform: nil))
            context.fillPath()

            let width = tile.width * 0.78
            let area = CGRect(x: tile.midX - width / 2, y: tile.midY - width / 2, width: width, height: width)
            draw(state: state, in: area, body: iconMark, dot: iconWarning, context: context)
        }
    }

    // MARK: files

    /// The mark as an SVG (one colour, `currentColor`), y pointing down as SVG expects.
    public static func svg(state: GlyphState, padding: CGFloat = 20) -> String {
        let shapes = LidGlyph.shapes(for: state)
        let box = shapes.bounds.insetBy(dx: -padding, dy: -padding)
        var parts = ["<path d=\"\(pathData(shapes.body))\"/>"]
        if let dot = shapes.dot { parts.append("<path d=\"\(pathData(dot))\"/>") }
        let viewBox = [box.minX, -box.maxY, box.width, box.height].map(number).joined(separator: " ")
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="\(viewBox)" fill="currentColor" fill-rule="nonzero">
        \(parts.joined(separator: "\n"))
        </svg>

        """
    }

    private static func number(_ value: CGFloat) -> String {
        let text = String(format: "%.2f", Double(value))
        guard text.contains(".") else { return text }
        var trimmed = text
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed == "-0" ? "0" : trimmed
    }

    private static func pathData(_ path: CGPath) -> String {
        var commands: [String] = []
        func point(_ p: CGPoint) -> String { "\(number(p.x)) \(number(-p.y))" }
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            let p = element.points
            switch element.type {
            case .moveToPoint: commands.append("M\(point(p[0]))")
            case .addLineToPoint: commands.append("L\(point(p[0]))")
            case .addQuadCurveToPoint: commands.append("Q\(point(p[0])) \(point(p[1]))")
            case .addCurveToPoint: commands.append("C\(point(p[0])) \(point(p[1])) \(point(p[2]))")
            case .closeSubpath: commands.append("Z")
            @unknown default: break
            }
        }
        return commands.joined(separator: "")
    }

    /// Renders into a bitmap of `pixelsWide` x `pixelsHigh`, drawing in a space of `pointSize` points.
    private static func renderPNG(pixelsWide: Int, pixelsHigh: Int, pointSize: NSSize, _ body: (CGContext) -> Void) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = pointSize
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let cg = context.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        // Draw in points whatever the context's own scale turns out to be.
        let wanted = CGFloat(pixelsWide) / pointSize.width
        if cg.ctm.a > 0 { cg.scaleBy(x: wanted / cg.ctm.a, y: wanted / cg.ctm.a) }
        body(cg)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
