import Foundation

/// Applies the lid override again and again, from a queue of its own, for as long as the Mac is being held.
///
/// Why it exists. The flag behind the override is not Half Lid's alone: macOS's power daemon (`powerd`) writes the very same
/// flag (xnu calls it `kClamshellSleepDisablePowerd`) and clears it whenever its own picture of the machine changes. A closed-lid
/// run on 2026-10-19 showed it in the system log: with an external monitor attached, the monitor's link dropped as the lid began
/// to close, `powerd` cleared the flag, and the kernel heard "lid closed" 0.69 s later with the flag gone, so the Mac went to sleep
/// while Half Lid believed it was holding it. Re-applying the override once a minute, as Half Lid first did, cannot win a race
/// that lasts well under a second; re-applying it a few times a second can. `docs/FINDINGS.md` section 1b has the log lines.
///
/// What it cannot do: the kernel puts the Mac to sleep inside the call that clears the last bit when the lid is already closed,
/// so a clear that arrives after the lid has closed cannot be undone in time. Nothing observed so far does that.
///
/// Two rules keep this from ever making things worse, because all the keeper does is set the override:
/// - `stop()` returns only when no call is in flight and none can start afterwards, so the release that follows it has the last word.
/// - The keeper applies the override only while its owner keeps saying it is alive (`alive()`, once per loop iteration). An owner
///   that hangs stops being backed by the keeper after `maxSilence` seconds, well before the guard process's own timeout releases
///   the Mac, so the keeper can never undo the guard's release.
public final class OverrideKeeper {
    public struct Timing: Sendable, Equatable {
        /// Seconds between two applications while nothing special happens.
        public var interval: TimeInterval
        /// After `kick()`, extra applications at these delays (seconds). Kicks closer together than `coalesce` count as one.
        public var burst: [TimeInterval]
        public var coalesce: TimeInterval
        /// How long the owner may stay silent, counted in seconds of awake time, before the keeper stops applying.
        public var maxSilence: TimeInterval

        public init(interval: TimeInterval, burst: [TimeInterval], coalesce: TimeInterval, maxSilence: TimeInterval) {
            self.interval = interval
            self.burst = burst
            self.coalesce = coalesce
            self.maxSilence = maxSilence
        }

        /// A quarter of a second is far inside the 0.69 s that was seen between powerd clearing the flag and the kernel hearing
        /// about the lid. One call costs about 60 microseconds (measured), so this is a few hundredths of a percent of one core.
        public static let standard = Timing(interval: 0.25, burst: [0.05, 0.1, 0.2, 0.4, 0.8, 1.6], coalesce: 0.05, maxSilence: 30)
    }

    private let override: LidOverride
    private let timing: Timing
    private let uptime: () -> TimeInterval
    private let log: (String) -> Void
    private let queue = DispatchQueue(label: "io.github.fedebartoli.halflid.override-keeper", qos: .userInitiated)

    // Everything below is read and written on `queue` only.
    private var timer: DispatchSourceTimer?
    private var generation = 0
    private var lastAlive: TimeInterval = 0
    private var lastKick: TimeInterval = -.infinity
    private var failures = 0
    private var applications = 0
    private var activity: NSObjectProtocol?

    /// - Parameter uptime: seconds of awake time; the default does not advance while the Mac sleeps, so a long sleep never
    ///   looks like a silent owner.
    public init(
        override: LidOverride, timing: Timing = .standard,
        uptime: @escaping () -> TimeInterval = { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 },
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.override = override
        self.timing = timing
        self.uptime = uptime
        self.log = log
    }

    deinit {
        timer?.cancel()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
    }

    /// Starts applying the override on a timer. The caller applies it once itself first (and handles that call failing); the
    /// keeper only keeps it applied. Calling it again while running changes nothing, except that it counts as `alive()`.
    public func start() {
        let now = uptime()
        queue.sync {
            lastAlive = now
            guard timer == nil else { return }
            generation &+= 1
            let source = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            let period = DispatchTimeInterval.nanoseconds(Int(timing.interval * 1_000_000_000))
            source.schedule(deadline: .now() + period, repeating: period, leeway: .milliseconds(10))
            source.setEventHandler { [weak self] in self?.applyIfOwnerAlive() }
            source.resume()
            timer = source
            // A menu bar app with no window is a candidate for App Nap, which stretches timers to a second or more: that would
            // undo the point of this class. This asks for precise timers; it does not hold the Mac awake by itself.
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Half Lid keeps the lid override applied while it holds the Mac awake"
            )
        }
    }

    /// Stops the timer and drops everything still scheduled. Once this returns no further call to the override is made, so a
    /// release made afterwards cannot be undone. Safe to call when not running. Must not be called from `log`.
    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            generation &+= 1
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
    }

    /// The owner is alive: call once per loop iteration.
    public func alive() {
        let now = uptime()
        queue.async { [self] in lastAlive = max(lastAlive, now) }
    }

    /// Something that can change the flag just happened (lid, display, power source, wake): apply now and again a few times
    /// over the next seconds, which is where the next write by powerd is most likely. Ignored when not running.
    public func kick() {
        let now = uptime()
        queue.async { [self] in
            guard timer != nil, now - lastKick >= timing.coalesce else { return }
            lastKick = now
            applyIfOwnerAlive()
            let current = generation
            for delay in timing.burst {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.timer != nil, self.generation == current else { return }
                    self.applyIfOwnerAlive()
                }
            }
        }
    }

    public var isRunning: Bool { queue.sync { timer != nil } }

    /// How many times the override has been applied by the keeper (for tests and diagnostics).
    public var applicationCount: Int { queue.sync { applications } }

    private func applyIfOwnerAlive() {
        guard uptime() - lastAlive <= timing.maxSilence else { return }
        applications += 1
        do {
            try override.setLidCloseIgnored(true)
            failures = 0
        } catch {
            failures += 1
            // The loop's own re-assertion reports a failing override to the user; the keeper only keeps trying, quietly.
            if failures == 1 || failures % 100 == 0 { log("override keeper: call failed (\(failures) in a row): \(error)") }
        }
    }
}
