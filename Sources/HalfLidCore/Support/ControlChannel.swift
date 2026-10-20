import Darwin
import Foundation

/// A request to the running menu bar app, from the command line (`halflid start`, `halflid stop`) or from the settings window.
public enum ControlCommand: Equatable, Sendable {
    /// Keep the Mac awake for this many minutes, or until stopped when `nil`.
    case start(minutes: Int?)
    case stop
    /// From the settings window. The login item and the notification permission belong to the menu bar app, so it is the one
    /// that has to change them; the settings window reads the result from the published status.
    case setOpenAtLogin(Bool)
    /// Shows the system's permission prompt if it has not been answered yet.
    case requestNotificationAccess
    case sendTestNotification
    /// Reads the login item and the notification permission again and publishes them.
    case refreshSystemAccess

    public static let notificationName = Notification.Name("io.github.fedebartoli.halflid.control")

    /// Commands that someone can type in a terminal or put in a script, and that the user can switch off in the settings.
    public var isFromCommandLine: Bool {
        switch self {
        case .start, .stop: return true
        case .setOpenAtLogin, .requestNotificationAccess, .sendTestNotification, .refreshSystemAccess: return false
        }
    }

    /// Property-list values only: this travels through the system's distributed notification center.
    public var userInfo: [String: Any] {
        switch self {
        case .start(let minutes):
            var info: [String: Any] = ["verb": "start"]
            if let minutes { info["minutes"] = minutes }
            return info
        case .stop:
            return ["verb": "stop"]
        case .setOpenAtLogin(let enabled):
            return ["verb": "openAtLogin", "enabled": enabled]
        case .requestNotificationAccess:
            return ["verb": "notificationAccess"]
        case .sendTestNotification:
            return ["verb": "testNotification"]
        case .refreshSystemAccess:
            return ["verb": "refreshSystemAccess"]
        }
    }

    /// `nil` for anything that is not a well-formed command. A timed start must be between one minute and one week.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let verb = userInfo?["verb"] as? String else { return nil }
        switch verb {
        case "stop":
            self = .stop
        case "start":
            guard let raw = userInfo?["minutes"] else {
                self = .start(minutes: nil)
                return
            }
            guard let minutes = (raw as? NSNumber)?.intValue, (1...10_080).contains(minutes) else { return nil }
            self = .start(minutes: minutes)
        case "openAtLogin":
            guard let enabled = (userInfo?["enabled"] as? NSNumber)?.boolValue else { return nil }
            self = .setOpenAtLogin(enabled)
        case "notificationAccess":
            self = .requestNotificationAccess
        case "testNotification":
            self = .sendTestNotification
        case "refreshSystemAccess":
            self = .refreshSystemAccess
        default:
            return nil
        }
    }
}

public enum ControlChannel {
    /// `HALFLID_NO_CONTROL` set to anything: the program sends nothing. The distributed notification center is shared by the
    /// whole Mac, so a settings window that runs against sample files (`scripts/screenshots.sh`) would otherwise be heard by the
    /// real menu bar app.
    public static func isMuted(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["HALFLID_NO_CONTROL"] != nil
    }

    public static func send(_ command: ControlCommand) {
        guard !isMuted() else { return }
        DistributedNotificationCenter.default().postNotificationName(
            ControlCommand.notificationName, object: nil, userInfo: command.userInfo, deliverImmediately: true
        )
    }

    /// The returned object keeps the registration alive; pass it to `stopObserving` (or drop it with the process).
    public static func observe(_ handler: @escaping (ControlCommand) -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: ControlCommand.notificationName, object: nil, queue: .main
        ) { note in
            if let command = ControlCommand(userInfo: note.userInfo) { handler(command) }
        }
    }

    public static func stopObserving(_ token: NSObjectProtocol) {
        DistributedNotificationCenter.default().removeObserver(token)
    }
}

/// What the running app publishes about itself, for `halflid status` and for the settings window. Holds no chat content, no
/// paths and no agent output: only what the menu already shows, and what the system says about the login item and the
/// notification permission.
public struct PublishedStatus: Codable, Equatable, Sendable {
    public var pid: Int32
    public var armed: Bool
    /// `idle`, `active` or `warning`.
    public var indicator: String
    public var title: String
    public var detail: String?
    /// "Held until 15:42" while a manual keep-awake is active.
    public var holdText: String?
    /// A manual hold with an end time.
    public var holdUntil: Date?
    public var holdUntilStopped: Bool
    /// Why the last session was stopped by a safety limit, while that limit still applies.
    public var latch: String?
    public var workingAgents: [String]
    /// The system's answers for the settings window. `nil` until the settings window has asked for them: the menu bar app does
    /// not look them up on its own, so it costs nothing while the window is closed.
    public var openAtLogin: LoginItemState?
    /// Why the last attempt to change the login item failed, in the system's words.
    public var openAtLoginError: String?
    public var notificationAccess: NotificationAccessState?

    public init(
        pid: Int32, armed: Bool, indicator: String, title: String, detail: String? = nil, holdText: String? = nil,
        holdUntil: Date? = nil, holdUntilStopped: Bool = false, latch: String? = nil, workingAgents: [String] = [],
        openAtLogin: LoginItemState? = nil, openAtLoginError: String? = nil, notificationAccess: NotificationAccessState? = nil
    ) {
        self.pid = pid
        self.armed = armed
        self.indicator = indicator
        self.title = title
        self.detail = detail
        self.holdText = holdText
        self.holdUntil = holdUntil
        self.holdUntilStopped = holdUntilStopped
        self.latch = latch
        self.workingAgents = workingAgents
        self.openAtLogin = openAtLogin
        self.openAtLoginError = openAtLoginError
        self.notificationAccess = notificationAccess
    }
}

public enum StatusFile {
    public static var defaultPath: String {
        if let override = ProcessInfo.processInfo.environment["HALFLID_STATUS"], !override.isEmpty { return override }
        return NSString(string: "~/Library/Application Support/HalfLid/status.json").expandingTildeInPath
    }

    public static func write(_ status: PublishedStatus, path: String = defaultPath) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(status) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }

    /// The published status, or `nil` when there is none or the process that wrote it is gone (a crash leaves the file behind).
    public static func read(path: String = defaultPath) -> PublishedStatus? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let status = try? decoder.decode(PublishedStatus.self, from: data), isAlive(status.pid) else { return nil }
        return status
    }

    public static func remove(path: String = defaultPath) {
        try? FileManager.default.removeItem(atPath: path)
    }

    static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
