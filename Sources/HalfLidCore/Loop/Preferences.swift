import Foundation

/// Which notifications Half Lid may post. Off until the user turns them on, which is also when macOS asks for permission.
public struct NotificationPreferences: Codable, Equatable, Sendable {
    public var enabled = false
    /// Half Lid stopped keeping the Mac awake to protect it (battery, heat, time limit).
    public var onStop = true
    /// A safety limit is close.
    public var onWarning = true
    /// A timed "keep awake" ends in a few minutes.
    public var onHoldEnding = true
    /// The work finished and the Mac may sleep again.
    public var onWorkFinished = false

    public init() {}
}

/// Persistent settings, stored as one small JSON file. Missing keys fall back to defaults, so an older file keeps working
/// after an update adds settings, and a damaged file never prevents the app from starting.
public struct Preferences: Codable, Equatable, Sendable {
    /// Read Cursor's chat state (only while a Cursor process exists).
    public var cursorEnabled = true
    /// Ids of command-line agents to watch. `nil` means every catalog agent except Cursor.
    public var cliAgents: [String]?
    public var limits = Limits()
    /// Lock the session when the lid closes while awake.
    public var lockOnClose = true
    /// Turn the display off (brightness to 0, display sleep) when the lid closes while awake.
    public var displayOffOnClose = true
    public var notifications = NotificationPreferences()
    /// Language code of the interface (one of the catalog files), or `nil` to follow the system.
    public var language: String?
    /// The short welcome shown the first time the panel opens has been seen.
    public var welcomeSeen = false
    /// `halflid start`, `stop` and `status` may control the running app.
    public var commandLineControl = true

    public init() {}

    public static var defaultPath: String {
        if let override = ProcessInfo.processInfo.environment["HALFLID_PREFERENCES"], !override.isEmpty { return override }
        return NSString(string: "~/Library/Application Support/HalfLid/preferences.json").expandingTildeInPath
    }

    /// The saved preferences, or defaults when the file is missing or unreadable. Limits are always brought inside the safe ranges.
    public static func load(path: String = defaultPath) -> Preferences {
        var loaded = Preferences()
        if let data = FileManager.default.contents(atPath: path) {
            loaded = JSONMerge.decode(Preferences.self, defaults: Preferences(), from: data)
        }
        loaded.limits = loaded.limits.sanitized()
        return loaded
    }

    /// Whether the command-line agent `id` is one the user watches. Cursor is handled by its own module, never here.
    public func watchesCommandLineAgent(_ id: String, cursorId: String = "cursor") -> Bool {
        id != cursorId && (cliAgents.map { $0.contains(id) } ?? true)
    }

    /// Whether any agent, Cursor included, is watched.
    public func watches(_ id: String, cursorId: String = "cursor") -> Bool {
        id == cursorId ? cursorEnabled : watchesCommandLineAgent(id, cursorId: cursorId)
    }

    /// Turns the watching of one agent on or off. Cursor has its own switch; command-line agents share one list, which is
    /// written out in full the first time (`nil` meant "all of them").
    public mutating func setWatching(_ id: String, _ on: Bool, agents: AgentCatalog, cursorId: String = "cursor") {
        if id == cursorId {
            cursorEnabled = on
            return
        }
        var watched = cliAgents ?? agents.agents.map(\.id).filter { $0 != cursorId }
        watched.removeAll { $0 == id }
        if on { watched.append(id) }
        cliAgents = watched.sorted()
    }

    public func save(path: String = Preferences.defaultPath) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

enum JSONMerge {
    /// Decodes `data` on top of `defaults`: keys present in the file win, absent keys keep their default. Any problem
    /// (not JSON, wrong types) returns `defaults` unchanged.
    static func decode<T: Codable>(_ type: T.Type, defaults: T, from data: Data) -> T {
        guard let overlay = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let encodedDefaults = try? JSONEncoder().encode(defaults),
              let base = (try? JSONSerialization.jsonObject(with: encodedDefaults)) as? [String: Any] else { return defaults }
        let merged = merge(base, overlay)
        guard JSONSerialization.isValidJSONObject(merged),
              let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let value = try? JSONDecoder().decode(T.self, from: mergedData) else { return defaults }
        return value
    }

    static func merge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let inner = value as? [String: Any], let existing = result[key] as? [String: Any] {
                result[key] = merge(existing, inner)
            } else {
                result[key] = value
            }
        }
        return result
    }
}

extension Limits {
    /// Keeps every limit inside a range that still protects the machine. A setting outside it (typo, hand-edited file, old
    /// version) is pulled to the nearest allowed value instead of silently disabling a safeguard.
    public func sanitized() -> Limits {
        func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T { min(max(value, low), high) }
        var result = self
        result.batteryStopPercent = clamp(batteryStopPercent, 5, 50)
        result.batteryWarnPercent = clamp(batteryWarnPercent, result.batteryStopPercent + 5, 90)
        result.batteryResumeMarginPercent = clamp(batteryResumeMarginPercent, 1, 20)
        result.maxHoursOnBattery = clamp(maxHoursOnBattery, 0.25, 24)
        result.maxHoursOnAC = clamp(maxHoursOnAC, 0.25, 72)
        result.thermalStopAt = max(thermalStopAt, .fair)
        result.thermalCooldownSeconds = clamp(thermalCooldownSeconds, 10, 3600)
        result.batteryTempStopC = clamp(batteryTempStopC, 38, 50)
        result.batteryTempWarnC = clamp(batteryTempWarnC, 35, result.batteryTempStopC - 1)
        result.batteryTempSustainSeconds = clamp(batteryTempSustainSeconds, 10, 600)
        result.batteryTempRecoveryMarginC = clamp(batteryTempRecoveryMarginC, 2, 15)
        result.idleGraceSeconds = clamp(idleGraceSeconds, 10, 3600)
        result.reassertSeconds = clamp(reassertSeconds, 10, 300)
        result.sleepFallbackSeconds = clamp(sleepFallbackSeconds, 10, 600)
        result.overrideRetrySeconds = clamp(overrideRetrySeconds, 10, 600)
        return result
    }
}
