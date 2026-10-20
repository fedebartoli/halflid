import Foundation

/// What the panel process asks the menu bar process to do. One JSON object per line on the panel's standard output.
public enum PanelRequest: Codable, Equatable, Sendable {
    /// Keep the Mac awake for this many minutes; `0` means until the user stops it.
    case hold(minutes: Int)
    case stopHold
    case setWatching(agentId: String, on: Bool)
    case openSettings
    /// The first-run welcome was dismissed.
    case dismissHint
    case quit
}

/// One JSON value per line, in both directions between the menu bar process and the panel process. Plain pipes: no sockets,
/// no XPC, nothing to register with the system.
public enum PanelWire {
    public static func line<T: Encodable>(_ value: T) -> Data {
        var data = (try? JSONEncoder().encode(value)) ?? Data()
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) -> T? {
        try? JSONDecoder().decode(type, from: line)
    }
}

/// Splits a byte stream into lines. Reads from a pipe can end in the middle of a line, so the remainder waits for more data.
public struct LineBuffer: Sendable {
    private var pending = Data()
    /// A line longer than this is dropped, so a misbehaving peer cannot make the buffer grow without limit.
    private let limit = 1 << 20

    public init() {}

    public mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            if !line.isEmpty { lines.append(Data(line)) }
            pending.removeSubrange(pending.startIndex...newline)
        }
        if pending.count > limit { pending.removeAll() }
        return lines
    }
}

/// The menu bar process's side of an open panel: starts the panel executable, feeds it the content to show, and delivers the
/// requests it sends back. The panel lives only while it is open, so the interface costs no memory the rest of the time.
public final class PanelSession {
    private let executable: URL
    private let arguments: [String]
    private let callbackQueue: DispatchQueue
    private let onRequest: (PanelRequest) -> Void
    private let onExit: () -> Void

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = LineBuffer()
    private var started = false
    private var lastSent: PanelContent?

    public init(
        executable: URL, arguments: [String], callbackQueue: DispatchQueue = .main,
        onRequest: @escaping (PanelRequest) -> Void, onExit: @escaping () -> Void
    ) {
        self.executable = executable
        self.arguments = arguments
        self.callbackQueue = callbackQueue
        self.onRequest = onRequest
        self.onExit = onExit
    }

    public var isRunning: Bool { started && process.isRunning }

    /// Throws if the executable cannot be started.
    public func start() throws {
        signal(SIGPIPE, SIG_IGN) // writing to a panel that just closed must not end this process
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.output.fileHandleForReading.readabilityHandler = nil
            // A last request written just before the panel exited (Settings, Quit) must still be delivered, and before the exit.
            let rest = (try? self.output.fileHandleForReading.readToEnd()) ?? Data()
            self.callbackQueue.async {
                self.deliver(rest)
                self.onExit()
            }
        }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            if data.isEmpty { // the panel closed its output
                handle.readabilityHandler = nil
                return
            }
            self.callbackQueue.async { self.deliver(data) }
        }
        try process.run()
        started = true
    }

    private func deliver(_ data: Data) {
        for line in buffer.append(data) {
            if let request = PanelWire.decode(PanelRequest.self, from: line) { onRequest(request) }
        }
    }

    /// Sends the content to show. Identical content is not sent again.
    public func send(_ content: PanelContent) {
        guard isRunning, content != lastSent else { return }
        lastSent = content
        try? input.fileHandleForWriting.write(contentsOf: PanelWire.line(content))
    }

    /// Asks the panel to go away. It also exits by itself when this process dies (its input closes).
    public func close() {
        guard started else { return }
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
