import Foundation

public struct WorkReport: Equatable, Sendable {
    /// Whether any watched agent is working right now (no grace period; the controller adds that).
    public var working: Bool
    /// Chat states from Cursor, `nil` when the module is off, Cursor is not running, or the state could not be read.
    public var cursor: CursorActivity?
    /// Why Cursor's state is missing although it is running and enabled (shown to the user; the manual hold still works).
    public var cursorProblem: String?
    /// Command-line agents judged to be working.
    public var workingAgents: [String]
    /// Every agent whose process or session files were seen, working or not.
    public var seenAgents: [String]

    public init(working: Bool = false, cursor: CursorActivity? = nil, cursorProblem: String? = nil, workingAgents: [String] = [], seenAgents: [String] = []) {
        self.working = working
        self.cursor = cursor
        self.cursorProblem = cursorProblem
        self.workingAgents = workingAgents
        self.seenAgents = seenAgents
    }
}

/// How a command-line agent is judged to be working from process signals alone. Deliberately simple.
/// [NOT VERIFIED] against the real agents: calibrated only with a simulated one (see docs/DECISIONS.md section 9).
public struct ProcessAgentRule: Equatable, Sendable {
    /// CPU of the agent's process tree, percent of one core, at or above which the agent counts as working.
    public var cpuThreshold = 15.0
    /// A session file written this recently counts as working.
    public var sessionFreshSeconds = 30.0

    public init() {}

    public func isWorking(_ signal: AgentSignal) -> Bool {
        guard signal.processCount > 0 else { return false }
        if signal.cpuPercent >= cpuThreshold { return true }
        if let age = signal.newestSessionAgeSeconds, age < sessionFreshSeconds { return true }
        return false
    }
}

/// Combines the agent modules into one answer: is anything working? Only enabled modules run; a disabled one costs nothing.
public final class WorkDetector {
    public typealias SignalSource = () -> [AgentSignal]
    public typealias CursorSource = () throws -> CursorActivity

    private let signals: SignalSource
    private let cursor: CursorSource
    private let rule: ProcessAgentRule
    private let cursorId: String

    public init(
        signals: @escaping SignalSource, cursor: @escaping CursorSource, rule: ProcessAgentRule = ProcessAgentRule(), cursorId: String = "cursor"
    ) {
        self.signals = signals
        self.cursor = cursor
        self.rule = rule
        self.cursorId = cursorId
    }

    public func detect(preferences: Preferences) -> WorkReport {
        var report = WorkReport()
        let seen = signals()
        report.seenAgents = seen.map(\.agentId)

        // Cursor: only when enabled and a Cursor process exists. The process table cannot tell working from waiting for
        // an answer (both look busy), so its signals are never used as a fallback: an unreadable state means "unknown".
        let cursorRunning = (seen.first { $0.agentId == cursorId }?.processCount ?? 0) > 0
        if preferences.cursorEnabled && cursorRunning {
            do {
                let activity = try cursor()
                report.cursor = activity
                if activity.working > 0 { report.working = true }
            } catch {
                report.cursorProblem = String(describing: error)
            }
        }

        // Command-line agents.
        for signal in seen where preferences.watchesCommandLineAgent(signal.agentId, cursorId: cursorId) {
            if rule.isWorking(signal) { report.workingAgents.append(signal.agentId) }
        }
        if !report.workingAgents.isEmpty { report.working = true }
        return report
    }
}
