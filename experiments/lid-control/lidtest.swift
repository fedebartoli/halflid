import Darwin
import Foundation
import IOKit

// THROWAWAY EXPERIMENT (not part of the product).
//
// Question: which mechanism keeps a MacBook awake with the lid closed and no external display on this macOS version?
//
// Modes. Every mode prints a summary and ends by restoring the normal lid policy.
//   lidtest quick-iokit          SHORT test (about 25 s): arms the IOKit call, waits for the lid to close and open, prints the verdict
//   lidtest quick-control        same without changing anything
//   lidtest read                 print the lid and sleep registry values
//   lidtest control-for N        changes nothing; baseline (the Mac is expected to sleep when the lid closes)
//   lidtest iokit-for N          unprivileged IOKit call kPMSetClamshellSleepState (selector 12)
//   lidtest caffeinate-for N     `caffeinate -s` (PreventSystemSleep assertion; documented as AC power only), no admin
//   lidtest pmset-for N          `sudo pmset -a disablesleep 1` (asks for your password once at start)
//   lidtest restore              puts everything back to normal (safe to run any time)
//
// A heartbeat is recorded every second. If the Mac sleeps, this process is frozen and the next heartbeat shows a large gap.
// iokit-for and pmset-for also start an independent watchdog that restores the policy a few seconds after the deadline
// even if this process is killed. Run on a desk, never in a bag.
// Test hook: LIDTEST_FAKE_PMSET=/path/to/script replaces `sudo -n pmset` so the restore logic can be tested without sudo.

let selector: UInt32 = 12
let heartbeatLog = "/tmp/halflid_heartbeat.log"
let fakePmset = ProcessInfo.processInfo.environment["LIDTEST_FAKE_PMSET"]
let selfPath = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path

// MARK: registry

func rootDomain() -> io_service_t {
    IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
}

func readBool(_ key: String) -> Bool? {
    let service = rootDomain()
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
}

func registrySummary() -> String {
    func text(_ b: Bool?) -> String { b.map(String.init(describing:)) ?? "nil" }
    return "CausesSleep=\(text(readBool("AppleClamshellCausesSleep"))) LidClosed=\(text(readBool("AppleClamshellState"))) SleepDisabled=\(text(readBool("SleepDisabled")))"
}

// MARK: mechanisms

func describe(_ kr: kern_return_t) -> String {
    kr == KERN_SUCCESS ? "OK" : "error 0x" + String(UInt32(bitPattern: kr), radix: 16)
}

@discardableResult
func iokitSetLidSleepDisabled(_ disable: Bool) -> kern_return_t {
    let service = rootDomain()
    defer { IOObjectRelease(service) }
    var connect: io_connect_t = 0
    var result = IOServiceOpen(service, mach_task_self_, 0, &connect)
    guard result == KERN_SUCCESS else { return result }
    defer { IOServiceClose(connect) }
    var input: UInt64 = disable ? 1 : 0
    result = IOConnectCallMethod(connect, selector, &input, 1, nil, 0, nil, nil, nil, nil)
    return result
}

/// Runs a command and waits. Standard input is inherited so `sudo` can ask for the password on the terminal.
@discardableResult
func run(_ path: String, _ args: [String], quiet: Bool = true) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    if quiet {
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }
    do { try process.run() } catch { return 127 }
    process.waitUntilExit()
    return process.terminationStatus
}

func capture(_ path: String, _ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// `pmset -a disablesleep 1|0` through the narrow, passwordless path (or the fake used in tests).
@discardableResult
func pmsetSet(_ disable: Bool) -> Int32 {
    let value = disable ? "1" : "0"
    if let fake = fakePmset { return run(fake, ["-a", "disablesleep", value]) }
    return run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", value])
}

func onACPower() -> Bool { capture("/usr/bin/pmset", ["-g", "batt"]).contains("AC Power") }

var watchdogProcess: Process?

func startWatchdog(after seconds: Int, mode: String) {
    // Independent process: restores shortly after the deadline even if this process is killed.
    let watchdog = Process()
    watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
    watchdog.arguments = ["-c", "sleep \(seconds + 10); exec \"$0\" restore-\(mode) >/dev/null 2>&1", selfPath]
    watchdog.standardInput = FileHandle.nullDevice
    watchdog.standardOutput = FileHandle.nullDevice
    watchdog.standardError = FileHandle.nullDevice
    try? watchdog.run()
    watchdogProcess = watchdog
}

/// Called after an orderly restore: a leftover watchdog firing later could undo the NEXT test.
func stopWatchdog() {
    watchdogProcess?.terminate()
    watchdogProcess = nil
}

// MARK: shared state for signal handlers (handlers cannot capture context)

var activeMode = ""
var caffeinateProcess: Process?

func restoreActiveMode() {
    switch activeMode {
    case "iokit": iokitSetLidSleepDisabled(false)
    case "pmset": pmsetSet(false)
    default: break
    }
    stopWatchdog()
    caffeinateProcess?.terminate()
}

// MARK: ground truth from the system power log

/// Power-state events recorded by macOS between two instants. This, not the heartbeat, is the ground truth: after a
/// lid close macOS may open a DarkWake window (up to 180 s) in which processes keep running, so a short heartbeat test
/// cannot tell "slept" from "kept awake".
func powerEvents(from start: Date, to end: Date) -> [String] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let lower = formatter.string(from: start.addingTimeInterval(-2))
    let upper = formatter.string(from: end.addingTimeInterval(2))
    let markers = ["Entering Sleep", "Entering DarkWake", "DarkWake from", "FullWake", "Display is turned"]
    return capture("/usr/bin/pmset", ["-g", "log"]).split(separator: "\n").compactMap { line in
        let text = String(line)
        guard text.count > 19 else { return nil }
        let stamp = String(text.prefix(19))
        guard stamp >= lower, stamp <= upper, markers.contains(where: { text.contains($0) }) else { return nil }
        let compact = text.split(whereSeparator: { $0 == "\t" }).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        return String(compact.prefix(140))
    }
}

func verdict(events: [String], lidClosedSamples: Int) -> String {
    if events.contains(where: { $0.contains("Entering Sleep") }) { return "SLEPT: macOS entered sleep because of the lid." }
    if events.contains(where: { $0.contains("Entering DarkWake") }) { return "PARTIAL: display off, system kept running in DarkWake (no full sleep)." }
    if lidClosedSamples > 0 { return "LID IGNORED: lid was closed and macOS logged no power event at all." }
    return "INCONCLUSIVE: the lid was never seen closed."
}

// MARK: recording

func record(label: String, seconds: Int, restore: () -> Void) {
    let started = Date()
    var last = started
    var maxGap = 0.0
    var beats = 0
    var lidClosedSamples = 0
    var log = ""
    print("GO: \(label) for \(seconds)s. Close the lid for about 25 seconds now, then open it. Do not touch anything else.")
    while Date().timeIntervalSince(started) < Double(seconds) {
        Thread.sleep(forTimeInterval: 1)
        let now = Date()
        let gap = now.timeIntervalSince(last)
        maxGap = max(maxGap, gap)
        last = now
        beats += 1
        let closed = readBool("AppleClamshellState")
        if closed == true { lidClosedSamples += 1 }
        log += String(format: "%.1f gap=%.1f lid_closed=%@\n", now.timeIntervalSince(started), gap, closed.map(String.init(describing:)) ?? "nil")
    }
    try? log.write(toFile: heartbeatLog, atomically: true, encoding: .utf8)
    restore()
    stopWatchdog()
    let ended = Date()
    print("SUMMARY: heartbeats=\(beats) lid_closed_samples=\(lidClosedSamples) max_gap=\(String(format: "%.1f", maxGap))s")
    let events = powerEvents(from: started, to: ended)
    print("POWER LOG during the run (\(events.count) events):")
    events.forEach { print("  \($0)") }
    print("RESULT: \(verdict(events: events, lidClosedSamples: lidClosedSamples))")
    print("final: \(registrySummary())")
}

/// Short interactive test: waits for the lid to close, keeps the state for ~12 s, beeps twice (speakers work with the
/// lid closed), waits for the lid to open, then prints the power-log verdict. No fixed duration to guess.
func quick(arm: Bool) {
    requireLidOpen()
    let closeTimeout = Double(ProcessInfo.processInfo.environment["LIDTEST_CLOSE_TIMEOUT"] ?? "") ?? 40
    if arm {
        activeMode = "iokit"
        startWatchdog(after: 80, mode: "iokit")
        installSignalHandlers()
        print("armed (iokit selector 12): \(describe(iokitSetLidSleepDisabled(true)))")
    } else {
        print("CONTROL: nothing is changed")
    }
    print("POWER SOURCE: \(onACPower() ? "AC" : "BATTERY")")
    print("READY. Close the lid now (you have \(Int(closeTimeout)) seconds). Keep it closed for about 15 seconds, then open it. Two beeps may sound; they are optional.")
    let started = Date()
    var closedAt: Date?
    while Date().timeIntervalSince(started) < closeTimeout {
        if readBool("AppleClamshellState") == true { closedAt = Date(); break }
        Thread.sleep(forTimeInterval: 0.2)
    }
    func finish() {
        if arm { print("restore -> \(describe(iokitSetLidSleepDisabled(false)))") }
        stopWatchdog()
    }
    guard let closed = closedAt else {
        finish()
        print("RESULT: TIMEOUT, the lid was not closed in time. Nothing to judge; run again.")
        return
    }
    var beeped = false
    while true {
        Thread.sleep(forTimeInterval: 0.25)
        if readBool("AppleClamshellState") == false { break }
        let elapsed = Date().timeIntervalSince(closed)
        if elapsed >= 12 && !beeped {
            beeped = true
            run("/usr/bin/afplay", ["/System/Library/Sounds/Glass.aiff"])
            run("/usr/bin/afplay", ["/System/Library/Sounds/Glass.aiff"])
        }
        if elapsed >= 45 { break } // safety: stop waiting even if the lid is still closed
    }
    let ended = Date()
    finish()
    Thread.sleep(forTimeInterval: 2) // let the power log catch up
    let closedSeconds = Int(ended.timeIntervalSince(closed))
    let events = powerEvents(from: closed, to: ended)
    print("LID CLOSED FOR: \(closedSeconds)s")
    print("POWER LOG during the run (\(events.count) events):")
    events.forEach { print("  \($0)") }
    print("RESULT: \(verdict(events: events, lidClosedSamples: closedSeconds))")
    print("final: \(registrySummary())")
}

func installSignalHandlers() {
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig) { _ in
            restoreActiveMode()
            exit(130)
        }
    }
}

func requireLidOpen() {
    guard readBool("AppleClamshellState") == false else { print("ABORT: lid is not reported open at start"); exit(2) }
}

// MARK: main

let arguments = CommandLine.arguments
let mode = arguments.dropFirst().first ?? "read"
let seconds = min(max(Int(arguments.dropFirst(2).first ?? "") ?? 75, 20), 300)

switch mode {
case "read":
    print("now: \(registrySummary())")
    print("pmset SleepDisabled line: \(capture("/usr/bin/pmset", ["-g"]).split(separator: "\n").first(where: { $0.contains("SleepDisabled") }).map(String.init) ?? "(not shown, i.e. 0)")")
case "restore", "restore-iokit":
    print("iokit restore -> \(describe(iokitSetLidSleepDisabled(false)))")
    print("now: \(registrySummary())")
case "restore-pmset":
    print("pmset restore -> exit \(pmsetSet(false))")
case "analyze":
    // lidtest analyze HH:mm:ss HH:mm:ss  (today, local time): re-read the power log for a past window.
    let args = Array(arguments.dropFirst(2))
    guard args.count == 2 else { print("usage: lidtest analyze HH:mm:ss HH:mm:ss"); exit(64) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let today = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    let day = String(format: "%04d-%02d-%02d", today.year ?? 0, today.month ?? 0, today.day ?? 0)
    guard let from = formatter.date(from: "\(day) \(args[0])"), let to = formatter.date(from: "\(day) \(args[1])") else { print("bad time"); exit(64) }
    let events = powerEvents(from: from, to: to)
    events.forEach { print("  \($0)") }
    print("RESULT: \(verdict(events: events, lidClosedSamples: 1))")
case "quick-iokit":
    quick(arm: true)
case "quick-control":
    quick(arm: false)
case "control-for":
    requireLidOpen()
    record(label: "CONTROL, nothing is changed", seconds: seconds, restore: {})
case "iokit-for":
    requireLidOpen()
    activeMode = "iokit"
    startWatchdog(after: seconds, mode: "iokit")
    installSignalHandlers()
    print("iokit set -> \(describe(iokitSetLidSleepDisabled(true)))  (\(registrySummary()))")
    record(label: "IOKIT selector 12", seconds: seconds, restore: { print("iokit restore -> \(describe(iokitSetLidSleepDisabled(false)))") })
case "caffeinate-for":
    requireLidOpen()
    if !onACPower() { print("NOTE: not on AC power; caffeinate -s is documented as valid on AC only. The result will say so.") }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
    process.arguments = ["-s", "-t", String(seconds + 5)]
    do { try process.run() } catch { print("ABORT: cannot start caffeinate"); exit(3) }
    caffeinateProcess = process
    activeMode = "caffeinate"
    installSignalHandlers()
    print("caffeinate -s started (on AC: \(onACPower()))")
    record(label: "CAFFEINATE -s", seconds: seconds, restore: { process.terminate(); print("caffeinate stopped") })
case "pmset-for":
    requireLidOpen()
    if fakePmset == nil {
        // Never prompt from inside this program: the password would be read by a child process. Authenticate in the shell first.
        guard run("/usr/bin/sudo", ["-n", "-v"]) == 0 else {
            print("ABORT: sudo is not authorised yet. In this terminal run:  sudo -v   (type your password THERE, nowhere else)")
            print("Then run this command again within 5 minutes.")
            exit(4)
        }
    }
    print("If anything goes wrong, restore manually with:  sudo pmset -a disablesleep 0")
    activeMode = "pmset"
    startWatchdog(after: seconds, mode: "pmset")
    installSignalHandlers()
    let status = pmsetSet(true)
    print("pmset disablesleep 1 -> exit \(status)  (\(registrySummary()))")
    guard status == 0 else { print("ABORT: pmset failed; nothing to restore"); exit(5) }
    record(label: "PMSET disablesleep", seconds: seconds, restore: {
        let code = pmsetSet(false)
        print("pmset disablesleep 0 -> exit \(code)")
    })
default:
    print("unknown mode")
    exit(64)
}
