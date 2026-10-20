import Foundation
import IOKit

/// Makes macOS ignore the lid being closed (or stops ignoring it). Behind a protocol so the policy can be tested with
/// fakes and so a different mechanism can replace the IOKit call if a future macOS changes its behaviour.
public protocol LidOverride: AnyObject {
    func setLidCloseIgnored(_ ignored: Bool) throws
}

public enum LidOverrideError: Error, Equatable {
    case serviceUnavailable
    case openFailed(Int32)
    case callFailed(Int32)
}

/// Calls the `IOPMrootDomain` user-client method `kPMSetClamshellSleepState` (selector 12 in IOPMLibDefs.h).
///
/// No privileges are needed. Verified on macOS 26.5.2 (arm64), lid closed, on AC and on battery: with the call active macOS
/// logs no power event at all when the lid closes; without it the Mac sleeps. The state is kernel-global (not tied to this
/// process) and the registry gives no way to read it back, so recovery relies on the guard process (`Guardian`).
///
/// The flag this sets is shared: macOS's power daemon (`powerd`) writes the very same bit (xnu names it
/// `kClamshellSleepDisablePowerd`) and clears it whenever its own picture changes: a monitor coming or going, a wake. Setting
/// it once is therefore not enough; `OverrideKeeper` sets it again several times a second while armed.
public final class IOKitLidOverride: LidOverride {
    static let selector: UInt32 = 12

    public init() {}

    public func setLidCloseIgnored(_ ignored: Bool) throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { throw LidOverrideError.serviceUnavailable }
        defer { IOObjectRelease(service) }
        var connection: io_connect_t = 0
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard opened == KERN_SUCCESS else { throw LidOverrideError.openFailed(opened) }
        defer { IOServiceClose(connection) }
        var input: UInt64 = ignored ? 1 : 0
        let result = IOConnectCallMethod(connection, Self.selector, &input, 1, nil, 0, nil, nil, nil, nil)
        guard result == KERN_SUCCESS else { throw LidOverrideError.callFailed(result) }
    }
}

/// Test and debug stand-in: records the requested state in a file instead of touching the system.
public final class FileLidOverride: LidOverride {
    public let path: String

    public init(path: String) { self.path = path }

    public func setLidCloseIgnored(_ ignored: Bool) throws {
        try (ignored ? "ignored\n" : "normal\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// `true` when the file says the lid is ignored, `false` when normal, `nil` when missing or unreadable.
    public static func state(at path: String) -> Bool? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "ignored": return true
        case "normal": return false
        default: return nil
        }
    }
}

public enum LidOverrideFactory {
    /// The real IOKit override, or the file stand-in when `HALFLID_FAKE_OVERRIDE` names a file (debug and tests only).
    public static func make(environment: [String: String] = ProcessInfo.processInfo.environment) -> LidOverride {
        if let path = environment["HALFLID_FAKE_OVERRIDE"], !path.isEmpty { return FileLidOverride(path: path) }
        return IOKitLidOverride()
    }
}
