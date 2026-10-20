import Foundation

/// Screen-related side effects. The real implementation (private APIs, `pmset displaysleepnow`) lives in the app layer so
/// the core can be tested without locking the screen of whoever runs the tests.
public protocol ScreenControl: AnyObject {
    func lockScreen()
    func displayOff()
    func restoreScreen()
    /// If the Mac is still awake after `afterSeconds` with the lid closed, put it to sleep.
    func sleepIfStillAwake(afterSeconds: Int)
    /// Forget a sleep request made by `sleepIfStillAwake` (work resumed before it fired).
    func cancelPendingSleep()
}

public protocol NoticeSink: AnyObject {
    func post(_ notice: Notice)
}

/// Applies the controller's actions to the system. Returns whether arming succeeded so the caller can tell the controller.
public final class ActionExecutor {
    private let override: LidOverride
    private let screen: ScreenControl
    private let notices: NoticeSink
    private let keeper: OverrideKeeper?
    private let log: (String) -> Void

    /// - Parameter keeper: re-applies the override several times a second while armed (see `OverrideKeeper`). `nil` in tests
    ///   that count calls to the override one by one.
    public init(
        override: LidOverride, screen: ScreenControl, notices: NoticeSink, keeper: OverrideKeeper? = nil,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.override = override
        self.screen = screen
        self.notices = notices
        self.keeper = keeper
        self.log = log
    }

    /// Something that can change the lid flag just happened (lid, display, power source, wake). Safe from any thread.
    public func overrideMayHaveChanged() {
        keeper?.kick()
    }

    /// - Returns: `false` if the override could not be applied (`arm` or `reassert` failed). In that case the screen actions
    ///   of the same batch are skipped: the Mac will sleep on lid close anyway, so locking and dimming would only confuse.
    @discardableResult
    public func apply(_ actions: [Action]) -> Bool {
        // Called once per loop iteration, so it doubles as the proof of life the keeper needs.
        keeper?.alive()
        var overrideOK = true
        for action in actions {
            switch action {
            case .arm, .reassert:
                do {
                    try override.setLidCloseIgnored(true)
                    keeper?.start()
                    if action == .arm { screen.cancelPendingSleep() }
                } catch {
                    log("override failed: \(error)")
                    overrideOK = false
                    notices.post(.stopped(.overrideFailed))
                }
            case .disarm:
                // The keeper first: once it has stopped nothing can set the override again behind the release.
                keeper?.stop()
                release()
            case .lockScreen where overrideOK:
                screen.lockScreen()
            case .displayOff where overrideOK:
                screen.displayOff()
            case .restoreScreen:
                screen.restoreScreen()
            case .ensureSleep(let seconds):
                screen.sleepIfStillAwake(afterSeconds: seconds)
            case .notify(let notice):
                notices.post(notice)
            case .lockScreen, .displayOff:
                break
            }
        }
        return overrideOK
    }

    /// Removing the override is the safety-critical step: try more than once before giving up (the guard process still backs it up).
    private func release() {
        for attempt in 1...3 {
            do {
                try override.setLidCloseIgnored(false)
                return
            } catch {
                log("release attempt \(attempt) failed: \(error)")
                if attempt < 3 { Thread.sleep(forTimeInterval: 0.2) }
            }
        }
    }
}
