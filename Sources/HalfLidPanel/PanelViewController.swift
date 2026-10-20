import AppKit
import HalfLidCore

/// A flat, rounded colour block (status tile, activity dot). The colour is resolved against the view's own appearance, so it
/// follows light and dark mode and accessibility settings.
private final class ColorView: NSView {
    var fill: NSColor { didSet { needsDisplay = true } }
    var radius: CGFloat { didSet { needsDisplay = true } }

    init(fill: NSColor, radius: CGFloat) {
        self.fill = fill
        self.radius = radius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill() // resolved with this view's appearance while drawing
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }
}

/// The quick-actions panel shown from the menu bar icon: what Half Lid is doing, a duration to keep the Mac awake, the watched
/// agents, and the way into the settings window. Built when the panel opens and dropped when it closes, so it holds no memory
/// while closed. Plain AppKit (no SwiftUI): it opens at once and costs almost nothing.
final class PanelViewController: NSViewController {
    struct Actions {
        /// Minutes to keep the Mac awake; `0` means until the user stops it.
        var hold: (_ minutes: Int) -> Void
        var stopHold: () -> Void
        var setWatching: (_ agentId: String, _ on: Bool) -> Void
        var openSettings: () -> Void
        var dismissHint: () -> Void
        var quit: () -> Void
    }

    /// Called when the content changes the height the panel needs, so its window can follow.
    var onResize: ((NSSize) -> Void)?

    static let width: CGFloat = 320
    private static let inset: CGFloat = 16
    private static let contentWidth = width - 2 * inset

    private let catalog: Catalog
    private let definitions: [String: AgentDefinition]
    private let resources: URL?
    private let actions: Actions
    private(set) var content: PanelContent
    private let root = NSStackView()

    /// Minutes for the duration choices, in the order of the segments (the last one, `0`, is "until I stop it").
    private static let holdChoices = [30, 60, 120, 240, 0]

    init(content: PanelContent, catalog: Catalog, agents: AgentCatalog, resources: URL?, actions: Actions) {
        self.content = content
        self.catalog = catalog
        self.definitions = Dictionary(uniqueKeysWithValues: agents.agents.map { ($0.id, $0) })
        self.resources = resources
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 14, left: Self.inset, bottom: 8, right: Self.inset)
        root.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.widthAnchor.constraint(equalToConstant: Self.width),
        ])
        view = container
        rebuild()
    }

    /// Shows new content. Does nothing when it is identical, so a periodic refresh never disturbs a control under the pointer.
    func apply(_ newContent: PanelContent) {
        guard newContent != content else { return }
        content = newContent
        rebuild()
    }

    // MARK: layout

    private func rebuild() {
        for subview in root.arrangedSubviews {
            root.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }
        add(appBar())
        if let hint = content.hint { add(hintStrip(hint)) }
        add(header())
        add(divider())
        add(holdSection())
        add(divider())
        add(agentsSection())
        if let line = content.sessionLine {
            add(divider())
            add(caption(line))
        }
        add(divider())
        add(footer())

        root.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.width, height: root.fittingSize.height)
        let changed = size != preferredContentSize
        preferredContentSize = size
        view.setFrameSize(size)
        if changed { onResize?(size) }
    }

    private func add(_ child: NSView) {
        root.addArrangedSubview(child)
        child.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
    }

    private func divider() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 2
        return label
    }

    // MARK: app bar

    /// The name of the app on the left and the way into the settings window on the right, so it is always clear what this
    /// panel belongs to.
    private func appBar() -> NSView {
        let name = NSTextField(labelWithString: catalog.text("app.name"))
        name.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        name.textColor = .secondaryLabelColor
        name.setAccessibilityRole(.staticText)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let settings = iconButton(symbol: "gearshape", label: catalog.text("menu.settings"), key: ",", action: #selector(openSettings))
        let row = NSStackView(views: [name, spacer, settings])
        row.orientation = .horizontal
        row.alignment = .centerY
        return row
    }

    // MARK: first-run welcome

    /// A short explanation shown once, the first time the panel opens: what the app does and how to dismiss this note.
    private func hintStrip(_ hint: PanelContent.Hint) -> NSView {
        let padding: CGFloat = 10
        let text = NSTextField(wrappingLabelWithString: hint.text)
        text.font = NSFont.preferredFont(forTextStyle: .callout)
        text.textColor = .labelColor
        text.maximumNumberOfLines = 0
        text.preferredMaxLayoutWidth = Self.contentWidth - 2 * padding
        let dismiss = NSButton(title: hint.dismissLabel, target: self, action: #selector(dismissHint))
        dismiss.bezelStyle = .rounded
        dismiss.controlSize = .small
        let stack = NSStackView(views: [text, dismiss])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let box = ColorView(fill: .quaternaryLabelColor, radius: 8)
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        return box
    }

    @objc private func dismissHint() {
        actions.dismissHint()
    }

    // MARK: status

    private func header() -> NSView {
        let tintedTile: NSColor
        let glyphTint: NSColor
        switch content.glyph {
        case .idle:
            tintedTile = .quaternaryLabelColor
            glyphTint = .labelColor
        case .active:
            tintedTile = .controlAccentColor
            glyphTint = .alternateSelectedControlTextColor
        case .warning:
            tintedTile = .systemOrange
            glyphTint = .black
        }
        let tile = ColorView(fill: tintedTile, radius: 9)
        let glyph = NSImageView(image: Glyph.menuBarImage(state: content.glyph))
        glyph.contentTintColor = glyphTint
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.setAccessibilityElement(false)
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 38),
            tile.heightAnchor.constraint(equalToConstant: 38),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 24),
            glyph.heightAnchor.constraint(equalToConstant: 24),
        ])

        let titleSize = NSFont.preferredFont(forTextStyle: .title3).pointSize
        let title = NSTextField(wrappingLabelWithString: content.title)
        title.font = NSFont.systemFont(ofSize: titleSize, weight: .semibold)
        title.maximumNumberOfLines = 2
        let texts = NSStackView(views: [title])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 2
        if let detail = content.detail { texts.addArrangedSubview(caption(detail)) }

        let row = NSStackView(views: [tile, texts])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    // MARK: keep awake

    private func holdSection() -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6

        if content.holding {
            let stop = NSButton(title: catalog.text("menu.keepAwake.stop"), target: self, action: #selector(stopHold))
            stop.bezelStyle = .rounded
            section.addArrangedSubview(stop)
            stop.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
            return section
        }

        section.addArrangedSubview(caption(catalog.text("panel.holdLabel")))
        let labels = [
            catalog.text("duration.minutes", ["m": "30"]), catalog.text("panel.chip.hours", ["h": "1"]),
            catalog.text("panel.chip.hours", ["h": "2"]), catalog.text("panel.chip.hours", ["h": "4"]), "",
        ]
        let choices = NSSegmentedControl(labels: labels, trackingMode: .momentary, target: self, action: #selector(holdChosen(_:)))
        choices.segmentDistribution = .fillEqually
        let untilStopped = catalog.text("menu.keepAwake.untilStopped")
        choices.setImage(NSImage(systemSymbolName: "infinity", accessibilityDescription: untilStopped), forSegment: 4)
        (choices.cell as? NSSegmentedCell)?.setToolTip(untilStopped, forSegment: 4)
        choices.setAccessibilityLabel(catalog.text("menu.keepAwake"))
        section.addArrangedSubview(choices)
        choices.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return section
    }

    @objc private func holdChosen(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard Self.holdChoices.indices.contains(index) else { return }
        actions.hold(Self.holdChoices[index])
    }

    @objc private func stopHold() {
        actions.stopHold()
    }

    // MARK: agents

    private func agentsSection() -> NSView {
        let section = NSStackView()
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4
        section.addArrangedSubview(caption(catalog.text("panel.agents")))
        for agent in content.agents {
            let row = agentRow(agent)
            section.addArrangedSubview(row)
            row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }
        return section
    }

    private func agentRow(_ agent: PanelContent.AgentRow) -> NSView {
        let name = NSTextField(labelWithString: agent.name)
        name.font = NSFont.preferredFont(forTextStyle: .body)
        name.textColor = agent.watched ? .labelColor : .secondaryLabelColor
        name.lineBreakMode = .byTruncatingTail
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let state = NSTextField(labelWithString: agent.stateText)
        state.font = NSFont.preferredFont(forTextStyle: .footnote)
        state.textColor = .secondaryLabelColor
        state.setContentHuggingPriority(.required, for: .horizontal)

        var views: [NSView] = []
        if let definition = definitions[agent.id] {
            let icon = NSImageView(image: AgentIcon.image(for: definition, name: agent.name, side: 22, dimmed: !agent.watched, resources: resources))
            icon.imageScaling = .scaleProportionallyUpOrDown
            icon.setAccessibilityElement(false) // decorative: the row's text already names the agent
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 22), icon.heightAnchor.constraint(equalToConstant: 22),
            ])
            views.append(icon)
        }
        views.append(name)
        if agent.state == .working {
            let dot = ColorView(fill: .systemGreen, radius: 4)
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
            dot.setAccessibilityElement(false)
            views.append(dot)
        }
        views.append(state)

        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = agent.watched ? .on : .off
        toggle.target = self
        toggle.action = #selector(watchToggled(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier(agent.id)
        toggle.setAccessibilityLabel(catalog.text("panel.watch", ["agent": agent.name]))
        views.append(toggle)

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill // the name stretches, so the state and the switch sit at the right edge
        row.spacing = 8
        row.setCustomSpacing(6, after: name)
        row.setAccessibilityElement(false)
        return row
    }

    @objc private func watchToggled(_ sender: NSSwitch) {
        guard let id = sender.identifier?.rawValue else { return }
        actions.setWatching(id, sender.state == .on)
    }

    // MARK: footer

    /// Quit sits alone at the bottom: this app has no Dock icon and no menu bar of its own, so this is the way out.
    private func footer() -> NSView {
        let label = catalog.text("menu.quit")
        let quit = NSButton(title: label, target: self, action: #selector(quitApp))
        quit.bezelStyle = .accessoryBarAction
        quit.showsBorderOnlyWhileMouseInside = true
        quit.font = NSFont.preferredFont(forTextStyle: .footnote)
        quit.contentTintColor = .secondaryLabelColor
        quit.toolTip = label
        quit.setAccessibilityLabel(label)
        quit.keyEquivalent = "q"
        quit.keyEquivalentModifierMask = .command
        let hint = NSTextField(labelWithString: "\u{2318}Q")
        hint.font = NSFont.preferredFont(forTextStyle: .footnote)
        hint.textColor = .tertiaryLabelColor
        hint.setAccessibilityElement(false)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, quit, hint])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        return row
    }

    private func iconButton(symbol: String, label: String, key: String, action: Selector) -> NSButton {
        let button = NSButton(
            image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(), target: self, action: action
        )
        button.title = "" // icon only; the label below is what VoiceOver and the tooltip use
        button.bezelStyle = .accessoryBarAction
        button.showsBorderOnlyWhileMouseInside = true
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.keyEquivalent = key
        button.keyEquivalentModifierMask = .command
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 24),
        ])
        return button
    }

    @objc private func openSettings() {
        actions.openSettings()
    }

    @objc private func quitApp() {
        actions.quit()
    }

    // MARK: description (used by `HalfLidPanel --print`)

    /// The panel as plain text, one line per element in reading order, for a command-line check of what it shows.
    func describe() -> [String] {
        loadViewIfNeeded()
        var lines: [String] = []
        walk(view, into: &lines)
        return lines
    }

    private func walk(_ view: NSView, into lines: inout [String]) {
        switch view {
        case let field as NSTextField:
            lines.append(field.stringValue)
        case let switchControl as NSSwitch:
            lines.append((switchControl.state == .on ? "(on) " : "(off) ") + (switchControl.accessibilityLabel() ?? ""))
        case let segmented as NSSegmentedControl:
            let names = (0..<segmented.segmentCount).map { index -> String in
                let label = segmented.label(forSegment: index) ?? ""
                return label.isEmpty ? ((segmented.cell as? NSSegmentedCell)?.toolTip(forSegment: index) ?? "?") : label
            }
            lines.append("[" + names.joined(separator: " | ") + "]")
        case let button as NSButton:
            lines.append("button: " + (button.title.isEmpty ? (button.accessibilityLabel() ?? "?") : button.title))
        case is NSBox:
            lines.append("---")
        default:
            for child in view.subviews { walk(child, into: &lines) }
        }
    }
}
