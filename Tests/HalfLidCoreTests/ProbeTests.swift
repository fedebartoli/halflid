import AppKit
import Foundation
import HalfLidCore

func runProbeTests() {
    // Process table: our own process is visible and has plausible fields.
    let own = ProcessInfo.processInfo.processIdentifier
    let table = ProcessProbe.snapshot()
    let me = table.first { $0.pid == own }
    expect(table.count > 10, "process table is not empty")
    expect(me != nil, "own process is listed")
    expect(me?.parentPid == getppid(), "parent pid matches getppid")
    expect(!(me?.name.isEmpty ?? true), "own process has a name")
    expect(me?.path.hasPrefix("/") == true, "own process has an absolute path")

    // CPU units: a busy child must read as roughly one core. If ticks were mistaken for nanoseconds this would be ~40x off.
    let burner = Process()
    burner.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
    burner.standardOutput = FileHandle.nullDevice
    burner.standardError = FileHandle.nullDevice
    if (try? burner.run()) != nil {
        defer { burner.terminate(); burner.waitUntilExit() }
        Thread.sleep(forTimeInterval: 0.3)
        let before = ProcessProbe.snapshot().first { $0.pid == burner.processIdentifier }
        let startWall = Date()
        Thread.sleep(forTimeInterval: 1.5)
        let after = ProcessProbe.snapshot().first { $0.pid == burner.processIdentifier }
        let wall = Date().timeIntervalSince(startWall)
        if let before, let after, after.cpuNanoseconds >= before.cpuNanoseconds {
            let percent = Double(after.cpuNanoseconds - before.cpuNanoseconds) / (wall * 1_000_000_000) * 100
            expect(percent > 50 && percent < 150, "CPU time of a busy process reads about 100% (got \(Int(percent))%)")
        } else {
            expect(false, "busy child process is visible in two snapshots")
        }
    } else {
        expect(false, "could start the busy child process")
    }

    // Session activity: metadata only, newest wins, depth is bounded.
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("halflid-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let deep = temp.appendingPathComponent("a/b/c/d/e/f")
    try? FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    let old = temp.appendingPathComponent("a/old.txt")
    let recent = temp.appendingPathComponent("a/b/recent.txt")
    FileManager.default.createFile(atPath: old.path, contents: Data())
    FileManager.default.createFile(atPath: recent.path, contents: Data())
    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3_600)], ofItemAtPath: old.path)
    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -5)], ofItemAtPath: recent.path)
    let newest = SessionActivityProbe.newestModification(under: temp)
    expect(newest != nil && abs(newest!.timeIntervalSinceNow + 5) < 3, "newest modification is the recent file")
    let tooDeep = deep.appendingPathComponent("hidden.txt")
    FileManager.default.createFile(atPath: tooDeep.path, contents: Data())
    let shallow = SessionActivityProbe.newestModification(under: temp, maxDepth: 2)
    expect(shallow != nil && shallow! <= Date(timeIntervalSinceNow: -2), "files deeper than maxDepth are ignored")
    expect(SessionActivityProbe.newestModification(under: temp.appendingPathComponent("missing")) == nil, "missing directory gives nil")
    let definition = AgentDefinition(id: "t", sessionPaths: [temp.path])
    let age = SessionActivityProbe.newestAgeSeconds(for: definition, now: Date())
    expect(age != nil && age! >= 0, "agent session age is non-negative")

    // System snapshot: values are in range when present.
    let snapshot = SystemProbe.snapshot()
    if let percent = snapshot.batteryPercent { expect((0...100).contains(percent), "battery percent in 0...100") }
    if let temperature = snapshot.batteryTemperatureC { expect(temperature > -20 && temperature < 100, "battery temperature in a plausible range") }
    expect(ThermalLevel.allCases.contains(snapshot.thermal), "thermal level is known")
    expect(AssertionsProbe.read().allSatisfy { $0.pid > 0 }, "assertions belong to real processes")

    // Identity: the mark renders, differs per state, and the menu bar image is a template.
    for state in GlyphState.allCases {
        let png = Glyph.appIconPNG(state: state, pixelSize: 128)
        expect(png != nil && png!.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "\(state) app icon is a PNG")
        expect(Glyph.menuBarImage(state: state).isTemplate, "\(state) menu bar image is a template")
    }
    expect(Glyph.menuBarPNG(state: .idle) != Glyph.menuBarPNG(state: .active), "idle and active marks differ")
    expect(Glyph.menuBarPNG(state: .active) != Glyph.menuBarPNG(state: .warning), "active and warning marks differ")
}
