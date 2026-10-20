import AppKit
import HalfLidCore
import SwiftUI

extension Text {
    /// Text from the catalog. `verbatim`, because the catalog (not SwiftUI's own lookup) does the translating.
    @MainActor
    init(_ model: SettingsModel, _ key: String, _ params: [String: String] = [:]) {
        self.init(verbatim: model.text(key, params))
    }
}

struct SettingsRoot: View {
    @Bindable var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 205, max: 260)
        } detail: {
            Detail(model: model)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 500)
        .onAppear { model.startObserving() }
    }
}

// MARK: sidebar

private struct Sidebar: View {
    let model: SettingsModel

    var body: some View {
        List(selection: selection) {
            ForEach(SettingsSection.allCases) { section in
                Label {
                    Text(model, section.titleKey)
                } icon: {
                    if let symbol = section.symbol {
                        Image(systemName: symbol)
                    } else {
                        Image(nsImage: AppIcon.sidebarMark)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 15)
                    }
                }
                .tag(section)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarHeader(model: model)
        }
    }

    private var selection: Binding<SettingsSection?> {
        Binding(get: { model.section }, set: { if let section = $0 { model.section = section } })
    }
}

/// The name and version of the app, at the top of the sidebar: it is always clear whose settings these are.
private struct SidebarHeader: View {
    let model: SettingsModel

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image)
                .resizable()
                .frame(width: 36, height: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(model, "app.name")
                    .font(.headline)
                Text(verbatim: model.versionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

/// The app's own images, drawn from the same traced drawings as the menu bar icon, so they are there even when the window is
/// not run from an installed app.
enum AppIcon {
    /// The app icon (the open laptop, as in the bundle's `AppIcon.icns`).
    static let image: NSImage = {
        if let data = Glyph.appIconPNG(state: .active, pixelSize: 256), let image = NSImage(data: data) { return image }
        return NSApp.applicationIconImage
    }()

    /// The open laptop as a template image, for the sidebar entry about the lid.
    static let sidebarMark: NSImage = Glyph.menuBarImage(state: .active)
}

// MARK: detail

private struct Detail: View {
    let model: SettingsModel

    var body: some View {
        Group {
            switch model.section {
            case .general: GeneralPane(model: model)
            case .agents: AgentsPane(model: model)
            case .lid: LidPane(model: model)
            case .safety: SafetyPane(model: model)
            case .notifications: NotificationsPane(model: model)
            case .diagnostics: DiagnosticsPane(model: model)
            case .about: AboutPane(model: model)
            }
        }
        .navigationTitle(model.text(model.section.titleKey))
    }
}
