import Foundation
import HalfLidCore

private func entry(_ pid: Int32, _ parent: Int32, _ name: String, _ path: String = "", cpuSeconds: Double = 0) -> ProcessEntry {
    ProcessEntry(pid: pid, parentPid: parent, name: name, path: path, cpuNanoseconds: UInt64(cpuSeconds * 1_000_000_000))
}

func runAgentTests() {
    let cursor = AgentDefinition(id: "cursor", pathContains: ["/Cursor.app/"])
    let claude = AgentDefinition(id: "claude", processNames: ["claude"])
    expect(cursor.matches(entry(1, 0, "Cursor Helper", "/Applications/Cursor.app/Contents/Frameworks/Helper")), "matches by path fragment")
    expect(!cursor.matches(entry(1, 0, "Cursor Helper", "/Applications/Other.app/x")), "does not match another path")
    expect(claude.matches(entry(1, 0, "claude")), "matches by exact process name")
    expect(!claude.matches(entry(1, 0, "claude-helper")), "process name must match exactly")
    expect(!AgentDefinition(id: "empty").matches(entry(1, 0, "", "")), "empty definition matches nothing")

    let t0 = Date(timeIntervalSince1970: 1_000)
    var table = [
        entry(1, 0, "launchd", "/sbin/launchd", cpuSeconds: 100),
        entry(100, 1, "Cursor", "/Applications/Cursor.app/Contents/MacOS/Cursor", cpuSeconds: 10),
        entry(101, 100, "node", "/usr/local/bin/node", cpuSeconds: 5),
        entry(102, 101, "zsh", "/bin/zsh", cpuSeconds: 1),
        entry(300, 102, "claude", "/x/claude", cpuSeconds: 2), // runs inside Cursor's tree: attributed to the first agent
        entry(200, 1, "claude", "/y/claude", cpuSeconds: 3),
    ]
    let assertions = [
        PowerAssertion(pid: 101, type: "PreventUserIdleSystemSleep", name: "work"),
        PowerAssertion(pid: 101, type: "UserIsActive", name: "not a sleep blocker"),
        PowerAssertion(pid: 999, type: "PreventSystemSleep", name: "unrelated process"),
    ]
    let sampler = AgentSignalSampler(
        catalog: AgentCatalog(agents: [cursor, claude, AgentDefinition(id: "ghost", processNames: ["ghost"])]),
        processes: { table },
        assertions: { assertions },
        sessionAge: { agent, _ in agent.id == "cursor" ? 42.04 : nil }
    )

    let first = sampler.sample(now: t0)
    expect(first.map(\.agentId) == ["cursor", "claude"], "first sample lists agents with processes, skips absent ones")
    expect(first.allSatisfy { $0.cpuPercent == 0 }, "first sample has no CPU baseline")

    table = table.map { var p = $0; if p.pid == 100 { p.cpuNanoseconds += 1_000_000_000 }; if p.pid == 101 { p.cpuNanoseconds += 500_000_000 }; if p.pid == 102 { p.cpuNanoseconds += 500_000_000 }; if p.pid == 200 { p.cpuNanoseconds += 200_000_000 }; return p }
    let second = sampler.sample(now: t0.addingTimeInterval(2))
    let cursorSignal = second.first { $0.agentId == "cursor" }
    let claudeSignal = second.first { $0.agentId == "claude" }
    expect(cursorSignal?.processCount == 4, "cursor tree has its own processes plus descendants (including nested claude)")
    expect(cursorSignal?.cpuPercent == 100, "cursor CPU: 2 CPU-seconds over 2 wall-seconds is 100%")
    expect(cursorSignal?.sleepAssertions == 1, "only sleep-preventing assertions of the tree count")
    expect(cursorSignal?.newestSessionAgeSeconds == 42.0, "session age is passed through and rounded")
    expect(claudeSignal?.processCount == 1, "the claude outside Cursor is its own tree")
    expect(claudeSignal?.cpuPercent == 10, "claude CPU: 0.2 CPU-seconds over 2 wall-seconds is 10%")
    expect(claudeSignal?.newestSessionAgeSeconds == nil, "no session activity gives nil")

    // The session-scan rule decides whether the expensive folder walk happens at all.
    var scans: [String] = []
    let frugal = AgentSignalSampler(
        catalog: AgentCatalog(agents: [cursor, claude]),
        processes: { table },
        assertions: { [] },
        sessionAge: { agent, _ in scans.append(agent.id); return 5 },
        scansSessions: { agent, processes in processes > 0 && agent.id != "cursor" }
    )
    let frugalSignals = frugal.sample(now: t0)
    expect(scans == ["claude"], "session folders are walked only where the rule allows (not for cursor)")
    expect(frugalSignals.first { $0.agentId == "cursor" }?.newestSessionAgeSeconds == nil, "a skipped agent has no session age")
    expect(frugalSignals.first { $0.agentId == "cursor" }?.processCount == 4, "a skipped session scan still counts processes")
    var withoutProcess = table
    withoutProcess.removeAll { $0.name == "claude" }
    scans = []
    let idle = AgentSignalSampler(
        catalog: AgentCatalog(agents: [claude]), processes: { withoutProcess }, assertions: { [] },
        sessionAge: { agent, _ in scans.append(agent.id); return 5 },
        scansSessions: { _, processes in processes > 0 }
    )
    expect(idle.sample(now: t0).isEmpty && scans.isEmpty, "no process means no folder walk")

    // A process that exits between samples must not produce a negative or inflated delta.
    table.removeAll { $0.pid == 101 }
    let third = sampler.sample(now: t0.addingTimeInterval(4))
    expect(third.first { $0.agentId == "cursor" }?.cpuPercent == 0, "vanished process contributes nothing")

    // Catalog shipped with the app.
    let shipped = try? AgentCatalog.load(from: repositoryRoot.appendingPathComponent("Resources/agents.json"))
    expect(shipped != nil, "agents.json decodes")
    let ids = shipped?.agents.map(\.id) ?? []
    expect(Set(ids).count == ids.count && !ids.isEmpty, "agent ids are unique")
    if let shipped { runProcessShapeTests(shipped) }
}

/// What each agent looks like to the process table, as the install methods describe it (package manifests, Homebrew
/// definitions, public bug reports; see docs/AGENTS.md). Only the executable's name and path are ever looked at, and the name
/// is the one libproc reports, which is the name of the real file: a symlink such as `~/.local/bin/claude` is followed first.
/// [NOT VERIFIED] on real installs, except Cursor.
private func runProcessShapeTests(_ catalog: AgentCatalog) {
    func agents(_ name: String, _ path: String) -> [String] {
        catalog.agents.filter { $0.matches(entry(1, 0, name, path)) }.map(\.id)
    }
    // Cursor: the app and the command-line agent.
    expect(agents("Cursor", "/Applications/Cursor.app/Contents/MacOS/Cursor") == ["cursor"], "Cursor's app is recognised")
    // Claude Code: the native installer runs a file named after the version (the process is then called "2.1.168" and not
    // "claude"), npm runs bin/claude.exe, Homebrew's cask runs a file called claude.
    expect(agents("2.1.168", "/Users/someone/.local/share/claude/versions/2.1.168") == ["claude-code"], "Claude Code from the native installer")
    expect(agents("2.1.168", "/Users/someone/xdg/claude/versions/2.1.168") == ["claude-code"], "Claude Code with XDG_DATA_HOME set")
    expect(agents("claude.exe", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/bin/claude.exe") == ["claude-code"], "Claude Code from npm")
    expect(agents("claude", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code-darwin-arm64/claude") == ["claude-code"], "Claude Code from npm, platform package")
    expect(agents("claude", "/opt/homebrew/Caskroom/claude-code/2.1.304/claude") == ["claude-code"], "Claude Code from Homebrew")
    expect(agents("Claude Helper (Renderer)", "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)").isEmpty,
           "the Claude desktop app is not Claude Code")
    // Codex: a native program started by npm's shim, or Homebrew's cask.
    let npmCodex = "/opt/homebrew/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex"
    expect(agents("codex", npmCodex) == ["codex"], "Codex from npm")
    expect(agents("codex", "/opt/homebrew/Caskroom/codex/0.163.0/bin/codex") == ["codex"], "Codex from Homebrew")
    // opencode: npm runs bin/opencode.exe, the installer and Homebrew run a file called opencode.
    expect(agents("opencode.exe", "/opt/homebrew/lib/node_modules/opencode-ai/bin/opencode.exe") == ["opencode"], "opencode from npm")
    expect(agents("opencode", "/Users/someone/.opencode/bin/opencode") == ["opencode"], "opencode from the installer")
    // GitHub Copilot CLI: npm's loader starts the native copilot of its platform package; Homebrew's cask is that program.
    expect(agents("copilot", "/opt/homebrew/lib/node_modules/@github/copilot/node_modules/@github/copilot-darwin-arm64/copilot") == ["copilot-cli"], "Copilot CLI from npm")
    expect(agents("copilot", "/opt/homebrew/Caskroom/copilot-cli/1.0.100/copilot") == ["copilot-cli"], "Copilot CLI from Homebrew")
    // Goose.
    expect(agents("goose", "/Users/someone/.local/bin/goose") == ["goose"], "Goose")
    // A program written in JavaScript runs as `node`, whatever script it is given, and is not told apart from other Node
    // programs. That is why Gemini CLI (npm, Homebrew) is not in the catalog.
    expect(agents("node", "/opt/homebrew/Cellar/node/24.7.0/bin/node").isEmpty, "a Node.js process is nobody's agent")
}
