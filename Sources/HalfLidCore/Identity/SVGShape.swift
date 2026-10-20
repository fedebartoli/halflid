import CoreGraphics
import Foundation

/// A very small SVG reader, enough for the monochrome marks that stand for the coding agents: a `viewBox` and one or more
/// `<path>` elements, nothing else (no transforms, gradients, strokes or clipping). Anything it cannot read gives `nil`, and
/// the interface then falls back to another kind of icon. Coordinates stay as written in the file (y pointing down).
public struct SVGShape {
    public struct Piece {
        public let path: CGPath
        /// `true` when the element asks for the even-odd rule (holes are then drawn by overlap rather than by direction).
        public let evenOdd: Bool
    }

    public let viewBox: CGRect
    public let pieces: [Piece]

    /// Smallest rectangle that holds every piece, in the file's coordinates.
    public var bounds: CGRect {
        pieces.map { $0.path.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }
    }

    public init?(data: Data) {
        let collector = Collector()
        let parser = XMLParser(data: data)
        parser.delegate = collector
        guard parser.parse() else { return nil }
        let pieces = collector.paths.compactMap { entry -> Piece? in
            SVGShape.parsePath(entry.data).map { Piece(path: $0, evenOdd: entry.evenOdd) }
        }
        guard !pieces.isEmpty, pieces.count == collector.paths.count else { return nil }
        self.pieces = pieces
        viewBox = collector.viewBox ?? pieces.map { $0.path.boundingBoxOfPath }.reduce(CGRect.null) { $0.union($1) }
    }

    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    // MARK: XML

    private final class Collector: NSObject, XMLParserDelegate {
        var viewBox: CGRect?
        var rootEvenOdd = false
        var paths: [(data: String, evenOdd: Bool)] = []

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            switch elementName {
            case "svg":
                rootEvenOdd = attributeDict["fill-rule"] == "evenodd"
                if let box = attributeDict["viewBox"] {
                    let numbers = box.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
                    if numbers.count == 4 { viewBox = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) }
                }
            case "path":
                guard let data = attributeDict["d"] else { return }
                let evenOdd = rootEvenOdd || attributeDict["fill-rule"] == "evenodd" || attributeDict["clip-rule"] == "evenodd"
                paths.append((data, evenOdd))
            default:
                break
            }
        }
    }

    // MARK: path data

    /// Parses the `d` attribute of a path: M L H V C S Q T A Z in absolute and relative forms, with the implicit repeats and
    /// the compact number forms the format allows ("a6 6 0 013-.4", ".5.5").
    public static func parsePath(_ text: String) -> CGPath? {
        var scanner = Scanner2(Array(text.unicodeScalars))
        let path = CGMutablePath()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastCubicControl: CGPoint?
        var lastQuadControl: CGPoint?
        var command: Character?
        var first = true

        while true {
            scanner.skipSeparators()
            if scanner.atEnd { break }
            if let letter = scanner.peekLetter() {
                command = letter
                scanner.advance()
            } else if command == nil {
                return nil
            } else if command == "M" { command = "L" } else if command == "m" { command = "l" } else if command == "Z" || command == "z" { return nil }
            guard let c = command else { return nil }
            if first, c != "M", c != "m" { return nil }
            first = false
            let relative = c.isLowercase
            let origin = relative ? current : .zero

            func number() -> Double? { scanner.number() }
            func point() -> CGPoint? {
                guard let x = number(), let y = number() else { return nil }
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }

            switch Character(c.lowercased()) {
            case "m":
                guard let p = point() else { return nil }
                path.move(to: p)
                current = p
                subpathStart = p
                lastCubicControl = nil
                lastQuadControl = nil
            case "l":
                guard let p = point() else { return nil }
                path.addLine(to: p)
                current = p
                lastCubicControl = nil
                lastQuadControl = nil
            case "h":
                guard let x = number() else { return nil }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadControl = nil
            case "v":
                guard let y = number() else { return nil }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current)
                lastCubicControl = nil
                lastQuadControl = nil
            case "c":
                guard let c1 = point(), let c2 = point(), let end = point() else { return nil }
                path.addCurve(to: end, control1: c1, control2: c2)
                lastCubicControl = c2
                lastQuadControl = nil
                current = end
            case "s":
                guard let c2 = point(), let end = point() else { return nil }
                let c1 = lastCubicControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addCurve(to: end, control1: c1, control2: c2)
                lastCubicControl = c2
                lastQuadControl = nil
                current = end
            case "q":
                guard let control = point(), let end = point() else { return nil }
                path.addQuadCurve(to: end, control: control)
                lastQuadControl = control
                lastCubicControl = nil
                current = end
            case "t":
                guard let end = point() else { return nil }
                let control = lastQuadControl.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                path.addQuadCurve(to: end, control: control)
                lastQuadControl = control
                lastCubicControl = nil
                current = end
            case "a":
                guard let rx = number(), let ry = number(), let rotation = number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let end = point() else { return nil }
                addArc(to: path, from: current, rx: rx, ry: ry, rotationDegrees: rotation, largeArc: large, sweep: sweep, end: end)
                current = end
                lastCubicControl = nil
                lastQuadControl = nil
            case "z":
                path.closeSubpath()
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil
            default:
                return nil
            }
        }
        return path.isEmpty ? nil : path
    }

    /// Adds an elliptical arc as cubic curves (SVG implementation notes, appendix F.6).
    private static func addArc(
        to path: CGMutablePath, from start: CGPoint, rx rawRx: Double, ry rawRy: Double, rotationDegrees: Double,
        largeArc: Bool, sweep: Bool, end: CGPoint
    ) {
        if start == end { return }
        var rx = abs(rawRx), ry = abs(rawRy)
        if rx == 0 || ry == 0 { path.addLine(to: end); return }
        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= lambda.squareRoot(); ry *= lambda.squareRoot() }
        let numerator = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let denominator = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let sign: Double = largeArc == sweep ? -1 : 1
        let coefficient = sign * (max(0, numerator / denominator)).squareRoot()
        let cxPrime = coefficient * (rx * y1 / ry)
        let cyPrime = coefficient * (-ry * x1 / rx)
        let cx = cosPhi * cxPrime - sinPhi * cyPrime + (start.x + end.x) / 2
        let cy = sinPhi * cxPrime + cosPhi * cyPrime + (start.y + end.y) / 2

        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let length = (ux * ux + uy * uy).squareRoot() * (vx * vx + vy * vy).squareRoot()
            var value = acos(max(-1, min(1, dot / length)))
            if ux * vy - uy * vx < 0 { value = -value }
            return value
        }
        let theta1 = angle(1, 0, (x1 - cxPrime) / rx, (y1 - cyPrime) / ry)
        var delta = angle((x1 - cxPrime) / rx, (y1 - cyPrime) / ry, (-x1 - cxPrime) / rx, (-y1 - cyPrime) / ry)
        if !sweep && delta > 0 { delta -= 2 * .pi }
        if sweep && delta < 0 { delta += 2 * .pi }

        let segments = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(segments)
        let t = 4.0 / 3.0 * tan(step / 4)
        func map(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: cx + cosPhi * rx * x - sinPhi * ry * y, y: cy + sinPhi * rx * x + cosPhi * ry * y)
        }
        for index in 0..<segments {
            let a = theta1 + Double(index) * step
            let b = a + step
            path.addCurve(
                to: index == segments - 1 ? end : map(cos(b), sin(b)),
                control1: map(cos(a) - t * sin(a), sin(a) + t * cos(a)),
                control2: map(cos(b) + t * sin(b), sin(b) - t * cos(b))
            )
        }
    }

    /// Reads numbers, flags and separators out of path data.
    private struct Scanner2 {
        private let scalars: [Unicode.Scalar]
        private var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var atEnd: Bool { index >= scalars.count }

        mutating func advance() { index += 1 }

        mutating func skipSeparators() {
            while index < scalars.count, scalars[index] == " " || scalars[index] == "," || scalars[index] == "\n" || scalars[index] == "\t" || scalars[index] == "\r" {
                index += 1
            }
        }

        func peekLetter() -> Character? {
            guard index < scalars.count else { return nil }
            let scalar = scalars[index]
            // "e" and "E" belong to numbers (exponents), never to a command.
            return (scalar.properties.isAlphabetic && scalar != "e" && scalar != "E") ? Character(scalar) : nil
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard index < scalars.count else { return nil }
            defer { index += 1 }
            switch scalars[index] {
            case "0": return false
            case "1": return true
            default: return nil
            }
        }

        mutating func number() -> Double? {
            skipSeparators()
            let start = index
            if index < scalars.count, scalars[index] == "-" || scalars[index] == "+" { index += 1 }
            var digits = 0
            while index < scalars.count, scalars[index].properties.numericType != nil, scalars[index].isASCII { index += 1; digits += 1 }
            if index < scalars.count, scalars[index] == "." {
                index += 1
                while index < scalars.count, scalars[index].properties.numericType != nil, scalars[index].isASCII { index += 1; digits += 1 }
            }
            guard digits > 0 else { index = start; return nil }
            if index < scalars.count, scalars[index] == "e" || scalars[index] == "E" {
                var look = index + 1
                if look < scalars.count, scalars[look] == "-" || scalars[look] == "+" { look += 1 }
                if look < scalars.count, scalars[look].isASCII, scalars[look].properties.numericType != nil {
                    while look < scalars.count, scalars[look].isASCII, scalars[look].properties.numericType != nil { look += 1 }
                    index = look
                }
            }
            return Double(String(String.UnicodeScalarView(scalars[start..<index])))
        }
    }
}
