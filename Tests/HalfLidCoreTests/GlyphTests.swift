import AppKit
import Foundation
import HalfLidCore
import ImageIO

/// Alpha values of a PNG, row by row from the top.
private func alphaRows(_ png: Data?) -> [[UInt8]]? {
    guard let png, let rep = NSBitmapImageRep(data: png) else { return nil }
    var rows: [[UInt8]] = []
    for y in 0..<rep.pixelsHigh {
        rows.append((0..<rep.pixelsWide).map { x in UInt8((rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) * 255 + 0.5) })
    }
    return rows
}

/// The rows of a menu bar PNG that have any ink.
private func inkRows(_ rows: [[UInt8]]) -> [Int] {
    rows.indices.filter { index in rows[index].contains { $0 > 0 } }
}

/// One of the maintainer's drawings (`docs/brand/source`): its size and which pixels are dark, row by row from the top.
private func drawing(_ file: String) -> (width: Int, height: Int, dark: [Bool])? {
    let url = repositoryRoot.appendingPathComponent("docs/brand/source/\(file)")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let width = image.width, height = image.height
    var gray = [UInt8](repeating: 255, count: width * height)
    let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    return drawn ? (width, height, gray.map { $0 < 128 }) : nil
}

/// The shapes drawn white on black into a `width` x `height` bitmap at the place of the drawing they were traced from (through
/// `drawingTransform`, no fitting of any kind). Returns which pixels are filled, row by row from the top.
private func render(_ shapes: LidGlyph.Shapes, width: Int, height: Int) -> [Bool]? {
    var gray = [UInt8](repeating: 0, count: width * height)
    let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return false }
        // The drawing's y axis points down and the bitmap's up, with the first memory row at the top: flip, after the transform.
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height))
        context.concatenate(shapes.drawingTransform.concatenating(flip))
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(shapes.body)
        context.fillPath(using: .winding)
        if let dot = shapes.dot {
            context.addPath(dot)
            context.fillPath(using: .winding)
        }
        return true
    }
    return drawn ? gray.map { $0 > 127 } : nil
}

func runGlyphTests() {
    let idle = LidGlyph.shapes(for: .idle)
    let active = LidGlyph.shapes(for: .active)
    let warning = LidGlyph.shapes(for: .warning)
    let states: [(GlyphState, LidGlyph.Shapes)] = [(.idle, idle), (.active, active), (.warning, warning)]

    // One placement for the three drawings: the base is 1000 units long and starts at the origin in every state, and the feet
    // reach about the same depth below it. Only the lid differs.
    for (state, shapes) in states {
        expect(abs(shapes.bodyBounds.minX) < 5, "\(state): the hinge end of the base is at the origin")
        expect(abs(shapes.bodyBounds.maxX - 1000) < 5, "\(state): the base is 1000 units long")
        expect(shapes.bodyBounds.minY > -72 && shapes.bodyBounds.minY < -56, "\(state): the feet reach 56 to 72 units below the base")
    }
    expect(active.bodyBounds.height > idle.bodyBounds.height * 2, "the open lid rises well above the closed one")
    expect(idle.dot == nil && active.dot == nil && warning.dot != nil, "only the warning state carries a dot")

    // Each laptop is four closed outlines: the lid, the base, and the two ports (wound the other way, so they are holes).
    for (state, shapes) in states {
        var outlines = 0
        shapes.body.applyWithBlock { element in if element.pointee.type == .moveToPoint { outlines += 1 } }
        expect(outlines == 4, "\(state): the laptop is the lid, the base and two port holes (found \(outlines) outlines)")
    }

    // The dot is round, floats clear of the lid, and sits above and beyond its tip.
    if let dot = warning.dot {
        let box = dot.boundingBoxOfPath
        expect(abs(box.width - box.height) < 4 && box.width > 50, "the dot is a circle")
        expect(warning.body.intersection(dot).isEmpty, "the dot does not touch the lid")
        expect(box.minY > warning.bodyBounds.maxY - 10, "the dot sits above the tip of the lid")
        expect(box.maxX > 1000, "the dot reaches beyond the end of the base")
    }

    // The shipped outlines are the drawings: drawn at the place they were traced from, each agrees with its JPEG on at least 99 %
    // of the pixels that either of them fills (the tracer measured 99.3 to 99.5 %; the rest is the JPEG's own noise).
    let files: [(GlyphState, String)] = [(.idle, "chiuso.jpeg"), (.active, "aperto.jpeg"), (.warning, "aperto con pallino.jpeg")]
    for (state, file) in files {
        guard let photo = drawing(file), let filled = render(LidGlyph.shapes(for: state), width: photo.width, height: photo.height) else {
            expect(false, "\(state): \(file) can be read from docs/brand/source and compared with the outline")
            continue
        }
        var both = 0, either = 0
        photo.dark.withUnsafeBufferPointer { dark in
            filled.withUnsafeBufferPointer { drawn in
                for index in 0..<(photo.width * photo.height) {
                    if dark[index] && drawn[index] { both += 1 }
                    if dark[index] || drawn[index] { either += 1 }
                }
            }
        }
        let overlap = either > 0 ? Double(both) / Double(either) : 0
        expect(overlap > 0.99, "\(state): the outline matches \(file) (overlap \(String(format: "%.4f", overlap)))")
    }

    // The SVG is well-formed and has one path per shape.
    for state in GlyphState.allCases {
        let svg = Glyph.svg(state: state)
        let parser = XMLParser(data: Data(svg.utf8))
        expect(parser.parse(), "\(state): SVG is well-formed XML")
        let paths = svg.components(separatedBy: "<path ").count - 1
        expect(paths == (state == .warning ? 2 : 1), "\(state): SVG has \(state == .warning ? 2 : 1) path(s)")
        expect(svg.contains("viewBox=") && !svg.contains("nan") && !svg.contains("inf"), "\(state): SVG has a finite viewBox")
    }

    // Menu bar image: one canvas for all three states, a template.
    var occupied: [GlyphState: [Int]] = [:]
    for state in GlyphState.allCases {
        let image = Glyph.menuBarImage(state: state)
        expect(image.size == Glyph.menuBarSize && image.isTemplate, "\(state): menu bar image is a template of the shared size")
        guard let rows = alphaRows(Glyph.menuBarPNG(state: state, scale: 2)), rows.count == 32, rows.first?.count == 48 else {
            expect(false, "\(state): menu bar PNG is 48 x 32 pixels at 2x")
            continue
        }
        // Nothing is cut off at the border of the canvas: a pixel on the border is at most partly covered by an edge that ends
        // inside it, never filled solid.
        let edges = rows.first! + rows.last! + rows.map { $0[0] } + rows.map { $0[47] }
        expect(edges.allSatisfy { $0 < 128 }, "\(state): the menu bar mark stays inside its canvas")
        occupied[state] = inkRows(rows)
        let columns = (0..<48).filter { column in rows.contains { $0[column] > 0 } }
        expect((columns.last ?? 0) - (columns.first ?? 0) >= 42, "\(state): the menu bar mark is about the full width of its canvas")
    }

    // The closed mark is short and sits in the middle of the bar; the open ones are taller, the warning one tallest (its dot).
    if let closed = occupied[.idle], let open = occupied[.active], let dotted = occupied[.warning], let top = closed.first, let bottom = closed.last {
        expect(abs(top - (31 - bottom)) <= 1, "the closed mark is vertically centred in the menu bar canvas")
        expect(closed.count < open.count && open.count < dotted.count, "the menu bar marks grow from closed to open to open with the dot")
    } else {
        expect(false, "the menu bar marks could be measured")
    }

    // The warning dot appears in the top-right corner, which the other states leave empty.
    if let open = alphaRows(Glyph.menuBarPNG(state: .active, scale: 2)), let dotted = alphaRows(Glyph.menuBarPNG(state: .warning, scale: 2)) {
        let corner = { (rows: [[UInt8]]) in rows[0..<9].flatMap { $0[36..<48] }.filter { $0 > 0 }.count }
        expect(corner(open) == 0 && corner(dotted) >= 6, "the dot appears in the top-right corner of the warning mark only")
    } else {
        expect(false, "active and warning menu bar PNGs could be read")
    }

    // App icon: opaque tile in the middle, transparent margin around it.
    for size in [64, 256] {
        if let rows = alphaRows(Glyph.appIconPNG(state: .active, pixelSize: size)) {
            expect(rows[0][0] == 0 && rows[size / 2][size / 2] == 255, "app icon \(size) px has a transparent margin and an opaque tile")
        } else {
            expect(false, "app icon \(size) px could be read")
        }
    }
}
