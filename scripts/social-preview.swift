// Draws the picture GitHub shows when a link to the repository is shared: 1280 x 640 pixels, flat colours, no effects.
//
//   social-preview PANEL.png OUT.png
//
// Run it through scripts/social-preview.sh. The mark is the traced outline from HalfLidCore (the maintainer's drawing, nothing
// redrawn), in the colours of docs/BRAND.md; the panel is a picture made by scripts/screenshots.sh. The script stops with an
// error if a line of text would not fit its column, so a change of wording cannot silently cut a word off.
import AppKit
import CoreGraphics
import CoreText
import HalfLidCore
import ImageIO
import UniformTypeIdentifiers

let canvasWidth = 1280
let canvasHeight = 640
let margin: CGFloat = 88

// Colours: docs/BRAND.md (graphite and off-white), and the off-white at lower strength for the smaller lines. The strengths are
// chosen so the smallest text still has a contrast of about 5:1 against the graphite.
func srgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}
let graphite = srgb(0x25272A)
let offWhite = srgb(0xF0EDE6)
let secondary = srgb(0xB3B2AE)
let tertiary = srgb(0x95948F)
let hairline = srgb(0xF0EDE6, alpha: 0.18)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("social-preview: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else { fail("usage: social-preview PANEL.png OUT.png") }
let panelURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let panelSource = CGImageSourceCreateWithURL(panelURL as CFURL, nil),
      let panel = CGImageSourceCreateImageAtIndex(panelSource, 0, nil) else {
    fail("cannot read \(panelURL.path)")
}
guard let space = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: canvasWidth, height: canvasHeight, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      ) else {
    fail("cannot create the bitmap")
}
// Flat text on a flat colour: no sub-pixel smoothing, which would leave coloured fringes in a picture that is shown everywhere.
context.setAllowsFontSmoothing(false)
context.setShouldSmoothFonts(false)
context.interpolationQuality = .high

context.setFillColor(graphite)
context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

// MARK: right column, the panel

let panelWidth: CGFloat = 392
let panelHeight = (panelWidth * CGFloat(panel.height) / CGFloat(panel.width)).rounded()
let panelRect = CGRect(
    x: CGFloat(canvasWidth) - margin - panelWidth, y: ((CGFloat(canvasHeight) - panelHeight) / 2).rounded(),
    width: panelWidth, height: panelHeight
)
let corner: CGFloat = 18
context.saveGState()
context.addPath(CGPath(roundedRect: panelRect, cornerWidth: corner, cornerHeight: corner, transform: nil))
context.clip()
context.draw(panel, in: panelRect)
context.restoreGState()
context.setStrokeColor(hairline)
context.setLineWidth(1.5)
context.addPath(CGPath(roundedRect: panelRect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: corner, cornerHeight: corner, transform: nil))
context.strokePath()

// MARK: left column

let columnWidth = panelRect.minX - margin - 56

func line(_ text: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, kern: CGFloat = 0) -> CTLine {
    let font = NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        NSAttributedString.Key(kCTKernAttributeName as String): kern,
    ]
    return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
}

/// Draws one line with its baseline at `y`. The ink, not the text box, starts at the margin: a font leaves a little room
/// before its first letter, which would push a large title visibly to the right of the mark above it.
func draw(_ text: String, size: CGFloat, weight: NSFont.Weight, color: CGColor, kern: CGFloat = 0, baseline y: CGFloat) {
    let typeset = line(text, size: size, weight: weight, color: color, kern: kern)
    context.textPosition = .zero // the bounds are measured from wherever the previous line left the text position
    let ink = CTLineGetImageBounds(typeset, context)
    if ink.width > columnWidth { fail("\"\(text)\" is \(Int(ink.width)) pixels wide, the column has \(Int(columnWidth))") }
    context.textPosition = CGPoint(x: margin - ink.minX, y: y)
    CTLineDraw(typeset, context)
}

// The stack, top to bottom (y grows upwards in this context): mark, name, tagline, small print. Its height is worked out from
// the pieces so the whole block sits in the middle of the picture, level with the panel.
let shapes = LidGlyph.shapes(for: .active)
let markInk = shapes.body.boundingBox // the tight box: `bodyBounds` also counts the control points of the curves
let markWidth: CGFloat = 384
let markScale = markWidth / markInk.width
let markHeight = markInk.height * markScale

let nameSize: CGFloat = 118
let taglineSize: CGFloat = 34
let taglineLeading: CGFloat = 46
let smallSize: CGFloat = 20

let gapAfterMark: CGFloat = 40
let gapAfterName: CGFloat = 30
let gapAfterTagline: CGFloat = 54
let nameHeight = nameSize * 0.72 // cap height of the system font
let taglineHeight = taglineLeading + taglineSize * 0.72
let smallHeight = smallSize * 0.72
let stackHeight = markHeight + gapAfterMark + nameHeight + gapAfterName + taglineHeight + gapAfterTagline + smallHeight
var cursor = ((CGFloat(canvasHeight) + stackHeight) / 2).rounded() // top of the stack

// Mark: placed by its bounds, filled with the non-zero rule as the app does.
context.saveGState()
context.translateBy(x: margin, y: cursor - markHeight)
context.scaleBy(x: markScale, y: markScale)
context.translateBy(x: -markInk.minX, y: -markInk.minY)
context.setFillColor(offWhite)
context.addPath(shapes.body)
context.fillPath(using: .winding)
context.restoreGState()
cursor -= markHeight + gapAfterMark

draw("Half Lid", size: nameSize, weight: .semibold, color: offWhite, kern: -2.2, baseline: cursor - nameHeight)
cursor -= nameHeight + gapAfterName

draw("Keeps your Mac working with the lid closed", size: taglineSize, weight: .regular, color: secondary, baseline: cursor - taglineSize * 0.72)
draw("while your coding agents do.", size: taglineSize, weight: .regular, color: secondary, baseline: cursor - taglineSize * 0.72 - taglineLeading)
cursor -= taglineHeight + gapAfterTagline

draw("macOS menu bar app. No account, no network, no admin password. MIT.", size: smallSize, weight: .regular, color: tertiary, baseline: cursor - smallHeight)

// MARK: write

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("cannot create \(outputURL.path)")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fail("cannot write \(outputURL.path)") }
