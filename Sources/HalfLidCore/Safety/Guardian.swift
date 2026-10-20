import Foundation

/// The app proves it is alive by touching a file. The guard process watches that file and the app's process.
public enum Heartbeat {
    public static func touch(path: String, now: Date = Date()) {
        try? "\(Int(now.timeIntervalSince1970))\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Seconds since the last touch, or `nil` if the file is missing.
    public static func age(path: String, now: Date = Date()) -> TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return max(0, now.timeIntervalSince(modified))
    }
}

public enum GuardOutcome: String, Equatable, Sendable {
    case parentExited
    case heartbeatStale
    case terminated
}

public enum GuardLogic {
    /// Fail safe: anything doubtful releases the override (the Mac then simply sleeps on lid close).
    public static func shouldRelease(parentAlive: Bool, heartbeatAge: TimeInterval?, maxHeartbeatAge: TimeInterval) -> Bool {
        if !parentAlive { return true }
        guard let heartbeatAge else { return true }
        return heartbeatAge > maxHeartbeatAge
    }
}

/// Runs in a separate process (`halflid guard`). Releases the lid override when the app dies (even with SIGKILL), hangs
/// (stale heartbeat) or the guard itself is asked to stop. Needs no privileges: any user process can clear the override.
public final class Guardian {
    private let parentPid: pid_t
    private let heartbeatPath: String
    private let override: LidOverride
    private let pollSeconds: Double
    private let maxHeartbeatAge: Double
    private let afterRelease: () -> Void

    /// - Parameter afterRelease: extra repair run once the override is released (for example restoring screen brightness).
    public init(
        parentPid: pid_t, heartbeatPath: String, override: LidOverride, pollSeconds: Double = 1, maxHeartbeatAge: Double = 120,
        afterRelease: @escaping () -> Void = {}
    ) {
        self.parentPid = parentPid
        self.heartbeatPath = heartbeatPath
        self.override = override
        self.pollSeconds = pollSeconds
        self.maxHeartbeatAge = maxHeartbeatAge
        self.afterRelease = afterRelease
    }

    static func processAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Blocks until the override has been released. `shouldStop` lets the caller end the loop (for SIGTERM handling).
    public func run(shouldStop: () -> Bool = { false }) -> GuardOutcome {
        var outcome = GuardOutcome.terminated
        while true {
            if shouldStop() { outcome = .terminated; break }
            let alive = Self.processAlive(parentPid)
            if GuardLogic.shouldRelease(parentAlive: alive, heartbeatAge: Heartbeat.age(path: heartbeatPath), maxHeartbeatAge: maxHeartbeatAge) {
                outcome = alive ? .heartbeatStale : .parentExited
                break
            }
            Thread.sleep(forTimeInterval: pollSeconds)
        }
        for attempt in 1...3 {
            if (try? override.setLidCloseIgnored(false)) != nil { break }
            if attempt < 3 { Thread.sleep(forTimeInterval: 1) }
        }
        afterRelease()
        // The app is gone and cannot clean up after itself. Not done for a stale heartbeat: the app may still be alive.
        if outcome == .parentExited { try? FileManager.default.removeItem(atPath: heartbeatPath) }
        return outcome
    }
}
