import Foundation
import HalfLidCore
import ServiceManagement

/// Opening at login, through the system's login-item service. The state is the system's, never stored by Half Lid.
///
/// Only the menu bar app can register itself: the service registers the app that asks. The settings window is another app,
/// so it sends `ControlCommand.setOpenAtLogin` and reads the result from the published status.
enum LoginItem {
    static var state: LoginItemState {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        // An app that was never registered is reported as "not found" as well (seen with ad-hoc signed builds, wherever they
        // are). Registering is how to find out; if the system refuses, its reason is shown to the user.
        case .notFound: return .disabled
        @unknown default: return .unavailable
        }
    }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
