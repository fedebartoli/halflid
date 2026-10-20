import Foundation

/// What the menu shows about the current state. Pure and catalog-driven, so the interface layer stays thin and testable.
public struct StatusPresentation: Equatable, Sendable {
    public var glyph: GlyphState
    public var title: String
    public var detail: String?

    public init(glyph: GlyphState, title: String, detail: String? = nil) {
        self.glyph = glyph
        self.title = title
        self.detail = detail
    }
}

public enum StatusPresenter {
    public static func present(_ status: AgentLoop.Status, catalog: Catalog) -> StatusPresentation {
        let glyph = GlyphState(rawValue: status.indicator.rawValue) ?? .idle

        if let latch = status.latch {
            return StatusPresentation(
                glyph: glyph, title: catalog.text("status.stopped"), detail: catalog.text("status.stopped.\(latch.rawValue)")
            )
        }

        if status.armed {
            let detail = status.indicator == .warning ? catalog.text("status.warning") : activeDetail(status, catalog: catalog)
            return StatusPresentation(glyph: glyph, title: catalog.text("status.active"), detail: detail)
        }

        let detail = status.report.cursorProblem == nil ? catalog.text("status.idle.detail") : catalog.text("status.cursorProblem")
        return StatusPresentation(glyph: glyph, title: catalog.text("status.idle"), detail: detail)
    }

    /// Names of the agents that are working right now, in a stable order (Cursor first).
    public static func workingNames(_ report: WorkReport, catalog: Catalog) -> [String] {
        var ids: [String] = []
        if (report.cursor?.working ?? 0) > 0 { ids.append("cursor") }
        ids.append(contentsOf: report.workingAgents.sorted())
        return ids.map { catalog.text("agent.\($0)") }
    }

    private static func activeDetail(_ status: AgentLoop.Status, catalog: Catalog) -> String {
        let names = workingNames(status.report, catalog: catalog)
        if !names.isEmpty { return catalog.text("status.active.working", ["agents": names.joined(separator: ", ")]) }
        return holdLine(status.hold, catalog: catalog) ?? catalog.text("status.active.grace")
    }

    /// "Held until 15:42" or "Held until you stop it" for a manual keep-awake; `nil` when there is none.
    public static func holdLine(_ hold: Hold, catalog: Catalog) -> String? {
        switch hold {
        case .none: return nil
        case .untilStopped: return catalog.text("status.hold.untilStopped")
        case .until(let date): return catalog.text("status.hold.until", ["time": clock(date)])
        }
    }

    /// `HH:mm` in the local time zone, without creating a date formatter (those keep several MB of locale data resident).
    static func clock(_ date: Date) -> String {
        var seconds = time_t(date.timeIntervalSince1970)
        var parts = tm()
        localtime_r(&seconds, &parts)
        return String(format: "%02d:%02d", Int(parts.tm_hour), Int(parts.tm_min))
    }

    /// "1 h 12 min", "35 min" or "under a minute".
    public static func duration(_ seconds: Double, catalog: Catalog) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 1 { return catalog.text("duration.short") }
        if minutes < 60 { return catalog.text("duration.minutes", ["m": String(minutes)]) }
        return catalog.text("duration.hours", ["h": String(minutes / 60), "m": String(minutes % 60)])
    }

    /// One line about the last finished session, for the menu.
    public static func sessionLine(_ summary: SessionSummary, catalog: Catalog) -> String {
        let ending: String
        switch summary.ending {
        case .finished: ending = catalog.text("session.ending.finished")
        case .quit: ending = catalog.text("session.ending.quit")
        case .limit: ending = catalog.text("session.ending.\(summary.stopReason?.rawValue ?? "finished")")
        }
        return catalog.text("session.last", ["duration": duration(summary.durationSeconds, catalog: catalog), "ending": ending])
    }
}
