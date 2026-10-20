import Foundation

/// Who Half Lid is to macOS. The menu bar app is the one the system knows: the login item, the notification permission and
/// the notifications themselves all belong to it. The settings window is an app of its own with another identity, so it asks
/// the menu bar app to change these (see `ControlCommand`) and reads the answers from the published status.
public enum AppIdentity {
    /// Must match `CFBundleIdentifier` of the menu bar app in `scripts/make-app.sh` (a test checks it).
    public static let menuBarBundleIdentifier = "io.github.fedebartoli.halflid.menubar"
}

/// Whether the system opens Half Lid at login. The system's answer, never stored by Half Lid.
public enum LoginItemState: String, Codable, Equatable, Sendable {
    case enabled
    /// Registered, but the user still has to allow it in System Settings.
    case requiresApproval
    case disabled
    /// Not running from an installed app (a development build), so there is nothing to register.
    case unavailable

    /// The switch is on, whether or not the system still waits for the user's approval.
    public var isOn: Bool { self == .enabled || self == .requiresApproval }
}

/// What macOS allows Half Lid to show as notifications.
public enum NotificationAccessState: String, Codable, Equatable, Sendable {
    /// The permission prompt has not been answered yet.
    case notDetermined
    case allowed
    case denied
    /// Not running from an installed app: the notification center cannot be used.
    case unavailable
    /// The system answered with something this version does not know.
    case unknown
}
