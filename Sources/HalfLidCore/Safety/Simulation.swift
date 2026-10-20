import Foundation

/// Scripted situations fed to the controller with virtual time, so every limit can be exercised without a real hot or
/// empty battery. `halflid simulate <name>` prints the timeline; the tests assert on it.
public enum Scenario: String, CaseIterable, Sendable {
    case agentSession = "agent-session"
    case lidClose = "lid-close"
    case batteryDrain = "battery-drain"
    case thermal
    case batteryTemperature = "battery-temperature"
    case maxDuration = "max-duration"
}

public struct SimulationLine: Equatable, Sendable {
    public var seconds: Int
    public var armed: Bool
    public var indicator: Indicator
    public var actions: [Action]
}

public enum Simulator {
    private struct Definition {
        var stepSeconds: Int
        var durationSeconds: Int
        var input: (Int) -> (agentWorking: Bool, system: SystemSnapshot)
    }

    private static func system(
        lidClosed: Bool = false, onAC: Bool = true, percent: Int = 100, temperature: Double? = 31, thermal: ThermalLevel = .nominal
    ) -> SystemSnapshot {
        SystemSnapshot(lidClosed: lidClosed, onACPower: onAC, batteryPercent: percent, batteryTemperatureC: temperature, thermal: thermal)
    }

    private static func definition(for scenario: Scenario) -> Definition {
        switch scenario {
        case .agentSession:
            // Work from 10 s to 600 s, then idle. Expect: arm at 10 s, disarm 120 s after the last work.
            return Definition(stepSeconds: 5, durationSeconds: 900) { t in (t >= 10 && t < 600, system()) }
        case .lidClose:
            // Armed the whole time; lid closed from 60 s to 180 s. Work ends at 240 s.
            return Definition(stepSeconds: 5, durationSeconds: 360) { t in (t < 240, system(lidClosed: t >= 60 && t < 180)) }
        case .batteryDrain:
            // On battery from 31 %, losing 1 % every 30 s; charger plugged in at 540 s.
            return Definition(stepSeconds: 5, durationSeconds: 600) { t in
                (true, system(onAC: t >= 540, percent: 31 - t / 30))
            }
        case .thermal:
            // Thermal level: nominal, fair (100 s), serious (200 s), fair (300 s), nominal (340 s).
            return Definition(stepSeconds: 5, durationSeconds: 500) { t in
                let level: ThermalLevel = t < 100 ? .nominal : t < 200 ? .fair : t < 300 ? .serious : t < 340 ? .fair : .nominal
                return (true, system(thermal: level))
            }
        case .batteryTemperature:
            // 40 C, then 43 C from 60 s, 46 C from 180 s, back to 39 C from 360 s.
            return Definition(stepSeconds: 5, durationSeconds: 500) { t in
                let temperature = t < 60 ? 40.0 : t < 180 ? 43.0 : t < 360 ? 46.0 : 39.0
                return (true, system(temperature: temperature))
            }
        case .maxDuration:
            // On battery at 80 % for five hours; the lid is closed at 15000 s and opened at 15300 s.
            return Definition(stepSeconds: 60, durationSeconds: 18000) { t in
                (true, system(lidClosed: t >= 15000 && t < 15300, onAC: false, percent: 80))
            }
        }
    }

    public static func run(_ scenario: Scenario, limits: Limits = Limits()) -> [SimulationLine] {
        let definition = definition(for: scenario)
        var controller = Controller(limits: limits)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var lines: [SimulationLine] = []
        var t = 0
        while t <= definition.durationSeconds {
            let (working, snapshot) = definition.input(t)
            let decision = controller.step(ControllerInput(now: start.addingTimeInterval(Double(t)), agentWorking: working, system: snapshot))
            lines.append(SimulationLine(seconds: t, armed: decision.armed, indicator: decision.indicator, actions: decision.actions))
            t += definition.stepSeconds
        }
        return lines
    }

    /// Compact text form of an action, used by the CLI and the tests.
    public static func describe(_ action: Action) -> String {
        switch action {
        case .arm: return "arm"
        case .reassert: return "reassert"
        case .disarm: return "disarm"
        case .lockScreen: return "lock"
        case .displayOff: return "display_off"
        case .restoreScreen: return "restore_screen"
        case .ensureSleep(let seconds): return "ensure_sleep(\(seconds))"
        case .notify(.warning(let kind)): return "warn:\(kind.rawValue)"
        case .notify(.stopped(let reason)): return "stopped:\(reason.rawValue)"
        }
    }
}
