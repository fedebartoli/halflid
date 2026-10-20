import Foundation

public enum InstanceLockResult {
    case acquired(InstanceLock)
    /// Another controller (the app or `halflid run`) already holds the lock.
    case alreadyRunning
    /// The lock file could not be created; the caller decides whether to go on without it.
    case unavailable
}

/// Only one controller at a time may hold the lid override: two of them would clear each other's override. The lock is
/// an advisory file lock, so the kernel releases it by itself when the holder dies, however it dies.
public final class InstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    public static var defaultPath: String {
        NSString(string: "~/Library/Application Support/HalfLid/controller.lock").expandingTildeInPath
    }

    public static func acquire(path: String = defaultPath) -> InstanceLockResult {
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        } catch {
            return .unavailable
        }
        // Close-on-exec: child processes (the guard) must not inherit the lock and keep it after the app is gone.
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return .unavailable }
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let busy = errno == EWOULDBLOCK
            close(descriptor)
            return busy ? .alreadyRunning : .unavailable
        }
        return .acquired(InstanceLock(descriptor: descriptor))
    }
}
