import Foundation

/// Why Half Lid stopped (or refused to start) keeping the Mac awake.
public enum StopReason: String, Codable, Equatable, Sendable, CaseIterable {
    case batteryLow
    case maxDuration
    case thermal
    case batteryTemperature
    /// The lid override could not be applied; the Mac will sleep when the lid closes.
    case overrideFailed
}

public enum WarningKind: String, Codable, Equatable, Sendable, CaseIterable {
    case batteryLow
    case batteryTemperature
}

/// Default limits, chosen to be prudent. Only measurable quantities are used. See docs/DECISIONS.md section 4.
public struct Limits: Codable, Equatable, Sendable {
    public var batteryWarnPercent = 30
    public var batteryStopPercent = 20
    /// After a battery stop the session may resume only on AC power or when the charge is this many points above the stop level.
    public var batteryResumeMarginPercent = 5
    public var maxHoursOnBattery = 4.0
    public var maxHoursOnAC = 12.0
    public var thermalStopAt: ThermalLevel = .serious
    /// After a thermal stop, wait at least this long (and for the level to drop below the stop level) before resuming.
    public var thermalCooldownSeconds = 60.0
    public var batteryTempWarnC = 42.0
    public var batteryTempStopC = 45.0
    /// A temperature threshold counts only after it has been exceeded for this long without interruption.
    public var batteryTempSustainSeconds = 60.0
    public var batteryTempRecoveryMarginC = 5.0
    /// How long after the last sign of work the Mac is still kept awake (rides out long network waits).
    public var idleGraceSeconds = 120.0
    /// While armed, the loop applies the override again this often and reports it if the call fails. This is not what defends
    /// the hold against macOS clearing the flag: `OverrideKeeper` applies it several times a second for that.
    public var reassertSeconds = 60.0
    /// After releasing with the lid closed, force sleep if the Mac is still awake after this many seconds.
    public var sleepFallbackSeconds = 90
    /// A failed override attempt blocks new attempts for this long (or until the lid opens).
    public var overrideRetrySeconds = 60.0

    public init() {}
}

extension ThermalLevel: Comparable {
    public static func < (lhs: ThermalLevel, rhs: ThermalLevel) -> Bool {
        let order = ThermalLevel.allCases
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}
