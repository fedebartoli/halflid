import Foundation
import HalfLidCore

// The keeper runs on a queue of its own, so these tests wait on real (short) intervals. They assert minimum counts, or exact
// zeros where the claim is "never", so a slow machine can only make a test wait longer, not fail it.

/// A lid override that records every call from any thread.
private final class KeeperOverride: LidOverride {
    private let lock = NSLock()
    private var calls: [Bool] = []
    private var failing = false

    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return calls }
    var count: Int { values.count }
    var last: Bool? { values.last }

    var failsEveryCall: Bool {
        get { lock.lock(); defer { lock.unlock() }; return failing }
        set { lock.lock(); failing = newValue; lock.unlock() }
    }

    func setLidCloseIgnored(_ ignored: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        calls.append(ignored)
        if failing { throw LidOverrideError.callFailed(-1) }
    }
}

/// A clock the test moves by hand; read from the keeper's queue, written from the test.
private final class KeeperClock {
    private let lock = NSLock()
    private var seconds: TimeInterval = 1000
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return seconds }
    func advance(_ delta: TimeInterval) { lock.lock(); seconds += delta; lock.unlock() }
}

private final class KeeperLog {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

private final class KeeperScreen: ScreenControl {
    func lockScreen() {}
    func displayOff() {}
    func restoreScreen() {}
    func sleepIfStillAwake(afterSeconds: Int) {}
    func cancelPendingSleep() {}
}

private final class KeeperNotices: NoticeSink {
    func post(_ notice: Notice) {}
}

private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

/// Polls until `condition` holds or `timeout` passes. Returns whether it held.
private func waitFor(_ timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if condition() { return true }
        pause(0.005)
    }
    return condition()
}

func runKeeperTests() {
    let fast = OverrideKeeper.Timing(interval: 0.02, burst: [0.01, 0.02], coalesce: 0.005, maxSilence: 60)
    // A long interval isolates what `kick()` does from what the timer does.
    let quiet = OverrideKeeper.Timing(interval: 30, burst: [0.02, 0.04], coalesce: 0.001, maxSilence: 60)

    // The shipped timing has to beat the window that was measured: 0.687 s from powerd clearing the flag to the kernel hearing
    // that the lid had closed. Several applications must fit in it, even when the timer is late.
    let standard = OverrideKeeper.Timing.standard
    expect(standard.interval <= 0.25, "keeper: applies at least four times a second")
    expect(standard.interval * 2 < 0.687, "keeper: at least two applications fit in the measured 0.687 s window")
    expect(standard.maxSilence >= 10 && standard.maxSilence < 120, "keeper: gives up before the guard's 120 s heartbeat timeout")
    expect(standard.burst == standard.burst.sorted() && standard.burst.first! < standard.interval, "keeper: bursts start quickly and widen")

    // Nothing happens before start, and start/stop switch the timer on and off.
    do {
        let override = KeeperOverride()
        let keeper = OverrideKeeper(override: override, timing: fast)
        pause(0.08)
        expect(override.count == 0, "keeper: idle until started")
        expect(!keeper.isRunning, "keeper: not running before start")
        keeper.start()
        expect(keeper.isRunning, "keeper: running after start")
        expect(waitFor { override.count >= 4 }, "keeper: applies repeatedly once started")
        expect(override.values.allSatisfy { $0 }, "keeper: only ever sets the override, never clears it")
        keeper.stop()
        expect(!keeper.isRunning, "keeper: not running after stop")
        let atStop = override.count
        pause(0.15)
        expect(override.count == atStop, "keeper: no call at all after stop returns")
        keeper.stop() // twice is harmless
        expect(!keeper.isRunning, "keeper: stopping twice is harmless")
        keeper.start()
        expect(waitFor { override.count >= atStop + 3 }, "keeper: can be started again after a stop")
        keeper.start() // already running: no second timer
        let rateBefore = override.count
        pause(0.2)
        let rateAfter = override.count - rateBefore
        expect(rateAfter <= 30, "keeper: starting twice does not double the timer (\(rateAfter) calls in 0.2 s at 20 ms)")
        keeper.stop()
    }

    // A kick applies at once and again over the next moments; kicks that follow each other closely count as one.
    do {
        let override = KeeperOverride()
        let keeper = OverrideKeeper(override: override, timing: quiet)
        keeper.kick()
        pause(0.15)
        expect(override.count == 0, "keeper: a kick does nothing while not running")
        keeper.start()
        pause(0.05)
        expect(override.count == 0, "keeper: starting does not apply by itself (the caller applies first)")
        keeper.kick()
        expect(waitFor { override.count >= 3 }, "keeper: a kick applies once at once and once for each burst step (got \(override.count))")
        pause(0.15)
        expect(override.count == 3, "keeper: and nothing else (got \(override.count))")
        keeper.stop()

        let coalescing = OverrideKeeper.Timing(interval: 30, burst: [0.03], coalesce: 0.5, maxSilence: 60)
        let second = KeeperOverride()
        let coalesced = OverrideKeeper(override: second, timing: coalescing)
        coalesced.start()
        coalesced.kick()
        coalesced.kick()
        coalesced.kick()
        pause(0.2)
        expect(second.count == 2, "keeper: kicks in quick succession are one burst (got \(second.count))")
        coalesced.stop()
    }

    // Nothing scheduled before a stop may run after it, including bursts waiting for their turn.
    do {
        let override = KeeperOverride()
        let slowBurst = OverrideKeeper.Timing(interval: 30, burst: [0.15], coalesce: 0.001, maxSilence: 60)
        let keeper = OverrideKeeper(override: override, timing: slowBurst)
        keeper.start()
        keeper.kick()
        expect(waitFor { override.count == 1 }, "keeper: the kick applies at once")
        keeper.stop()
        pause(0.3)
        expect(override.count == 1, "keeper: a burst step waiting at stop never runs")

        // Stopped and started again before the waiting step is due: it belongs to the earlier run and must not fire.
        keeper.start()
        keeper.kick()
        expect(waitFor { override.count == 2 }, "keeper: the second kick applies at once")
        keeper.stop()
        keeper.start()
        pause(0.35)
        expect(override.count == 2, "keeper: a burst from before a restart does not run after it (got \(override.count))")
        keeper.stop()
    }

    // An owner that stops saying it is alive is no longer backed; one that comes back is.
    do {
        let override = KeeperOverride()
        let clock = KeeperClock()
        let limited = OverrideKeeper.Timing(interval: 0.02, burst: [], coalesce: 0.001, maxSilence: 30)
        let keeper = OverrideKeeper(override: override, timing: limited, uptime: { clock.now() })
        keeper.start()
        expect(waitFor { override.count >= 3 }, "keeper: applies while the owner is fresh")
        clock.advance(31)
        pause(0.05) // lets calls already in flight finish
        let silent = override.count
        pause(0.2)
        expect(override.count == silent, "keeper: stops applying once the owner has been silent for longer than maxSilence")
        expect(keeper.isRunning, "keeper: the timer itself keeps running, so it can resume")
        keeper.alive()
        expect(waitFor { override.count > silent }, "keeper: resumes when the owner reports alive again")
        clock.advance(10)
        keeper.kick()
        pause(0.1)
        keeper.stop()
    }

    // A failing override is retried quietly and the failure is reported once, not on every call.
    do {
        let override = KeeperOverride()
        override.failsEveryCall = true
        let log = KeeperLog()
        let keeper = OverrideKeeper(override: override, timing: fast, log: { log.add($0) })
        keeper.start()
        expect(waitFor { override.count >= 8 }, "keeper: keeps trying while the override fails")
        keeper.stop()
        expect(log.all.count == 1, "keeper: reports a failing override once, not once per call (\(log.all.count) lines)")
        expect(log.all.first?.contains("1 in a row") == true, "keeper: the report says it was the first failure")
        override.failsEveryCall = false
        keeper.start()
        let before = override.count
        expect(waitFor { override.count >= before + 3 }, "keeper: recovers when the override works again")
        keeper.stop()
    }

    // Dropping the keeper while it runs leaves no timer behind.
    do {
        let override = KeeperOverride()
        var keeper: OverrideKeeper? = OverrideKeeper(override: override, timing: fast)
        keeper?.start()
        expect(waitFor { override.count >= 2 }, "keeper: running before it is dropped")
        keeper = nil
        pause(0.05)
        let atDrop = override.count
        pause(0.15)
        expect(override.count == atDrop, "keeper: a dropped keeper makes no more calls")
    }

    // The executor starts the keeper after a successful arm, and stops it BEFORE releasing: nothing may set the override again
    // behind the release.
    do {
        let override = KeeperOverride()
        let keeper = OverrideKeeper(override: override, timing: fast)
        let executor = ActionExecutor(override: override, screen: KeeperScreen(), notices: KeeperNotices(), keeper: keeper)
        expect(executor.apply([]), "keeper+executor: an empty batch succeeds")
        expect(!keeper.isRunning, "keeper+executor: not started by an empty batch")
        expect(executor.apply([.arm]), "keeper+executor: arm succeeds")
        expect(keeper.isRunning, "keeper+executor: arm starts the keeper")
        expect(override.values.first == true, "keeper+executor: the executor applies the override itself first")
        expect(waitFor { override.count >= 5 }, "keeper+executor: the keeper keeps applying between loop iterations")
        executor.overrideMayHaveChanged()
        pause(0.1)
        expect(executor.apply([.reassert]), "keeper+executor: reassert succeeds")
        expect(keeper.isRunning, "keeper+executor: reassert leaves the keeper running")
        expect(executor.apply([.disarm]), "keeper+executor: disarm succeeds")
        expect(!keeper.isRunning, "keeper+executor: disarm stops the keeper")
        let afterRelease = override.values
        expect(afterRelease.last == false, "keeper+executor: the release is the last word")
        pause(0.2)
        expect(override.values == afterRelease, "keeper+executor: nothing is applied after the release")
        expect(afterRelease.filter { !$0 }.count == 1, "keeper+executor: exactly one release")
    }

    // Hammer the stop-before-release ordering: with the keeper at its fastest, every release must stay the last call.
    do {
        var staleSets = 0
        for _ in 0..<40 {
            let override = KeeperOverride()
            let tight = OverrideKeeper.Timing(interval: 0.001, burst: [0.001, 0.002], coalesce: 0, maxSilence: 60)
            let keeper = OverrideKeeper(override: override, timing: tight)
            let executor = ActionExecutor(override: override, screen: KeeperScreen(), notices: KeeperNotices(), keeper: keeper)
            executor.apply([.arm])
            pause(0.004)
            executor.overrideMayHaveChanged()
            pause(0.002)
            executor.apply([.disarm])
            let atRelease = override.count
            pause(0.01)
            if override.count != atRelease || override.last != false { staleSets += 1 }
        }
        expect(staleSets == 0, "keeper+executor: in 40 rapid arm/release cycles the keeper never set the override after a release (\(staleSets))")
    }

    // A failing arm does not start the keeper, and the failure still reaches the caller.
    do {
        let override = KeeperOverride()
        override.failsEveryCall = true
        let keeper = OverrideKeeper(override: override, timing: fast)
        let executor = ActionExecutor(override: override, screen: KeeperScreen(), notices: KeeperNotices(), keeper: keeper)
        expect(!executor.apply([.arm]), "keeper+executor: a failing arm is reported")
        expect(!keeper.isRunning, "keeper+executor: a failing arm does not start the keeper")
        pause(0.1)
        expect(override.count == 1, "keeper+executor: and nothing retries behind the loop's back (got \(override.count))")
        override.failsEveryCall = false
        executor.apply([.disarm])
        expect(override.last == false, "keeper+executor: a release still works afterwards")
    }

    // A failing reassert while the keeper runs: the loop disarms, which stops the keeper.
    do {
        let override = KeeperOverride()
        let keeper = OverrideKeeper(override: override, timing: fast)
        let executor = ActionExecutor(override: override, screen: KeeperScreen(), notices: KeeperNotices(), keeper: keeper)
        executor.apply([.arm])
        override.failsEveryCall = true
        expect(!executor.apply([.reassert]), "keeper+executor: a failing reassert is reported")
        override.failsEveryCall = false
        executor.apply([.disarm])
        expect(!keeper.isRunning, "keeper+executor: the disarm that follows a failed reassert stops the keeper")
        pause(0.1)
        expect(override.last == false, "keeper+executor: and the release stays the last call")
    }

    // Without a keeper the executor behaves exactly as before.
    do {
        let override = KeeperOverride()
        let executor = ActionExecutor(override: override, screen: KeeperScreen(), notices: KeeperNotices())
        executor.apply([.arm])
        executor.overrideMayHaveChanged() // no keeper: nothing happens
        pause(0.05)
        expect(override.values == [true], "executor without keeper: one call per action, nothing in the background")
        executor.apply([.disarm])
        expect(override.values == [true, false], "executor without keeper: release applies")
    }
}
