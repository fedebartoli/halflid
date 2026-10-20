import AppKit

/// The panel's window: borderless, rounded, with the system's popover material, placed just under the menu bar icon. It can
/// take keyboard focus (Esc, Tab, Command-comma) but is not listed anywhere and has no title bar.
final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private static let cornerRadius: CGFloat = 12
    private static let screenMargin: CGFloat = 8

    init(contentViewController controller: NSViewController) {
        super.init(contentRect: NSRect(origin: .zero, size: controller.preferredContentSize), styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none

        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = Self.cornerRadius
        material.layer?.cornerCurve = .continuous
        material.layer?.masksToBounds = true
        contentView = material

        let content = controller.view
        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])
        setContentSize(controller.preferredContentSize)
    }

    /// Puts the panel centred under `anchor` (the menu bar icon, in screen coordinates), kept inside the visible screen.
    func place(below anchor: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var x = anchor.midX - frame.width / 2
        x = min(max(x, visible.minX + Self.screenMargin), visible.maxX - frame.width - Self.screenMargin)
        setFrameTopLeftPoint(NSPoint(x: x, y: min(anchor.minY, visible.maxY) - 6))
    }

    /// Follows a change of content height while keeping the top edge where it is.
    func resize(to size: NSSize) {
        let top = frame.maxY
        let left = frame.minX
        setContentSize(size)
        setFrameTopLeftPoint(NSPoint(x: left, y: top))
    }

    func show() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = reduceMotion ? 1 : 0
        makeKeyAndOrderFront(nil)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                animator().alphaValue = 1
            }
        }
    }
}
