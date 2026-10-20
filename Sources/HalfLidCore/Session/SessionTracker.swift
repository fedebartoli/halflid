import Foundation

/// A finished stretch of keeping the Mac awake, as shown in the menu ("Last session: 1 h 12 min (work finished)").
/// Holds no agent names, paths or chat content: only times and why it ended.
public struct SessionSummary: Codable, Equatable, Sendable {
    public enum Ending: String, Codable, Equatable, Sendable {
        /// Work ended (or a manual hold ran out or was stopped) and everything went back to normal.
        case finished
        /// A safety limit stopped the session.
        case limit
        /// The app was closed while the session was running.
        case quit
    }

    public var startedAt: Date
    public var endedAt: Date
    public var ending: Ending
    public var stopReason: StopReason?

    public init(startedAt: Date, endedAt: Date, ending: Ending, stopReason: StopReason? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.ending = ending
        self.stopReason = stopReason
    }

    public var durationSeconds: Double { max(0, endedAt.timeIntervalSince(startedAt)) }
}

/// Watches the loop's status and reports a summary each time a session ends.
public struct SessionTracker {
    private var startedAt: Date?

    public init() {}

    /// Feed every status. Returns a summary on the tick where the Mac stopped being held awake. A limit that stops a
    /// session is reported in the same tick that releases the Mac, so that tick's latch is the reason.
    public mutating func observe(_ status: AgentLoop.Status) -> SessionSummary? {
        if status.armed {
            if startedAt == nil { startedAt = status.at }
            return nil
        }
        guard let started = startedAt else { return nil }
        startedAt = nil
        return SessionSummary(
            startedAt: started, endedAt: status.at, ending: status.latch == nil ? .finished : .limit, stopReason: status.latch
        )
    }

    /// The app is quitting: close the open session, if any.
    public mutating func finish(at date: Date) -> SessionSummary? {
        guard let started = startedAt else { return nil }
        startedAt = nil
        return SessionSummary(startedAt: started, endedAt: date, ending: .quit)
    }
}

/// The last session, kept in one small JSON file so the menu can show it after a restart.
public enum SessionStore {
    public static var defaultPath: String {
        if let override = ProcessInfo.processInfo.environment["HALFLID_LAST_SESSION"], !override.isEmpty { return override }
        return NSString(string: "~/Library/Application Support/HalfLid/last-session.json").expandingTildeInPath
    }

    public static func load(path: String = defaultPath) -> SessionSummary? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(SessionSummary.self, from: data)
    }

    public static func save(_ summary: SessionSummary, path: String = defaultPath) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(summary) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
    }
}
