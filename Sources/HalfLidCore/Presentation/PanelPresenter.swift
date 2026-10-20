import Foundation

/// Everything the quick-actions panel shows, already turned into text. Pure and `Equatable`, so the interface can skip a
/// redraw when nothing changed and tests can check the content without any window.
public struct PanelContent: Equatable, Codable, Sendable {
    public enum AgentState: String, Codable, Sendable {
        /// Watched and judged to be working right now.
        case working
        /// Watched and running, but not working.
        case idle
        /// Watched, but no process was seen.
        case notRunning
        /// Not watched: the user switched this agent off.
        case off
    }

    public struct AgentRow: Equatable, Codable, Sendable {
        public var id: String
        public var name: String
        public var state: AgentState
        public var stateText: String
        public var watched: Bool
    }

    public var glyph: GlyphState
    public var title: String
    public var detail: String?
    /// One line about the last finished session; only while nothing is being held.
    public var sessionLine: String?
    /// A manual "keep awake" is active, so the panel offers to stop it instead of choosing a duration.
    public var holding: Bool
    public var agents: [AgentRow]
    /// A short first-run welcome, shown once above the status.
    public var hint: Hint?

    public struct Hint: Equatable, Codable, Sendable {
        public var text: String
        public var dismissLabel: String
    }
}

public enum PanelPresenter {
    public static func present(
        status: AgentLoop.Status, preferences: Preferences, agents: AgentCatalog, lastSession: SessionSummary?, catalog: Catalog,
        welcome: Bool = false, cursorId: String = "cursor"
    ) -> PanelContent {
        let summary = StatusPresenter.present(status, catalog: catalog)
        let rows = agents.agents.map { agent -> PanelContent.AgentRow in
            let isCursor = agent.id == cursorId
            let watched = isCursor ? preferences.cursorEnabled : preferences.watchesCommandLineAgent(agent.id, cursorId: cursorId)
            let working = isCursor ? (status.report.cursor?.working ?? 0) > 0 : status.report.workingAgents.contains(agent.id)
            let state: PanelContent.AgentState
            if !watched {
                state = .off
            } else if working {
                state = .working
            } else if status.report.seenAgents.contains(agent.id) {
                state = .idle
            } else {
                state = .notRunning
            }
            return PanelContent.AgentRow(
                id: agent.id, name: catalog.text("agent.\(agent.id)"), state: state,
                stateText: catalog.text("agent.state.\(state.rawValue)"), watched: watched
            )
        }
        let sessionLine = (!status.armed ? lastSession : nil).map { StatusPresenter.sessionLine($0, catalog: catalog) }
        return PanelContent(
            glyph: summary.glyph, title: summary.title, detail: summary.detail, sessionLine: sessionLine,
            holding: status.hold != .none, agents: rows,
            hint: welcome ? PanelContent.Hint(text: catalog.text("panel.welcome"), dismissLabel: catalog.text("panel.welcome.dismiss")) : nil
        )
    }
}
