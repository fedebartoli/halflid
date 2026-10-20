// Helper of scripts/screenshots.sh, compiled by it on the spot.
//
//   window-id --preflight   exits 0 when this process may capture windows (Screen Recording is allowed), without ever asking.
//   window-id PID           waits up to 15 seconds for the first window of that process that is on screen, then prints
//                           "ID WIDTH HEIGHT INSIDE SCALE" on one line: its window number, its size in points, INSIDE = 1 when
//                           the window lies wholly in the usable area of a screen (below the menu bar, above the Dock) or 0 when
//                           not (macOS shortens a window that is taller than that area, which the script has to notice), and
//                           SCALE, the pixels to the point of the screen it is on (2 on a Retina screen).
//
// The id goes to `screencapture -l`, which then takes a picture of that one window and nothing else on the screen.

import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments

if arguments.count == 2, arguments[1] == "--preflight" {
    exit(CGPreflightScreenCaptureAccess() ? 0 : 1)
}

guard arguments.count == 2, let pid = Int(arguments[1]) else {
    FileHandle.standardError.write(Data("usage: window-id --preflight | window-id PID\n".utf8))
    exit(2)
}

/// Whether a rectangle in window-list coordinates (points, origin at the top left of the main display) lies wholly inside the
/// usable area of one of the screens.
func isInsideAScreen(x: Double, y: Double, width: Double, height: Double) -> Bool {
    // The first screen is the one with the menu bar; the window list measures from its top edge, AppKit from its bottom edge.
    guard let main = NSScreen.screens.first else { return true }
    let mainHeight = Double(main.frame.height)
    for screen in NSScreen.screens {
        let usable = screen.visibleFrame
        let top = mainHeight - Double(usable.maxY)
        let bottom = mainHeight - Double(usable.minY)
        if x >= Double(usable.minX) - 1, x + width <= Double(usable.maxX) + 1, y >= top - 1, y + height <= bottom + 1 {
            return true
        }
    }
    return false
}

/// The pixels to the point of the screen that holds the middle of the rectangle (same coordinates as above).
func scaleOfScreen(x: Double, y: Double, width: Double, height: Double) -> Int {
    guard let main = NSScreen.screens.first else { return 1 }
    let mainHeight = Double(main.frame.height)
    let middle = (x: x + width / 2, y: y + height / 2)
    for screen in NSScreen.screens {
        let frame = screen.frame
        let top = mainHeight - Double(frame.maxY)
        let bottom = mainHeight - Double(frame.minY)
        if middle.x >= Double(frame.minX), middle.x <= Double(frame.maxX), middle.y >= top, middle.y <= bottom {
            return Int(screen.backingScaleFactor.rounded())
        }
    }
    return 1
}

let deadline = Date().addingTimeInterval(15)
while Date() < deadline {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    if let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? Int) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, width > 300,
                  let height = bounds["Height"] as? Double,
                  let number = window[kCGWindowNumber as String] as? Int else { continue }
            let x = bounds["X"] as? Double ?? 0
            let y = bounds["Y"] as? Double ?? 0
            let inside = isInsideAScreen(x: x, y: y, width: width, height: height)
            let scale = scaleOfScreen(x: x, y: y, width: width, height: height)
            print(number, Int(width.rounded()), Int(height.rounded()), inside ? 1 : 0, scale)
            exit(0)
        }
    }
    usleep(100_000)
}
exit(1)
