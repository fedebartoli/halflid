import CoreGraphics
import Foundation

// Screen side of the lid-closed sequence. With the lid override on, the internal display is NOT turned off by macOS, so we
// lock the session and put the display to sleep ourselves. Everything here is best effort: a missing private symbol or a
// failing command is logged and skipped, never fatal.
//
// Private API used (looked up at run time with dlsym; if one disappears in a future macOS the feature degrades):
//   login.framework      SACLockScreenImmediate   lock the session
//   DisplayServices      DisplayServicesGet/SetBrightness   built-in panel brightness
// Public tools: `pmset displaysleepnow` and `pmset sleepnow` need no privileges.

/// Read-only views of the screen state, used to verify what the sequence really did.
public enum ScreenProbe {
    public static func displayAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    /// `true` while the session is locked, `nil` if the session dictionary is unavailable.
    public static func sessionLocked() -> Bool? {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        if let value = dictionary["CGSSessionScreenIsLocked"] as? NSNumber { return value.boolValue }
        return false
    }
}

public enum DisplayBrightness {
    private typealias GetFunction = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFunction = @convention(c) (UInt32, Float) -> Int32

    private static let functions: (get: GetFunction, set: SetFunction)? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let get = dlsym(library, "DisplayServicesGetBrightness"),
              let set = dlsym(library, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(get, to: GetFunction.self), unsafeBitCast(set, to: SetFunction.self))
    }()

    public static var isAvailable: Bool { functions != nil }

    /// Brightness of the built-in display between 0 and 1, `nil` if unavailable.
    public static func current() -> Float? {
        guard let functions else { return nil }
        var value: Float = -1
        guard functions.get(CGMainDisplayID(), &value) == 0, value >= 0 else { return nil }
        return value
    }

    @discardableResult
    public static func set(_ value: Float) -> Bool {
        guard let functions else { return false }
        return functions.set(CGMainDisplayID(), max(0, min(1, value))) == 0
    }
}

/// Remembers the brightness to restore. The file survives a crash, so the guard process and the next app start can repair
/// a Mac left with a black screen.
public enum ScreenRepair {
    public static var defaultStatePath: String {
        NSString(string: "~/Library/Application Support/HalfLid/brightness.saved").expandingTildeInPath
    }

    public static func save(_ value: Float, path: String = defaultStatePath) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? "\(value)\n".write(toFile: path, atomically: true, encoding: .utf8)
    }

    public static func load(path: String = defaultStatePath) -> Float? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return Float(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Restores the saved brightness (if any) and forgets it. Returns whether something was restored.
    @discardableResult
    public static func restore(path: String = defaultStatePath, apply: (Float) -> Bool = { DisplayBrightness.set($0) }) -> Bool {
        guard let saved = load(path: path) else { return false }
        let applied = apply(saved)
        // Keep the file if the restore failed, so a later attempt can still repair it.
        if applied { try? FileManager.default.removeItem(atPath: path) }
        return applied
    }
}

public final class SystemScreenControl: ScreenControl {
    private typealias LockFunction = @convention(c) () -> Void

    private static let lockFunction: LockFunction? = {
        guard let library = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_NOW),
              let symbol = dlsym(library, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(symbol, to: LockFunction.self)
    }()

    /// Whether the private function that locks the session exists on this macOS. The settings window shows it, because without
    /// it the lid-closed sequence cannot lock the Mac and nothing else says so.
    public static var canLockScreen: Bool { lockFunction != nil }

    private let statePath: String
    private let log: (String) -> Void
    private let mutex = NSLock()
    private var pendingSleep: DispatchWorkItem?

    public init(statePath: String = ScreenRepair.defaultStatePath, log: @escaping (String) -> Void = { _ in }) {
        self.statePath = statePath
        self.log = log
    }

    public func lockScreen() {
        guard let lock = Self.lockFunction else {
            log("screen lock unavailable: SACLockScreenImmediate not found")
            return
        }
        lock()
    }

    public func displayOff() {
        dimToZero()
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    public func restoreScreen() {
        if ScreenRepair.load(path: statePath) != nil, !ScreenRepair.restore(path: statePath) {
            log("brightness could not be restored; the saved value is kept for the next attempt")
        }
    }

    public func sleepIfStillAwake(afterSeconds: Int) {
        let work = DispatchWorkItem { [weak self] in
            // The lid must still be closed: with the lid open nobody wants the Mac put to sleep.
            guard PowerRegistry.lidClosed() == true else { return }
            self?.log("still awake with the lid closed after release: sleeping")
            self?.run("/usr/bin/pmset", ["sleepnow"])
        }
        mutex.lock()
        pendingSleep?.cancel()
        pendingSleep = work
        mutex.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(afterSeconds), execute: work)
    }

    public func cancelPendingSleep() {
        mutex.lock()
        pendingSleep?.cancel()
        pendingSleep = nil
        mutex.unlock()
    }

    // MARK: private

    private func dimToZero() {
        guard let current = DisplayBrightness.current() else { return }
        // Remember the original value only once, and never remember an already dark screen.
        if ScreenRepair.load(path: statePath) == nil, current > 0.01 { ScreenRepair.save(current, path: statePath) }
        if !DisplayBrightness.set(0) { log("brightness could not be set to 0") }
    }

    private func run(_ path: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log("\(path) failed to start: \(error)")
        }
    }
}
