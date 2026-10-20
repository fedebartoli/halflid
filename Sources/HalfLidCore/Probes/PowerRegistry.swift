import Foundation
import IOKit

/// Reads power-related IORegistry properties. Read-only, no privileges required.
public enum PowerRegistry {
    private static func property(service name: String, key: String) -> CFTypeRef? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(name))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// `nil` when the Mac has no lid (desktop) or the key is unreadable.
    public static func lidClosed() -> Bool? {
        property(service: "IOPMrootDomain", key: "AppleClamshellState") as? Bool
    }

    /// Whether the system-wide "sleep disabled" setting (`pmset disablesleep`) is currently on.
    public static func sleepDisabled() -> Bool? {
        property(service: "IOPMrootDomain", key: "SleepDisabled") as? Bool
    }

    /// Battery temperature in degrees Celsius. The registry value is in hundredths of a degree (convention used by public
    /// tools); the unit has not been checked against a reference thermometer.
    public static func batteryTemperatureCelsius() -> Double? {
        guard let raw = property(service: "AppleSmartBattery", key: "Temperature") as? Int else { return nil }
        return Double(raw) / 100.0
    }

    /// Whether a charger is physically connected (can differ from "providing power" when charging is paused).
    public static func chargerConnected() -> Bool? {
        property(service: "AppleSmartBattery", key: "ExternalConnected") as? Bool
    }
}

/// Calls `handler` on every general-interest message of the power root domain (lid, sleep, wake, ...). The message type is
/// passed through so callers can log it; callers should re-read the state instead of interpreting message codes.
public final class RootDomainWatcher {
    private let port: IONotificationPortRef
    private var notifier: io_object_t = 0
    private let handler: (UInt32) -> Void

    private static let callback: IOServiceInterestCallback = { refcon, _, messageType, _ in
        guard let refcon else { return }
        Unmanaged<RootDomainWatcher>.fromOpaque(refcon).takeUnretainedValue().handler(messageType)
    }

    public init?(queue: DispatchQueue = .main, handler: @escaping (UInt32) -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        self.port = port
        self.handler = handler
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else {
            IONotificationPortDestroy(port)
            return nil
        }
        defer { IOObjectRelease(service) }
        IONotificationPortSetDispatchQueue(port, queue)
        let result = IOServiceAddInterestNotification(
            port, service, kIOGeneralInterest, RootDomainWatcher.callback,
            Unmanaged.passUnretained(self).toOpaque(), &notifier
        )
        guard result == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return nil
        }
    }

    deinit {
        if notifier != 0 { IOObjectRelease(notifier) }
        IONotificationPortDestroy(port)
    }
}
