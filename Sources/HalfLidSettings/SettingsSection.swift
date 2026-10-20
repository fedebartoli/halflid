import Foundation

/// The panes of the settings window, in the order of the sidebar.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, agents, lid, safety, notifications, diagnostics, about

    var id: String { rawValue }

    /// Catalog key of the pane's name.
    var titleKey: String { "settings.section.\(rawValue)" }

    /// The system symbol of the pane; nil for the pane about the lid, which carries Half Lid's own mark (the open laptop).
    var symbol: String? {
        switch self {
        case .general: return "gearshape"
        case .agents: return "terminal"
        case .lid: return nil
        case .safety: return "shield"
        case .notifications: return "bell"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}
