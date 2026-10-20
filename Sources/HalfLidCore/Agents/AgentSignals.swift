import Foundation

/// Raw activity signals for one agent at one instant. These are inputs for a later "is it working?" decision; this type
/// makes no decision itself.
public struct AgentSignal: Codable, Sendable, Equatable {
    public var agentId: String
    public var processCount: Int
    /// CPU used by the agent's process tree since the previous sample, as a percentage of one core (can exceed 100).
    public var cpuPercent: Double
    /// Number of sleep-preventing power assertions held by the agent's processes.
    public var sleepAssertions: Int
    /// Seconds since the newest modification under the agent's session directories; `nil` if none exist.
    public var newestSessionAgeSeconds: Double?

    public init(agentId: String, processCount: Int = 0, cpuPercent: Double = 0, sleepAssertions: Int = 0, newestSessionAgeSeconds: Double? = nil) {
        self.agentId = agentId
        self.processCount = processCount
        self.cpuPercent = cpuPercent
        self.sleepAssertions = sleepAssertions
        self.newestSessionAgeSeconds = newestSessionAgeSeconds
    }
}

public final class AgentSignalSampler {
    public typealias ProcessSource = () -> [ProcessEntry]
    public typealias AssertionSource = () -> [PowerAssertion]
    public typealias SessionAgeSource = (AgentDefinition, Date) -> Double?
    /// Whether to look at an agent's session files, given the agent and how many of its processes are running.
    /// Walking session folders is by far the most expensive signal (about 90 ms for Cursor's), so the app only does it
    /// where the result can change a decision.
    public typealias SessionScanRule = (AgentDefinition, Int) -> Bool

    private let catalog: AgentCatalog
    private let processes: ProcessSource
    private let assertions: AssertionSource
    private let sessionAge: SessionAgeSource
    private let scansSessions: SessionScanRule
    private var previousCPU: [Int32: UInt64] = [:]
    private var previousTime: Date?

    public init(
        catalog: AgentCatalog,
        processes: @escaping ProcessSource = ProcessProbe.snapshot,
        assertions: @escaping AssertionSource = AssertionsProbe.read,
        sessionAge: @escaping SessionAgeSource = SessionActivityProbe.newestAgeSeconds,
        scansSessions: @escaping SessionScanRule = { _, _ in true }
    ) {
        self.catalog = catalog
        self.processes = processes
        self.assertions = assertions
        self.sessionAge = sessionAge
        self.scansSessions = scansSessions
    }

    /// Returns one signal per agent that has running processes or session activity. The first call has no CPU baseline and
    /// reports `cpuPercent` as 0.
    public func sample(now: Date = Date()) -> [AgentSignal] {
        let table = processes()
        let held = assertions().filter(\.preventsSleep)
        let elapsed = previousTime.map { now.timeIntervalSince($0) } ?? 0

        var children: [Int32: [Int32]] = [:]
        var byPid: [Int32: ProcessEntry] = [:]
        for entry in table {
            byPid[entry.pid] = entry
            children[entry.parentPid, default: []].append(entry.pid)
        }

        var claimed = Set<Int32>()
        var signals: [AgentSignal] = []
        for agent in catalog.agents {
            var tree = Set<Int32>()
            var queue = table.filter { agent.matches($0) && !claimed.contains($0.pid) }.map(\.pid)
            while let pid = queue.popLast() {
                guard tree.insert(pid).inserted, !claimed.contains(pid) else { continue }
                queue.append(contentsOf: children[pid] ?? [])
            }
            claimed.formUnion(tree)

            var deltaCPU: UInt64 = 0
            for pid in tree {
                guard let entry = byPid[pid], let before = previousCPU[pid], entry.cpuNanoseconds >= before else { continue }
                deltaCPU += entry.cpuNanoseconds - before
            }
            let cpuPercent = elapsed > 0 ? Double(deltaCPU) / (elapsed * 1_000_000_000) * 100 : 0
            let age = scansSessions(agent, tree.count) ? sessionAge(agent, now) : nil
            if tree.isEmpty && age == nil { continue }
            signals.append(AgentSignal(
                agentId: agent.id,
                processCount: tree.count,
                cpuPercent: (cpuPercent * 10).rounded() / 10,
                sleepAssertions: held.filter { tree.contains($0.pid) }.count,
                newestSessionAgeSeconds: age.map { ($0 * 10).rounded() / 10 }
            ))
        }

        previousCPU = Dictionary(uniqueKeysWithValues: table.map { ($0.pid, $0.cpuNanoseconds) })
        previousTime = now
        return signals
    }
}
