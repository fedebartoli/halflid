import Foundation
import IOKit.ps

public enum ThermalLevel: String, Codable, Sendable, CaseIterable {
    case nominal, fair, serious, critical

    public init(_ state: ProcessInfo.ThermalState) {
        switch state {
        case .nominal: self = .nominal
        case .fair: self = .fair
        case .serious: self = .serious
        case .critical: self = .critical
        @unknown default: self = .serious // unknown future state: treat as worse than fair
        }
    }
}

/// Everything Half Lid can read about the machine without privileges. Optional fields are `nil` when unavailable
/// (for example battery fields on a desktop Mac).
public struct SystemSnapshot: Codable, Equatable, Sendable {
    public var lidClosed: Bool?
    public var sleepDisabled: Bool?
    public var onACPower: Bool?
    public var chargerConnected: Bool?
    public var batteryPercent: Int?
    public var batteryCharging: Bool?
    public var batteryTemperatureC: Double?
    public var thermal: ThermalLevel
    public var lowPowerMode: Bool

    public init(
        lidClosed: Bool? = nil, sleepDisabled: Bool? = nil, onACPower: Bool? = nil, chargerConnected: Bool? = nil,
        batteryPercent: Int? = nil, batteryCharging: Bool? = nil, batteryTemperatureC: Double? = nil,
        thermal: ThermalLevel = .nominal, lowPowerMode: Bool = false
    ) {
        self.lidClosed = lidClosed
        self.sleepDisabled = sleepDisabled
        self.onACPower = onACPower
        self.chargerConnected = chargerConnected
        self.batteryPercent = batteryPercent
        self.batteryCharging = batteryCharging
        self.batteryTemperatureC = batteryTemperatureC
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
    }
}

public enum SystemProbe {
    public static func snapshot() -> SystemSnapshot {
        let power = readPowerSource()
        return SystemSnapshot(
            lidClosed: PowerRegistry.lidClosed(),
            sleepDisabled: PowerRegistry.sleepDisabled(),
            onACPower: power.onAC,
            chargerConnected: PowerRegistry.chargerConnected(),
            batteryPercent: power.percent,
            batteryCharging: power.charging,
            batteryTemperatureC: PowerRegistry.batteryTemperatureCelsius(),
            thermal: ThermalLevel(ProcessInfo.processInfo.thermalState),
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    struct PowerSourceReading {
        var onAC: Bool?
        var percent: Int?
        var charging: Bool?
    }

    static func readPowerSource() -> PowerSourceReading {
        var reading = PowerSourceReading()
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return reading }
        if let provider = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? {
            reading.onAC = (provider == kIOPSACPowerValue)
        }
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return reading }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                reading.percent = Int((Double(current) / Double(max) * 100).rounded())
            }
            reading.charging = description[kIOPSIsChargingKey] as? Bool
        }
        return reading
    }
}
