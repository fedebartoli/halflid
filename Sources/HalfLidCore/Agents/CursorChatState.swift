import Foundation
import SQLite3

// Cursor keeps one row per chat in a local SQLite database. From a few state fields we can tell, chat by chat, whether
// the agent is working, waiting for an answer from the user, or idle. A chat waiting on a question must NOT count as work:
// to the process table (CPU, sleep assertions) it looks exactly like a working one.
//
// Privacy: queries extract only state fields (status, tool name and status, timestamps). Message text is never selected,
// so it never enters this process. The database is opened read-only. Never written, never copied.
//
// This depends on Cursor's internal format, which can change in any release. Everything that does is in this file. If a
// read fails the caller falls back to "unknown" and the user keeps the manual hold.
// Rules derived from measurements on macOS 26.5.2 with Cursor, see docs/DECISIONS.md section 3.

public enum ChatActivity: String, Equatable, Sendable {
    case working
    case waitingForUser
    case idle
}

/// What we know about one step (bubble) of a chat, without its text.
public struct BubbleFacts: Equatable, Sendable {
    public var createdAt: Date?
    public var toolName: String?
    /// `loading` while the tool runs, then `completed`, `cancelled`, `error`.
    public var toolStatus: String?
    /// For a question: `pending` until answered, then `submitted`.
    public var additionalStatus: String?
    /// `Requested` while a tool waits for the user's approval (Run / Skip).
    public var reviewStatus: String?
    public var approvalType: String?

    public init(
        createdAt: Date? = nil, toolName: String? = nil, toolStatus: String? = nil, additionalStatus: String? = nil,
        reviewStatus: String? = nil, approvalType: String? = nil
    ) {
        self.createdAt = createdAt
        self.toolName = toolName
        self.toolStatus = toolStatus
        self.additionalStatus = additionalStatus
        self.reviewStatus = reviewStatus
        self.approvalType = approvalType
    }
}

public struct ChatFacts: Equatable, Sendable {
    public var id: String
    /// Header `unfinishedRunAt`: set while a run is in progress. Not always written (not after an answered question).
    public var runStartedAt: Date?
    /// Header `conversationCheckpointLastUpdatedAt`: refreshed every 30 to 60 s while a run is in progress.
    public var checkpointAt: Date?
    /// `composerData.status`: `completed` at rest, `aborted` during a run (and after a manual stop).
    public var status: String?
    public var queueLength: Int
    public var last: BubbleFacts?
    public var previous: BubbleFacts?

    public init(
        id: String, runStartedAt: Date? = nil, checkpointAt: Date? = nil, status: String? = nil, queueLength: Int = 0,
        last: BubbleFacts? = nil, previous: BubbleFacts? = nil
    ) {
        self.id = id
        self.runStartedAt = runStartedAt
        self.checkpointAt = checkpointAt
        self.status = status
        self.queueLength = queueLength
        self.last = last
        self.previous = previous
    }
}

public struct CursorActivityRules: Equatable, Sendable {
    /// Chats whose last user message is older than this are not looked at (a leftover run cannot be older).
    public var windowSeconds = 12.0 * 3600
    /// A running chat must show a sign of life this recently (checkpoint or new step), otherwise the run is a leftover.
    public var aliveSeconds = 300.0
    /// Without the header flag, a new step this recent means the agent is working.
    public var recentStepSeconds = 120.0

    public init() {}
}

public enum CursorChatClassifier {
    /// Approvals Cursor grants by itself: nobody is waiting.
    private static let automaticApprovals: Set<String> = ["allowlist", "full_auto"]

    static func isPendingQuestion(_ bubble: BubbleFacts?) -> Bool {
        guard let bubble, bubble.toolName == "ask_question" else { return false }
        if bubble.additionalStatus == "submitted" { return false }
        return bubble.toolStatus == "loading" || bubble.additionalStatus == "pending"
    }

    static func isPendingApproval(_ bubble: BubbleFacts?) -> Bool {
        guard let bubble, bubble.reviewStatus == "Requested" else { return false }
        if bubble.toolName == "ask_question" || bubble.toolName == "create_plan" { return false }
        if let type = bubble.approvalType, automaticApprovals.contains(type) { return false }
        return true
    }

    public static func classify(_ chat: ChatFacts, now: Date, rules: CursorActivityRules = CursorActivityRules()) -> ChatActivity {
        // Waiting for the user beats everything: the agent's turn is over until a human answers.
        if isPendingQuestion(chat.last) || isPendingApproval(chat.last) || isPendingApproval(chat.previous) {
            return .waitingForUser
        }
        // Cursor's own definition of a finished turn: `completed` with nothing queued. Mid-run it is never `completed`.
        if chat.status == "completed" && chat.queueLength == 0 { return .idle }

        // Not completed: working only with a recent sign of life, otherwise it is a leftover (Cursor quit mid-run, manual stop).
        let lastStepAt = chat.last?.createdAt
        let lastSign = [chat.checkpointAt, lastStepAt].compactMap { $0 }.max()
        guard let lastSign, now.timeIntervalSince(lastSign) < rules.aliveSeconds else { return .idle }

        if let started = chat.runStartedAt, now.timeIntervalSince(started) < rules.windowSeconds { return .working }
        if chat.last?.toolStatus == "loading" { return .working }
        if let lastStepAt, now.timeIntervalSince(lastStepAt) < rules.recentStepSeconds { return .working }
        // The agent is processing an answer just given: the header run flag is not written in that phase.
        if chat.last?.toolName == "ask_question" && chat.last?.additionalStatus == "submitted" { return .working }
        return .idle
    }
}

public struct CursorChat: Equatable, Sendable {
    /// First 8 characters of Cursor's chat id. Never the chat name.
    public var id: String
    public var activity: ChatActivity

    public init(id: String, activity: ChatActivity) {
        self.id = id
        self.activity = activity
    }
}

public struct CursorActivity: Equatable, Sendable {
    public var chats: [CursorChat]

    public init(chats: [CursorChat]) { self.chats = chats }

    public var working: Int { chats.filter { $0.activity == .working }.count }
    public var waitingForUser: Int { chats.filter { $0.activity == .waitingForUser }.count }
    public var idle: Int { chats.filter { $0.activity == .idle }.count }
}

public enum CursorStateError: Error, Equatable {
    case databaseMissing
    case openFailed(Int32)
    case queryFailed(String)
}

/// Reads chat states from Cursor's database. Each `read` opens the database, runs a few short queries and closes it,
/// so no read transaction stays open while Cursor writes.
public final class CursorStateReader {
    public static var defaultPath: String {
        NSString(string: "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb").expandingTildeInPath
    }

    private let path: String
    private let rules: CursorActivityRules

    public init(path: String = CursorStateReader.defaultPath, rules: CursorActivityRules = CursorActivityRules()) {
        self.path = path
        self.rules = rules
    }

    public var isAvailable: Bool { FileManager.default.fileExists(atPath: path) }

    public func read(now: Date = Date()) throws -> CursorActivity {
        guard isAvailable else { throw CursorStateError.databaseMissing }
        var handle: OpaquePointer?
        let opened = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard opened == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw CursorStateError.openFailed(opened)
        }
        // The chat records are large JSON blobs: hand the memory back after every read instead of keeping it resident.
        defer {
            sqlite3_close(db)
            malloc_zone_pressure_relief(nil, 0)
        }
        sqlite3_busy_timeout(db, 1500)
        try execute(db, "PRAGMA query_only = ON")
        try execute(db, "PRAGMA cache_size = -256")

        let chats = try headers(db, now: now).map { header -> CursorChat in
            let facts = try chatFacts(db, header: header)
            return CursorChat(id: String(header.id.prefix(8)), activity: CursorChatClassifier.classify(facts, now: now, rules: rules))
        }
        return CursorActivity(chats: chats)
    }

    // MARK: queries (state fields only, never message text)

    private struct Header {
        var id: String
        var runStartedAt: Date?
        var checkpointAt: Date?
    }

    private func headers(_ db: OpaquePointer, now: Date) throws -> [Header] {
        let sql = """
        SELECT composerId,
               json_extract(value, '$.unfinishedRunAt'),
               json_extract(value, '$.conversationCheckpointLastUpdatedAt')
          FROM composerHeaders
         WHERE COALESCE(isArchived, 0) = 0 AND COALESCE(isSubagent, 0) = 0 AND COALESCE(lastUpdatedAt, 0) > ?
         ORDER BY lastUpdatedAt DESC
        """
        let since = Int64((now.timeIntervalSince1970 - rules.windowSeconds) * 1000)
        return try query(db, sql, [.int(since)]) { row in
            guard let id = row.text(0) else { return nil }
            return Header(id: id, runStartedAt: row.milliseconds(1), checkpointAt: row.milliseconds(2))
        }
    }

    private func chatFacts(_ db: OpaquePointer, header: Header) throws -> ChatFacts {
        let tailSQL = """
        SELECT json_extract(value, '$.status'),
               json_array_length(value, '$.queueItems'),
               json_extract(value, '$.fullConversationHeadersOnly[#-1].bubbleId'),
               json_extract(value, '$.fullConversationHeadersOnly[#-2].bubbleId')
          FROM cursorDiskKV WHERE key = ?
        """
        typealias Tail = (status: String?, queue: Int, last: String?, previous: String?)
        let tails: [Tail] = try query(db, tailSQL, [.text("composerData:\(header.id)")]) { row in
            (row.text(0), Int(row.int(1) ?? 0), row.text(2), row.text(3))
        }
        var facts = ChatFacts(id: header.id, runStartedAt: header.runStartedAt, checkpointAt: header.checkpointAt)
        guard let tail = tails.first else { return facts }
        facts.status = tail.status
        facts.queueLength = tail.queue
        if let lastId = tail.last { facts.last = try bubble(db, chat: header.id, bubble: lastId) }
        // Cursor looks for a pending approval among the last two steps; the earlier one only matters while not at rest.
        if tail.status != "completed", let previousId = tail.previous { facts.previous = try bubble(db, chat: header.id, bubble: previousId) }
        return facts
    }

    private func bubble(_ db: OpaquePointer, chat: String, bubble: String) throws -> BubbleFacts? {
        let sql = """
        SELECT json_extract(value, '$.createdAt'),
               json_extract(value, '$.toolFormerData.name'),
               json_extract(value, '$.toolFormerData.status'),
               json_extract(value, '$.toolFormerData.additionalData.status'),
               json_extract(value, '$.toolFormerData.additionalData.reviewData.status'),
               json_extract(value, '$.toolFormerData.additionalData.reviewData.approvalType')
          FROM cursorDiskKV WHERE key = ?
        """
        return try query(db, sql, [.text("bubbleId:\(chat):\(bubble)")]) { row in
            BubbleFacts(
                createdAt: row.date(0), toolName: row.text(1), toolStatus: row.text(2), additionalStatus: row.text(3),
                reviewStatus: row.text(4), approvalType: row.text(5)
            )
        }.first
    }

    // MARK: minimal SQLite wrapper

    private enum Binding {
        case int(Int64)
        case text(String)
    }

    private struct Row {
        let statement: OpaquePointer

        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }

        func text(_ column: Int32) -> String? {
            guard !isNull(column), let value = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: value)
        }

        func int(_ column: Int32) -> Int64? {
            isNull(column) ? nil : sqlite3_column_int64(statement, column)
        }

        /// Integer milliseconds since 1970 (the header fields).
        func milliseconds(_ column: Int32) -> Date? {
            guard let value = int(column), value > 0 else { return nil }
            return Date(timeIntervalSince1970: Double(value) / 1000)
        }

        /// ISO 8601 text with fractional seconds, or milliseconds as a number.
        func date(_ column: Int32) -> Date? {
            guard let value = text(column) else { return nil }
            if let milliseconds = Double(value) { return Date(timeIntervalSince1970: milliseconds / 1000) }
            let withFraction = ISO8601DateFormatter()
            withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = withFraction.date(from: value) { return parsed }
            return ISO8601DateFormatter().date(from: value)
        }
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw CursorStateError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query<T>(_ db: OpaquePointer, _ sql: String, _ bindings: [Binding], _ map: (Row) -> T?) throws -> [T] {
        var handle: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK, let statement = handle else {
            throw CursorStateError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, binding) in bindings.enumerated() {
            let position = Int32(index + 1)
            switch binding {
            case .int(let value): sqlite3_bind_int64(statement, position, value)
            case .text(let value): sqlite3_bind_text(statement, position, value, -1, transient)
            }
        }
        var results: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                if let value = map(Row(statement: statement)) { results.append(value) }
            } else if step == SQLITE_DONE {
                return results
            } else {
                throw CursorStateError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }
}
