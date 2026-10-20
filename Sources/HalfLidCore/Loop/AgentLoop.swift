import Foundation

/// The recovery process that releases the lid override if the app dies.
public protocol GuardHandle: AnyObject {
    var isRunning: Bool { get }
    func start()
    /// Stops the guard and returns once it is gone (or after a short timeout), so a late release cannot undo a new session.
    func stop()
}

/// Real guard: the same executable started as `guard --parent <pid> --heartbeat <file>`. It lives in its own process so it
/// survives the app being killed.
public final class GuardProcess: GuardHandle {
    private let executable: URL
    private let heartbeatPath: String
    private let environment: [String: String]?
    private var process: Process?

    public init(executable: URL, heartbeatPath: String, environment: [String: String]? = nil) {
        self.executable = executable
        self.heartbeatPath = heartbeatPath
        self.environment = environment
    }

    public var isRunning: Bool { process?.isRunning ?? false }

    public func start() {
        guard !isRunning else { return }
        let child = Process()
        child.executableURL = executable
        child.arguments = ["guard", "--parent", String(getpid()), "--heartbeat", heartbeatPath]
        // Passed explicitly: leaving it unset did not hand the parent's variables to the guard (found by the kill -9 test).
        child.environment = environment ?? ProcessInfo.processInfo.environment
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try? child.run()
        process = child
    }

    public func stop() {
        guard let child = process else { return }
        process = nil
        guard child.isRunning else { return }
        child.terminate()
        let deadline = Date().addingTimeInterval(3)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    }
}

/// One iteration reads the machine and the agents, asks the controller what to do, and applies it. The caller decides
/// when to iterate (a timer, plus lid and power events). Not thread-safe: call from one queue.
public final class AgentLoop {
    public struct Status: Equatable, Sendable {
        public var armed: Bool
        public var indicator: Indicator
        public var latch: StopReason?
        public var report: WorkReport
        public var system: SystemSnapshot
        public var hold: Hold
        /// Seconds since the current session was armed, `nil` when not armed.
        public var armedSeconds: Double?
        public var at: Date

        public init(
            armed: Bool, indicator: Indicator, latch: StopReason? = nil, report: WorkReport = WorkReport(),
            system: SystemSnapshot = SystemSnapshot(), hold: Hold = .none, armedSeconds: Double? = nil, at: Date = Date()
        ) {
            self.armed = armed
            self.indicator = indicator
            self.latch = latch
            self.report = report
            self.system = system
            self.hold = hold
            self.armedSeconds = armedSeconds
            self.at = at
        }
    }

    public var hold: Hold = .none

    private var preferences: Preferences
    private var controller: Controller
    private let detector: WorkDetector
    private let systemProbe: () -> SystemSnapshot
    private let executor: ActionExecutor
    private let guardHandle: GuardHandle
    private let heartbeatPath: String
    private let clock: () -> Date
    private var armedSince: Date?

    public init(
        preferences: Preferences, detector: WorkDetector, system: @escaping () -> SystemSnapshot, executor: ActionExecutor,
        guardHandle: GuardHandle, heartbeatPath: String, clock: @escaping () -> Date = Date.init
    ) {
        self.preferences = preferences
        self.controller = Controller(limits: preferences.limits.sanitized())
        self.detector = detector
        self.systemProbe = system
        self.executor = executor
        self.guardHandle = guardHandle
        self.heartbeatPath = heartbeatPath
        self.clock = clock
    }

    /// Applies new settings without losing the session in progress.
    public func update(preferences: Preferences) {
        self.preferences = preferences
        controller.limits = preferences.limits.sanitized()
    }

    /// Something that can change the lid flag just happened (the lid, a monitor, the power source, a wake). Re-applies the
    /// override at once and a few more times over the next seconds while armed. Unlike the rest of the loop, safe from any thread.
    public func overrideMayHaveChanged() {
        executor.overrideMayHaveChanged()
    }

    @discardableResult
    public func tick() -> Status {
        let now = clock()
        // A timed hold that has run out is no hold at all. Left in place it would keep "stop keeping awake" on screen, hide the
        // duration choices and show an end time in the past, for as long as the app runs.
        if case .until(let end) = hold, end <= now { hold = .none }
        let system = systemProbe()
        let report = detector.detect(preferences: preferences)
        let decision = controller.step(ControllerInput(now: now, agentWorking: report.working, hold: hold, system: system))

        let actions = decision.actions.filter { action in
            switch action {
            case .lockScreen: return preferences.lockOnClose
            case .displayOff: return preferences.displayOffOnClose
            default: return true
            }
        }

        // The safety net first: when the override is about to be applied the guard and a fresh heartbeat must already exist.
        if actions.contains(.arm) || decision.armed {
            Heartbeat.touch(path: heartbeatPath, now: now)
        }
        // Never apply the override without a running guard: without it nothing would release the Mac if this app died.
        var guardReady = true
        if actions.contains(.arm) {
            guardHandle.start()
            guardReady = guardHandle.isRunning
        }

        var indicator = decision.indicator
        var latch = decision.latch
        if !guardReady || !executor.apply(actions) {
            controller.armFailed(at: now)
            // The failed call may have partly worked: release as well as we can. When the executor never ran, it also
            // could not tell the user, so do that here.
            executor.apply(guardReady ? [.disarm] : [.disarm, .notify(.stopped(.overrideFailed))])
            indicator = .warning
            latch = .overrideFailed
        }

        if actions.contains(.arm) && controller.isArmed { armedSince = now }
        if !controller.isArmed { armedSince = nil }

        if controller.isArmed {
            if !guardHandle.isRunning { guardHandle.start() }
        } else {
            guardHandle.stop()
        }

        return Status(
            armed: controller.isArmed, indicator: indicator, latch: latch, report: report, system: system, hold: hold,
            armedSeconds: armedSince.map { now.timeIntervalSince($0) }, at: now
        )
    }

    /// Leaves the Mac in its normal state: override released, screen restored, guard stopped. Call before exiting.
    public func shutdown() {
        executor.apply([.disarm, .restoreScreen])
        guardHandle.stop()
        try? FileManager.default.removeItem(atPath: heartbeatPath)
        armedSince = nil
    }
}
