import AppKit
import Foundation
import HalfLidCore

/// Draws `shape` in a `side` x `side` bitmap and returns the alpha of every pixel, rows from the top.
private func renderAlpha(_ shape: SVGShape, side: Int) -> [[Double]]? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    AgentMark.draw(shape, in: CGRect(x: 0, y: 0, width: side, height: side), color: .black, flipped: false, context: context.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    return (0..<side).map { y in (0..<side).map { x in Double(bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) } }
}

func runMarkTests() {
    // Path data: the commands, relative forms, implicit repeats and compact number forms.
    func bounds(_ data: String) -> CGRect? { SVGShape.parsePath(data)?.boundingBoxOfPath }
    expect(bounds("M0 0h10v10H0z") == CGRect(x: 0, y: 0, width: 10, height: 10), "H, V and Z draw a square")
    expect(bounds("m1 1l2 0 0 2z") == CGRect(x: 1, y: 1, width: 2, height: 2), "relative commands and an implicit repeat of l")
    expect(bounds("M1 1 4 1 4 4") == CGRect(x: 1, y: 1, width: 3, height: 3), "extra pairs after M are line segments")
    expect(bounds("M.5.5L1.5.5") == CGRect(x: 0.5, y: 0.5, width: 1, height: 0), "numbers may run together (.5.5)")
    expect(bounds("M0 0C0 5 10 5 10 0S20-5 20 0") != nil, "cubic and smooth cubic curves")
    expect(bounds("M0 0Q5 5 10 0T20 0") != nil, "quadratic and smooth quadratic curves")
    if let arc = bounds("M0 0a5 5 0 0 1 10 0") {
        expect(abs(arc.minY + 5) < 0.05 && abs(arc.maxY) < 0.05 && abs(arc.width - 10) < 0.05, "an arc of radius 5 rises 5 above its chord with sweep 1")
    } else {
        expect(false, "an arc parses")
    }
    if let arc = bounds("M0 0a5 5 0 0 0 10 0") {
        expect(abs(arc.minY) < 0.05 && abs(arc.maxY - 5) < 0.05, "the same arc with sweep 0 falls below its chord")
    } else {
        expect(false, "an arc with sweep 0 parses")
    }
    expect(bounds("M0 0a1 1 0 013 0") != nil, "arc flags may be written without separators")
    expect(bounds("M0 0a1 1 0 01 3 0")?.width ?? 0 > 2.9, "an arc whose radius is too small is scaled up to reach its end")
    expect(SVGShape.parsePath("") == nil, "empty path data gives nothing")
    expect(SVGShape.parsePath("L0 0") == nil, "path data must start with a move")
    expect(SVGShape.parsePath("M0") == nil, "a move without its second number is refused")
    expect(SVGShape.parsePath("M0 0 X1 1") == nil, "an unknown command is refused")
    expect(SVGShape(data: Data("<svg viewBox=\"0 0 24 24\"><rect/></svg>".utf8)) == nil, "an SVG without paths is refused")
    expect(SVGShape(data: Data("not xml".utf8)) == nil, "text that is not SVG is refused")

    // The bundled marks: every agent in the catalog has one, it reads, stays inside its viewBox and draws something sensible.
    let resources = repositoryRoot.appendingPathComponent("Resources")
    guard let agents = try? AgentCatalog.load(from: resources.appendingPathComponent("agents.json")) else {
        expect(false, "the agent catalog loads for the mark tests")
        return
    }
    for agent in agents.agents {
        guard let name = agent.mark else {
            expect(false, "\(agent.id) names a mark")
            continue
        }
        guard let shape = AgentMark.shape(named: name, in: resources) else {
            expect(false, "\(agent.id): the mark \(name).svg reads")
            continue
        }
        let box = shape.viewBox.insetBy(dx: -0.5, dy: -0.5)
        expect(box.contains(shape.bounds), "\(agent.id): the mark stays inside its viewBox")
        if let alpha = renderAlpha(shape, side: 48) {
            let covered = Double(alpha.flatMap { $0 }.filter { $0 > 0.5 }.count) / Double(48 * 48)
            expect(covered > 0.15 && covered < 0.85, "\(agent.id): the mark covers a sensible part of its box (\(Int(covered * 100))%)")
        } else {
            expect(false, "\(agent.id): the mark can be drawn")
        }
        expect(AgentIcon.source(for: agent, resources: resources) == .mark, "\(agent.id): the icon is the mark")
    }

    // Holes: the mark of opencode is a frame, so its middle is empty and its sides are filled.
    if let shape = AgentMark.shape(named: "opencode", in: resources), let alpha = renderAlpha(shape, side: 48) {
        expect(alpha[24][24] < 0.1, "opencode: the middle of the frame is empty")
        expect(alpha[24][9] > 0.9, "opencode: the side of the frame is filled")
    } else {
        expect(false, "the opencode mark can be drawn")
    }
    // Even-odd filling (the marks of Codex and Goose rely on it). Two squares written the same way: the inner one is a hole
    // only when the element asks for the even-odd rule, and is filled over by the non-zero rule.
    let squares = "M2 2h20v20H2z M8 8h8v8H8z"
    let ring = SVGShape(data: Data("<svg viewBox=\"0 0 24 24\"><path fill-rule=\"evenodd\" d=\"\(squares)\"/></svg>".utf8))
    let plate = SVGShape(data: Data("<svg viewBox=\"0 0 24 24\"><path d=\"\(squares)\"/></svg>".utf8))
    if let ring, let alpha = renderAlpha(ring, side: 96) {
        expect(alpha[48][12] > 0.9 && alpha[48][48] < 0.1, "even-odd: the band is filled and the middle is a hole")
    } else {
        expect(false, "the even-odd test shape can be drawn")
    }
    if let plate, let alpha = renderAlpha(plate, side: 96) {
        expect(alpha[48][12] > 0.9 && alpha[48][48] > 0.9, "non-zero: squares written the same way are filled right through")
    } else {
        expect(false, "the non-zero test shape can be drawn")
    }

    // Names are plain file stems; nothing can reach outside the marks folder.
    expect(AgentMark.shape(named: "../agents", in: resources) == nil, "a mark name cannot climb out of the folder")
    expect(AgentMark.shape(named: "cursor/../cursor", in: resources) == nil, "a mark name cannot contain a path")
    expect(AgentMark.shape(named: "", in: resources) == nil, "an empty mark name is refused")
    expect(AgentMark.shape(named: "no-such-mark", in: resources) == nil, "a missing mark file gives nothing")

    // Without a mark an agent falls back to an installed app, then to its initial; the image is always the size asked for.
    let unknown = AgentDefinition(id: "x", appBundleIds: ["no.such.bundle.identifier"], mark: "no-such-mark")
    expect(AgentIcon.source(for: unknown, resources: resources) == .monogram, "an agent with nothing to show gets a monogram")
    let image = AgentIcon.image(for: unknown, name: "Example", side: 22, resources: resources)
    expect(image.size == NSSize(width: 22, height: 22), "the fallback icon has the size asked for")
    expect(AgentIcon.image(for: agents.agents[0], name: "Cursor", side: 30, resources: resources).size == NSSize(width: 30, height: 30), "a mark icon has the size asked for")
    expect(AgentIcon.image(for: unknown, name: "Example", side: 22, resources: nil).size.width == 22, "an icon can be made without a resources folder")

    // A catalog that predates marks still loads.
    let legacy = #"{"agents":[{"id":"a","processNames":[],"pathContains":[],"sessionPaths":[],"verified":false}]}"#
    expect((try? JSONDecoder().decode(AgentCatalog.self, from: Data(legacy.utf8)))?.agents.first?.mark == nil, "a catalog without marks still loads")
}
