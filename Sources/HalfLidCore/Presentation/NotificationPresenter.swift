import Foundation

/// Something worth telling the user about outside the panel.
public enum NotificationEvent: Equatable, Sendable {
    /// Half Lid stopped keeping the Mac awake to protect it.
    case stopped(StopReason)
    /// A safety limit is close.
    case warning(WarningKind)
    /// A timed "keep awake" ends soon.
    case holdEnding
    /// The work finished and everything went back to normal.
    case workFinished(durationSeconds: Double)

    public init(_ notice: Notice) {
        switch notice {
        case .stopped(let reason): self = .stopped(reason)
        case .warning(let kind): self = .warning(kind)
        }
    }
}

public struct NotificationText: Equatable, Sendable {
    public var title: String
    public var body: String
}

/// Turns events into notification text and decides which ones the user asked for. Pure, so it is tested without a
/// notification center.
public enum NotificationPresenter {
    /// How long before a timed hold ends the user is told.
    public static let holdWarningSeconds: TimeInterval = 5 * 60

    public static func isWanted(_ event: NotificationEvent, by preferences: NotificationPreferences) -> Bool {
        guard preferences.enabled else { return false }
        switch event {
        case .stopped: return preferences.onStop
        case .warning: return preferences.onWarning
        case .holdEnding: return preferences.onHoldEnding
        case .workFinished: return preferences.onWorkFinished
        }
    }

    /// One identifier per kind of event: a newer notice of the same kind replaces the older one instead of piling up.
    public static func identifier(for event: NotificationEvent) -> String {
        switch event {
        case .stopped: return "halflid.stopped"
        case .warning(let kind): return "halflid.warning.\(kind.rawValue)"
        case .holdEnding: return "halflid.holdEnding"
        case .workFinished: return "halflid.workFinished"
        }
    }

    public static func text(for event: NotificationEvent, catalog: Catalog) -> NotificationText {
        switch event {
        case .stopped(let reason):
            return NotificationText(title: catalog.text("status.stopped"), body: catalog.text("status.stopped.\(reason.rawValue)"))
        case .warning(let kind):
            return NotificationText(title: catalog.text("status.warning"), body: catalog.text("notify.warning.\(kind.rawValue)"))
        case .holdEnding:
            return NotificationText(title: catalog.text("notify.holdEnding.title"), body: catalog.text("notify.holdEnding.body"))
        case .workFinished(let seconds):
            return NotificationText(
                title: catalog.text("notify.workFinished.title"),
                body: catalog.text("notify.workFinished.body", ["duration": StatusPresenter.duration(seconds, catalog: catalog)])
            )
        }
    }
}
