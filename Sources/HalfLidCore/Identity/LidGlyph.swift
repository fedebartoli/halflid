import CoreGraphics
import Foundation

/// The Half Lid mark: three drawings of a laptop seen from the side, the lid closed, open, and open with a dot beyond its tip.
///
/// They are the maintainer's drawings (`docs/brand/source`), traced to vector outlines by `docs/brand/trace-marks.py` and kept
/// as they are: nothing here redraws, simplifies or rebuilds them. The outlines live in `LidMarks`; this type only places them.
///
/// Placement: every state is scaled so that its base is 1000 units long and positioned with the top-left corner of the base at
/// the origin (x to the right, y up, the base below the origin), so the three states share the same base in the same place and
/// only the lid moves.
public enum LidGlyph {
    public struct Shapes {
        /// Base and lid, filled with the non-zero winding rule (the ports are wound the other way and read as holes).
        public let body: CGPath
        /// The dot of the warning state, separate so callers may colour it differently.
        public let dot: CGPath?
        /// Bounds of `body` alone.
        public let bodyBounds: CGRect
        /// Maps `body` and `dot` back onto the pixels of the maintainer's drawing (y pointing down). The tests use it to hold the
        /// outlines to the drawings in `docs/brand/source`.
        public let drawingTransform: CGAffineTransform

        /// Everything that is drawn.
        public var bounds: CGRect { dot.map { bodyBounds.union($0.boundingBoxOfPath) } ?? bodyBounds }
    }

    /// Width, in the same units, of the menu bar canvas: the base takes 22.5 of its 24 points and the rest is room for the dot.
    public static let menuBarDesignWidth: CGFloat = 1000 * 24 / 22.5

    public static func shapes(for state: GlyphState) -> Shapes {
        switch state {
        case .idle: return closed
        case .active: return open
        case .warning: return openWithDot
        }
    }

    private static let closed = build(LidMarks.idle)
    private static let open = build(LidMarks.active)
    private static let openWithDot = build(LidMarks.warning)

    /// Drawing coordinates (pixels of the 1024 drawing, y down) to the mark's own (base length 1000, y up).
    private static func build(_ mark: LidMarks.Mark) -> Shapes {
        let scale = 1000 / mark.base.width
        var placement = CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: -mark.base.minX * scale, ty: mark.base.minY * scale)
        func place(_ data: String) -> CGPath {
            guard let path = SVGShape.parsePath(data), let placed = path.copy(using: &placement) else { return CGMutablePath() }
            return placed
        }
        let body = place(mark.body)
        return Shapes(body: body, dot: mark.dot.map(place), bodyBounds: body.boundingBoxOfPath, drawingTransform: placement.inverted())
    }
}
