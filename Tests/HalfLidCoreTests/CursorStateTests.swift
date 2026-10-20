import Foundation
import HalfLidCore
import SQLite3

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func ago(_ seconds: Double) -> Date { now.addingTimeInterval(-seconds) }

private func question(_ status: String = "pending", toolStatus: String = "completed", age: Double = 600) -> BubbleFacts {
    BubbleFacts(createdAt: ago(age), toolName: "ask_question", toolStatus: toolStatus, additionalStatus: status)
}

private func runningTool(age: Double = 5) -> BubbleFacts {
    BubbleFacts(createdAt: ago(age), toolName: "run_terminal_command_v2", toolStatus: "loading")
}

func runCursorStateTests() {
    classifierTests()
    readerTests()
}

private func classifierTests() {
    func classify(_ chat: ChatFacts) -> ChatActivity { CursorChatClassifier.classify(chat, now: now) }

    // Waiting for the user.
    expect(classify(ChatFacts(id: "a", status: "completed", last: question())) == .waitingForUser, "pending question at rest waits for the user")
    expect(classify(ChatFacts(id: "a", checkpointAt: ago(10), status: "aborted", last: question())) == .waitingForUser, "pending question wins over an aborted status")
    expect(classify(ChatFacts(id: "a", runStartedAt: ago(30), checkpointAt: ago(5), status: "aborted", last: question("pending", toolStatus: "loading", age: 3))) == .waitingForUser, "a question just posted already waits for the user")
    let approval = BubbleFacts(createdAt: ago(10), toolName: "run_terminal_command_v2", toolStatus: "loading", reviewStatus: "Requested", approvalType: "ask")
    expect(classify(ChatFacts(id: "a", runStartedAt: ago(60), checkpointAt: ago(5), status: "aborted", last: approval)) == .waitingForUser, "a tool waiting for approval waits for the user")
    expect(classify(ChatFacts(id: "a", runStartedAt: ago(60), checkpointAt: ago(5), status: "aborted", last: runningTool(), previous: approval)) == .waitingForUser, "an approval in the previous step still counts")
    let automatic = BubbleFacts(createdAt: ago(10), toolName: "run_terminal_command_v2", toolStatus: "loading", reviewStatus: "Requested", approvalType: "allowlist")
    expect(classify(ChatFacts(id: "a", runStartedAt: ago(60), checkpointAt: ago(5), status: "aborted", last: automatic)) == .working, "an automatic approval is not waiting")

    // Idle.
    expect(classify(ChatFacts(id: "a", checkpointAt: ago(5), status: "completed", last: BubbleFacts(createdAt: ago(5)))) == .idle, "completed turn is idle even right after the last step")
    expect(classify(ChatFacts(id: "a")) == .idle, "a chat without data is idle")
    expect(classify(ChatFacts(id: "a", runStartedAt: ago(5 * 3600), checkpointAt: ago(5 * 3600), status: "aborted", last: runningTool(age: 5 * 3600))) == .idle, "a run left over from hours ago is idle")
    expect(classify(ChatFacts(id: "a", runStartedAt: ago(600), checkpointAt: ago(600), status: "aborted", last: BubbleFacts(createdAt: ago(600)))) == .idle, "a run with no sign of life for 10 minutes is dead")
    expect(classify(ChatFacts(id: "a", checkpointAt: ago(600), status: "aborted", last: BubbleFacts(createdAt: ago(600)))) == .idle, "stopped by hand and quiet is idle")
    expect(classify(ChatFacts(id: "a", checkpointAt: ago(100), status: "aborted", last: BubbleFacts(createdAt: ago(400)))) == .idle, "alive checkpoint alone is not enough without a run flag or a recent step")

    // Working.
    expect(classify(ChatFacts(id: "a", runStartedAt: ago(60), checkpointAt: ago(10), status: "aborted", last: BubbleFacts(createdAt: ago(40)))) == .working, "run flag with a fresh checkpoint is working")
    expect(classify(ChatFacts(id: "a", checkpointAt: ago(20), status: "aborted", last: runningTool(age: 200))) == .working, "a tool still loading is working even without the run flag")
    expect(classify(ChatFacts(id: "a", checkpointAt: ago(20), status: "aborted", last: BubbleFacts(createdAt: ago(30), toolName: "read_file", toolStatus: "completed"))) == .working, "a very recent step is working")
    expect(classify(ChatFacts(id: "a", checkpointAt: ago(20), status: "aborted", last: question("submitted", age: 200))) == .working, "the agent processing an answer just given is working")
    expect(classify(ChatFacts(id: "a", checkpointAt: ago(20), status: "completed", queueLength: 1, last: BubbleFacts(createdAt: ago(30)))) == .working, "a queued message keeps the chat going")

    // Counting.
    let activity = CursorActivity(chats: [
        CursorChat(id: "1", activity: .working), CursorChat(id: "2", activity: .waitingForUser),
        CursorChat(id: "3", activity: .waitingForUser), CursorChat(id: "4", activity: .idle),
    ])
    expect(activity.working == 1 && activity.waitingForUser == 2 && activity.idle == 1, "activity counts")
}

// MARK: database fixture

private func exec(_ db: OpaquePointer, _ sql: String) {
    var message: UnsafeMutablePointer<CChar>?
    if sqlite3_exec(db, sql, nil, nil, &message) != SQLITE_OK {
        print("fixture SQL failed: \(message.map { String(cString: $0) } ?? "?")")
        failureCount += 1
    }
}

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func milliseconds(_ date: Date) -> Int64 { Int64(date.timeIntervalSince1970 * 1000) }

private let canary = "CANARY-MESSAGE-TEXT-MUST-NEVER-APPEAR"

private func bubbleJSON(createdAt: Date, tool: String? = nil, toolStatus: String? = nil, additional: String? = nil) -> String {
    var parts = ["\"createdAt\":\"\(iso(createdAt))\"", "\"type\":2", "\"text\":\"\(canary)\""]
    if let tool {
        var data = "\"name\":\"\(tool)\""
        if let toolStatus { data += ",\"status\":\"\(toolStatus)\"" }
        if let additional { data += ",\"additionalData\":{\"status\":\"\(additional)\"}" }
        parts.append("\"toolFormerData\":{\(data)}")
    }
    return "{" + parts.joined(separator: ",") + "}"
}

private struct FixtureChat {
    var id: String
    var lastUpdated: Date = ago(1000)
    var archived = false
    var subagent = false
    var runAt: Date?
    var checkpoint: Date?
    var status: String?
    var bubbles: [String] = []   // JSON of each bubble, oldest first
    var withComposerData = true
}

private func makeDatabase(at path: String, chats: [FixtureChat]) {
    var handle: OpaquePointer?
    guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
        expect(false, "fixture database can be created")
        return
    }
    defer { sqlite3_close(db) }
    exec(db, "CREATE TABLE composerHeaders(composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER, lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, value TEXT)")
    exec(db, "CREATE TABLE cursorDiskKV(key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
    for chat in chats {
        var header = ["\"name\":\"\(canary)\""]
        if let runAt = chat.runAt { header.append("\"unfinishedRunAt\":\(milliseconds(runAt))") }
        if let checkpoint = chat.checkpoint { header.append("\"conversationCheckpointLastUpdatedAt\":\(milliseconds(checkpoint))") }
        exec(db, "INSERT INTO composerHeaders VALUES('\(chat.id)','w',0,\(milliseconds(chat.lastUpdated)),\(chat.archived ? 1 : 0),\(chat.subagent ? 1 : 0),'{\(header.joined(separator: ","))}')")
        guard chat.withComposerData else { continue }
        let headers = chat.bubbles.indices.map { "{\"bubbleId\":\"b\($0)\",\"type\":2}" }.joined(separator: ",")
        let statusPart = chat.status.map { "\"status\":\"\($0)\"," } ?? ""
        exec(db, "INSERT INTO cursorDiskKV VALUES('composerData:\(chat.id)','{\(statusPart)\"queueItems\":[],\"fullConversationHeadersOnly\":[\(headers)]}')")
        for (index, bubble) in chat.bubbles.enumerated() {
            exec(db, "INSERT INTO cursorDiskKV VALUES('bubbleId:\(chat.id):b\(index)','\(bubble)')")
        }
    }
}

private func readerTests() {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("halflid-cursor-\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/state.vscdb"

    expect(CursorStateReader(path: path).isAvailable == false, "missing database is reported as unavailable")
    do {
        _ = try CursorStateReader(path: path).read(now: now)
        expect(false, "reading a missing database throws")
    } catch {
        expect(error as? CursorStateError == .databaseMissing, "missing database error is databaseMissing")
    }

    let chats: [FixtureChat] = [
        FixtureChat(id: "aaaaaaaa-1", runAt: ago(60), checkpoint: ago(10), status: "aborted",
                    bubbles: [bubbleJSON(createdAt: ago(100)), bubbleJSON(createdAt: ago(5), tool: "run_terminal_command_v2", toolStatus: "loading")]),
        FixtureChat(id: "bbbbbbbb-1", checkpoint: ago(3000), status: "completed",
                    bubbles: [bubbleJSON(createdAt: ago(3000), tool: "ask_question", toolStatus: "completed", additional: "pending")]),
        FixtureChat(id: "cccccccc-1", checkpoint: ago(4000), status: "completed", bubbles: [bubbleJSON(createdAt: ago(4000))]),
        FixtureChat(id: "dddddddd-1", archived: true, runAt: ago(60), checkpoint: ago(10), status: "aborted",
                    bubbles: [bubbleJSON(createdAt: ago(5), tool: "run_terminal_command_v2", toolStatus: "loading")]),
        FixtureChat(id: "eeeeeeee-1", subagent: true, runAt: ago(60), checkpoint: ago(10), status: "aborted",
                    bubbles: [bubbleJSON(createdAt: ago(5), tool: "run_terminal_command_v2", toolStatus: "loading")]),
        FixtureChat(id: "ffffffff-1", lastUpdated: ago(13 * 3600), runAt: ago(60), checkpoint: ago(10), status: "aborted",
                    bubbles: [bubbleJSON(createdAt: ago(5), tool: "run_terminal_command_v2", toolStatus: "loading")]),
        FixtureChat(id: "gggggggg-1", lastUpdated: ago(5 * 3600), runAt: ago(5 * 3600), checkpoint: ago(5 * 3600), status: "aborted",
                    bubbles: [bubbleJSON(createdAt: ago(5 * 3600), tool: "run_terminal_command_v2", toolStatus: "loading")]),
        FixtureChat(id: "hhhhhhhh-1", checkpoint: ago(20), status: "aborted",
                    bubbles: [bubbleJSON(createdAt: ago(200), tool: "ask_question", toolStatus: "completed", additional: "submitted")]),
        FixtureChat(id: "iiiiiiii-1", withComposerData: false),
    ]
    makeDatabase(at: path, chats: chats)

    let before = try? FileManager.default.attributesOfItem(atPath: path)
    do {
        let reader = CursorStateReader(path: path)
        expect(reader.isAvailable, "fixture database is available")
        let activity = try reader.read(now: now)
        let byId = Dictionary(uniqueKeysWithValues: activity.chats.map { ($0.id, $0.activity) })
        expect(byId["aaaaaaaa"] == .working, "database: running chat is working")
        expect(byId["bbbbbbbb"] == .waitingForUser, "database: pending question waits for the user")
        expect(byId["cccccccc"] == .idle, "database: completed chat is idle")
        expect(byId["dddddddd"] == nil, "database: archived chats are skipped")
        expect(byId["eeeeeeee"] == nil, "database: subagents are skipped")
        expect(byId["ffffffff"] == nil, "database: chats outside the time window are skipped")
        expect(byId["gggggggg"] == .idle, "database: a leftover run from hours ago is idle")
        expect(byId["hhhhhhhh"] == .working, "database: a chat processing an answer is working")
        expect(byId["iiiiiiii"] == .idle, "database: a header without conversation data is idle")
        expect(activity.chats.count == 6, "database: exactly the six visible chats are reported")

        // The reader must not leak message text or chat names: only ids and states exist in the result.
        let dump = String(describing: activity)
        expect(!dump.contains(canary), "database: message text and chat names never reach the result")
        expect(activity.chats.allSatisfy { $0.id.count == 8 }, "database: chat ids are shortened to 8 characters")
    } catch {
        expect(false, "database read succeeds: \(error)")
    }
    let after = try? FileManager.default.attributesOfItem(atPath: path)
    expect(before?[.modificationDate] as? Date == after?[.modificationDate] as? Date && before?[.size] as? Int == after?[.size] as? Int, "reading does not modify the database file")

    // Not a database at all: a clear error, not a crash and not a silent "idle".
    let garbage = dir + "/garbage"
    try? "this is not sqlite".write(toFile: garbage, atomically: true, encoding: .utf8)
    do {
        _ = try CursorStateReader(path: garbage).read(now: now)
        expect(false, "reading a non-database file throws")
    } catch {
        expect(error is CursorStateError, "reading a non-database file reports a CursorStateError")
    }

    // A database with a different layout (Cursor changed its format): error, so the caller can fall back.
    let other = dir + "/other.db"
    var handle: OpaquePointer?
    if sqlite3_open(other, &handle) == SQLITE_OK, let db = handle {
        exec(db, "CREATE TABLE unrelated(x INTEGER)")
        sqlite3_close(db)
    }
    do {
        _ = try CursorStateReader(path: other).read(now: now)
        expect(false, "reading a database with another layout throws")
    } catch {
        expect(error is CursorStateError, "a changed layout is reported, not guessed")
    }
}
