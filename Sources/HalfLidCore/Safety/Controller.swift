import Foundation

/// A manual request to keep the Mac awake regardless of agent activity.
public enum Hold: Equatable, Sendable {
    case none
    case untilStopped
    case until(Date)
}

/// What the menu bar icon should show.
public enum Indicator: String, Equatable, Sendable {
    case idle
    case active
    case warning
}

public enum Notice: Equatable, Sendable {
    case warning(WarningKind)
    case stopped(StopReason)
}

/// Side effects requested by the controller. The controller never touches the system itself.
public enum Action: Equatable, Sendable {
    /// Apply the lid override.
    case arm
    /// Apply it again. macOS's power daemon shares the flag and clears it on its own events, so `OverrideKeeper` also applies it
    /// several times a second between these; this action is the loop's own check that the call still works.
    case reassert
    /// Remove the lid override.
    case disarm
    case lockScreen
    case displayOff
    case restoreScreen
    /// If the Mac is still awake after this many seconds with the lid closed, put it to sleep.
    case ensureSleep(afterSeconds: Int)
    case notify(Notice)
}

public struct ControllerInput: Sendable {
    public var now: Date
    public var agentWorking: Bool
    public var hold: Hold
    public var system: SystemSnapshot

    public init(now: Date, agentWorking: Bool, hold: Hold = .none, system: SystemSnapshot) {
        self.now = now
        self.agentWorking = agentWorking
        self.hold = hold
        self.system = system
    }
}

public struct Decision: Equatable, Sendable {
    public var armed: Bool
    public var indicator: Indicator
    public var latch: StopReason?
    public var actions: [Action]
}

/// Decides when to keep the Mac awake with the lid closed. Pure state machine: feed it a snapshot every few seconds and
/// apply the returned actions. All timing comes from `ControllerInput.now`, so every limit can be tested without waiting.
///
/// Rules, in short (details in docs/DECISIONS.md):
/// - Armed while an agent works (plus a grace period) or a manual hold is active, unless a limit is violated.
/// - A violated limit latches: the session stays stopped until the hazard recedes, so the state cannot flap.
/// - Armed with the lid closed: lock the screen and turn the display off once, then keep the display off.
/// - Releasing with the lid closed asks for sleep if the Mac does not sleep by itself.
public struct Controller {
    /// Can be replaced while running (settings changed); the session in progress keeps its state.
    public var limits: Limits

    private var armedSince: Date?
    private var lastWorkAt: Date?
    private var latch: StopReason?
    private var latchedAt: Date?
    private var warned: Set<WarningKind> = []
    private var tempWarnSince: Date?
    private var tempStopSince: Date?
    private var lidWasClosed = false
    private var closedSequenceRan = false
    private var lastReassertAt: Date?
    private var lastDisplayOffAt: Date?

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var isArmed: Bool { armedSince != nil }
    public var currentLatch: StopReason? { latch }

    /// Tell the controller that applying the override failed, so it stops pretending to be armed.
    public mutating func armFailed(at now: Date) {
        armedSince = nil
        warned = []
        latch = .overrideFailed
        latchedAt = now
    }

    public mutating func step(_ input: ControllerInput) -> Decision {
        let now = input.now
        let system = input.system
        let lidClosed = system.lidClosed ?? false
        let onBattery = system.onACPower == false
        var actions: [Action] = []

        // Is work wanted?
        if input.agentWorking { lastWorkAt = now }
        let inGrace = lastWorkAt.map { now.timeIntervalSince($0) < limits.idleGraceSeconds } ?? false
        let wanted = input.agentWorking || inGrace || Self.isActive(input.hold, now: now)

        // Lid transitions.
        let lidOpened = lidWasClosed && !lidClosed
        lidWasClosed = lidClosed
        if lidOpened && closedSequenceRan {
            actions.append(.restoreScreen)
            closedSequenceRan = false
        }

        trackTemperature(system.batteryTemperatureC, now: now)

        // Latch maintenance first, so a recovered hazard can be re-evaluated in the same step.
        if !wanted { latch = nil }
        if lidOpened, latch == .maxDuration || latch == .overrideFailed { latch = nil }
        if let current = latch, recovered(current, system: system, onBattery: onBattery, now: now) { latch = nil }

        // New violation. Only relevant while work is wanted: if it is not, the session is ending normally.
        var newlyLatched: StopReason?
        if latch == nil, wanted,
           let violation = violation(system: system, onBattery: onBattery, now: now) {
            latch = violation
            latchedAt = now
            newlyLatched = violation
        }

        // Arm or disarm.
        let shouldArm = wanted && latch == nil
        let wasArmed = armedSince != nil
        var justArmed = false
        if shouldArm && !wasArmed {
            armedSince = now
            warned = []
            lastReassertAt = now
            justArmed = true
            actions.append(.arm)
        } else if !shouldArm && wasArmed {
            armedSince = nil
            warned = []
            actions.append(.disarm)
            if lidClosed { actions.append(.ensureSleep(afterSeconds: limits.sleepFallbackSeconds)) }
        }
        if let reason = newlyLatched { actions.append(.notify(.stopped(reason))) }

        // While armed: lid-closed sequence, periodic re-assertion, warnings.
        if armedSince != nil {
            if lidClosed && !closedSequenceRan {
                actions.append(contentsOf: [.lockScreen, .displayOff])
                closedSequenceRan = true
                lastDisplayOffAt = now
            } else if lidClosed, let last = lastDisplayOffAt, now.timeIntervalSince(last) >= limits.reassertSeconds {
                actions.append(.displayOff)
                lastDisplayOffAt = now
            }
            if !justArmed, let last = lastReassertAt, now.timeIntervalSince(last) >= limits.reassertSeconds {
                actions.append(.reassert)
                lastReassertAt = now
            }
            appendWarnings(system: system, onBattery: onBattery, now: now, to: &actions)
        }

        let indicator: Indicator
        if latch != nil || (armedSince != nil && !warned.isEmpty) {
            indicator = .warning
        } else {
            indicator = armedSince != nil ? .active : .idle
        }
        return Decision(armed: armedSince != nil, indicator: indicator, latch: latch, actions: actions)
    }

    // MARK: rules

    private static func isActive(_ hold: Hold, now: Date) -> Bool {
        switch hold {
        case .none: return false
        case .untilStopped: return true
        case .until(let date): return now < date
        }
    }

    private mutating func trackTemperature(_ temperature: Double?, now: Date) {
        guard let temperature else {
            tempWarnSince = nil
            tempStopSince = nil
            return
        }
        tempWarnSince = temperature >= limits.batteryTempWarnC ? (tempWarnSince ?? now) : nil
        tempStopSince = temperature >= limits.batteryTempStopC ? (tempStopSince ?? now) : nil
    }

    /// The most urgent limit currently violated, hazards first.
    private func violation(system: SystemSnapshot, onBattery: Bool, now: Date) -> StopReason? {
        if system.thermal >= limits.thermalStopAt { return .thermal }
        if let since = tempStopSince, now.timeIntervalSince(since) >= limits.batteryTempSustainSeconds { return .batteryTemperature }
        if onBattery, let percent = system.batteryPercent, percent <= limits.batteryStopPercent { return .batteryLow }
        if let since = armedSince {
            let hours = onBattery ? limits.maxHoursOnBattery : limits.maxHoursOnAC
            if now.timeIntervalSince(since) >= hours * 3600 { return .maxDuration }
        }
        return nil
    }

    private func recovered(_ reason: StopReason, system: SystemSnapshot, onBattery: Bool, now: Date) -> Bool {
        switch reason {
        case .thermal:
            guard system.thermal < limits.thermalStopAt else { return false }
            return latchedAt.map { now.timeIntervalSince($0) >= limits.thermalCooldownSeconds } ?? true
        case .batteryTemperature:
            guard let temperature = system.batteryTemperatureC else { return true }
            return temperature <= limits.batteryTempStopC - limits.batteryTempRecoveryMarginC
        case .batteryLow:
            guard onBattery, let percent = system.batteryPercent else { return true }
            return percent >= limits.batteryStopPercent + limits.batteryResumeMarginPercent
        case .overrideFailed:
            return latchedAt.map { now.timeIntervalSince($0) >= limits.overrideRetrySeconds } ?? true
        case .maxDuration:
            return false // cleared by the lid opening or by the session ending (see step)
        }
    }

    private mutating func appendWarnings(system: SystemSnapshot, onBattery: Bool, now: Date, to actions: inout [Action]) {
        if onBattery, let percent = system.batteryPercent,
           percent <= limits.batteryWarnPercent, percent > limits.batteryStopPercent, !warned.contains(.batteryLow) {
            warned.insert(.batteryLow)
            actions.append(.notify(.warning(.batteryLow)))
        }
        if let since = tempWarnSince, now.timeIntervalSince(since) >= limits.batteryTempSustainSeconds,
           !warned.contains(.batteryTemperature) {
            warned.insert(.batteryTemperature)
            actions.append(.notify(.warning(.batteryTemperature)))
        }
    }
}
