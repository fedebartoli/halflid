import Foundation
import HalfLidCore

/// The commands meant for people: `status`, `start` and `stop` talk to the running app. (The rest of this tool is for
/// development and tests.) Each returns the process exit code: 0 done, 3 the app is not running, 4 command-line control is
/// turned off in the settings, 5 the app did not answer, 64 bad usage.
enum UserCommands {
    static let notRunning: Int32 = 3
    static let controlDisabled: Int32 = 4
    static let noAnswer: Int32 = 5
    static let badUsage: Int32 = 64

    static func status(catalog: Catalog, arguments: [String]) -> Int32 {
        let wantsJSON = arguments.contains("--json")
        guard let status = StatusFile.read() else {
            if wantsJSON { print(#"{"running":false}"#) } else { print(catalog.text("cli.notRunning")) }
            return notRunning
        }
        if wantsJSON { printJSON(status) } else { printText(status) }
        return 0
    }

    /// `halflid start [30 | 30m | 2h]`, or `--minutes N` / `--hours N`. Without a duration: until `halflid stop`.
    static func start(catalog: Catalog, arguments: [String]) -> Int32 {
        var minutes: Int?
        if let text = durationArgument(arguments) {
            guard let parsed = parseMinutes(text) else {
                FileHandle.standardError.write(Data((catalog.text("cli.badDuration", ["value": text]) + "\n").utf8))
                return badUsage
            }
            minutes = parsed
        }
        return send(.start(minutes: minutes), catalog: catalog) { status in
            if let minutes {
                guard let end = status.holdUntil else { return false }
                return abs(end.timeIntervalSinceNow - Double(minutes) * 60) < 120
            }
            return status.holdUntilStopped
        }
    }

    static func stop(catalog: Catalog) -> Int32 {
        send(.stop, catalog: catalog) { !$0.holdUntilStopped && $0.holdUntil == nil }
    }

    // MARK: private

    private static func send(_ command: ControlCommand, catalog: Catalog, confirmed: (PublishedStatus) -> Bool) -> Int32 {
        guard StatusFile.read() != nil else {
            FileHandle.standardError.write(Data((catalog.text("cli.notRunning") + "\n").utf8))
            return notRunning
        }
        guard Preferences.load().commandLineControl else {
            FileHandle.standardError.write(Data((catalog.text("cli.controlDisabled") + "\n").utf8))
            return controlDisabled
        }
        ControlChannel.send(command)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if let current = StatusFile.read(), confirmed(current) {
                printText(current)
                return 0
            }
        }
        FileHandle.standardError.write(Data((catalog.text("cli.noAnswer") + "\n").utf8))
        return noAnswer
    }

    private static func printText(_ status: PublishedStatus) {
        print(status.title)
        if let detail = status.detail { print(detail) }
        if let hold = status.holdText, hold != status.detail { print(hold) }
    }

    private static func printJSON(_ status: PublishedStatus) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(status),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        object["running"] = true
        if let output = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: output, encoding: .utf8) { print(text) }
    }

    /// The duration given as `--minutes N`, `--hours N`, or the first plain word after the command.
    private static func durationArgument(_ arguments: [String]) -> String? {
        if let index = arguments.firstIndex(of: "--minutes"), arguments.indices.contains(index + 1) { return arguments[index + 1] + "m" }
        if let index = arguments.firstIndex(of: "--hours"), arguments.indices.contains(index + 1) { return arguments[index + 1] + "h" }
        return arguments.dropFirst(2).first { !$0.hasPrefix("-") }
    }

    /// `30`, `30m` or `2h` as minutes (at most one week); `nil` for anything else.
    static func parseMinutes(_ text: String) -> Int? {
        var number = text.lowercased()
        var factor = 1
        if number.hasSuffix("h") { number.removeLast(); factor = 60 } else if number.hasSuffix("m") { number.removeLast() }
        guard let value = Int(number), value >= 1, value * factor <= 10_080 else { return nil }
        return value * factor
    }
}
