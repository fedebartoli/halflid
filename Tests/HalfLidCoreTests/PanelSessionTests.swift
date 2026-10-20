import Foundation
import HalfLidCore

private func sampleContent(title: String = "Ready") -> PanelContent {
    let agents = AgentCatalog(agents: [AgentDefinition(id: "cursor"), AgentDefinition(id: "codex")])
    let status = AgentLoop.Status(armed: false, indicator: .idle)
    let catalog = Catalog.load(directory: repositoryRoot.appendingPathComponent("Resources/i18n"), preferred: ["en"])
    var content = PanelPresenter.present(status: status, preferences: Preferences(), agents: agents, lastSession: nil, catalog: catalog)
    content.title = title
    return content
}

/// Waits for a callback from the session's own queue.
private final class Mailbox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    private let signal = DispatchSemaphore(value: 0)

    func put(_ item: T) {
        lock.lock(); items.append(item); lock.unlock()
        signal.signal()
    }

    func waitForCount(_ count: Int, seconds: Double = 5) -> [T] {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            lock.lock(); let current = items; lock.unlock()
            if current.count >= count || Date() > deadline { return current }
            _ = signal.wait(timeout: .now() + 0.1)
        }
    }
}

func runPanelSessionTests() {
    // Wire format: every message is one line and survives a round trip.
    let requests: [PanelRequest] = [.hold(minutes: 30), .hold(minutes: 0), .stopHold, .setWatching(agentId: "codex", on: false), .openSettings, .dismissHint, .quit]
    for request in requests {
        let line = PanelWire.line(request)
        expect(line.last == 0x0A && line.dropLast().firstIndex(of: 0x0A) == nil, "a request is exactly one line: \(request)")
        expect(PanelWire.decode(PanelRequest.self, from: line.dropLast()) == request, "a request survives a round trip: \(request)")
    }
    let content = sampleContent()
    let contentLine = PanelWire.line(content)
    expect(contentLine.dropLast().firstIndex(of: 0x0A) == nil, "content is one line")
    expect(PanelWire.decode(PanelContent.self, from: contentLine.dropLast()) == content, "content survives a round trip")
    expect(PanelWire.decode(PanelRequest.self, from: Data("not json".utf8)) == nil, "garbage decodes to nothing")

    // Lines arrive in arbitrary pieces.
    var buffer = LineBuffer()
    expect(buffer.append(Data("ab".utf8)).isEmpty, "a partial line is held back")
    expect(buffer.append(Data("c\nde".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["abc"], "the line completes with the next piece")
    expect(buffer.append(Data("f\n\n\ng\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["def", "g"], "empty lines are skipped")
    var flooded = LineBuffer()
    expect(flooded.append(Data(repeating: 0x61, count: (1 << 20) + 10)).isEmpty, "a line without end is not delivered")
    expect(flooded.append(Data("x\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["x"], "an over-long line is dropped and the stream recovers")

    // A real child process stands in for the panel: it sends two requests, then copies the first line it receives to a file.
    let directory = NSTemporaryDirectory() + "halflid-panel-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: directory) }
    var scripted = Data()
    scripted.append(PanelWire.line(PanelRequest.hold(minutes: 30)))
    scripted.append(PanelWire.line(PanelRequest.setWatching(agentId: "codex", on: false)))
    try? scripted.write(to: URL(fileURLWithPath: directory + "/requests.txt"))
    let script = directory + "/panel.sh"
    try? "#!/bin/sh\ncat \"$1\"\nread line\necho \"$line\" > \"$2\"\n".write(toFile: script, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)

    let received = Mailbox<PanelRequest>()
    let exits = Mailbox<Bool>()
    let queue = DispatchQueue(label: "halflid.test.panel")
    let session = PanelSession(
        executable: URL(fileURLWithPath: script), arguments: [directory + "/requests.txt", directory + "/received.txt"], callbackQueue: queue,
        onRequest: { received.put($0) }, onExit: { exits.put(true) }
    )
    expect(!session.isRunning, "a session is not running before it starts")
    do { try session.start() } catch { expect(false, "the stand-in panel starts: \(error)") }
    expect(session.isRunning, "the panel runs after start")
    session.send(content)
    session.send(content) // identical: must not be sent twice
    expect(received.waitForCount(2) == [.hold(minutes: 30), .setWatching(agentId: "codex", on: false)], "requests arrive in order")
    expect(exits.waitForCount(1).count == 1, "the exit of the panel is reported")
    expect(!session.isRunning, "the session is over once the panel exited")
    let echoed = (try? String(contentsOfFile: directory + "/received.txt", encoding: .utf8)) ?? ""
    expect(PanelWire.decode(PanelContent.self, from: Data(echoed.utf8).dropLast()) == content, "the panel received the content")
    session.send(content) // after the end: nothing happens, and above all no crash from a broken pipe

    // A panel that sends a request and leaves at once (Quit, Settings) must have the request delivered before its exit.
    var farewell = Data()
    farewell.append(PanelWire.line(PanelRequest.quit))
    try? farewell.write(to: URL(fileURLWithPath: directory + "/farewell.txt"))
    let quick = directory + "/quick.sh"
    try? "#!/bin/sh\ncat \"$1\"\n".write(toFile: quick, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: quick)
    let events = Mailbox<String>()
    let leaver = PanelSession(
        executable: URL(fileURLWithPath: quick), arguments: [directory + "/farewell.txt"], callbackQueue: queue,
        onRequest: { events.put("request:\($0)") }, onExit: { events.put("exit") }
    )
    do { try leaver.start() } catch { expect(false, "the quick stand-in panel starts: \(error)") }
    expect(events.waitForCount(2) == ["request:quit", "exit"], "a request sent just before the panel exits is delivered, before the exit")

    // `close` ends a panel that does not leave by itself, and reports it.
    let stubborn = Mailbox<Bool>()
    let sleeper = PanelSession(
        executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], callbackQueue: queue, onRequest: { _ in }, onExit: { stubborn.put(true) }
    )
    do { try sleeper.start() } catch { expect(false, "sleep starts as a stand-in panel: \(error)") }
    sleeper.close()
    expect(stubborn.waitForCount(1, seconds: 3).count == 1, "close ends a panel that does not leave by itself")

    // An executable that does not exist is an error, not a crash.
    let missing = PanelSession(executable: URL(fileURLWithPath: "/nonexistent/halflid-panel"), arguments: [], onRequest: { _ in }, onExit: {})
    var failed = false
    do { try missing.start() } catch { failed = true }
    expect(failed && !missing.isRunning, "a missing panel executable is reported as an error")
}
