import Foundation

/// How to recognise one coding agent without reading anything it writes. Matching uses the process name and the
/// executable path only (never command-line arguments).
public struct AgentDefinition: Codable, Sendable, Equatable {
    public var id: String
    /// Exact process names (as reported by the kernel, at most 32 characters).
    public var processNames: [String]
    /// Substrings of the executable path (for helpers that all live inside one application bundle or directory).
    public var pathContains: [String]
    /// Directories whose newest modification time hints at recent session activity. `~` is expanded. Only metadata is read.
    public var sessionPaths: [String]
    /// `true` only if the entry was checked against the real agent on a real machine.
    public var verified: Bool
    /// Bundle identifiers of installed applications whose icon stands for this agent when it has no `mark`. The interface asks
    /// the system for the icon of whichever is installed. Unknown or absent ids simply give no icon.
    public var appBundleIds: [String]
    /// Name of the monochrome mark (a file `agent-marks/<mark>.svg` in the resources) that stands for this agent in the
    /// interface. Without one, the icon of an installed application is used, then a monogram.
    public var mark: String?

    public init(
        id: String, processNames: [String] = [], pathContains: [String] = [], sessionPaths: [String] = [], verified: Bool = false,
        appBundleIds: [String] = [], mark: String? = nil
    ) {
        self.id = id
        self.processNames = processNames
        self.pathContains = pathContains
        self.sessionPaths = sessionPaths
        self.verified = verified
        self.appBundleIds = appBundleIds
        self.mark = mark
    }

    private enum CodingKeys: String, CodingKey { case id, processNames, pathContains, sessionPaths, verified, appBundleIds, mark }

    /// A catalog written before `appBundleIds` or `mark` existed still loads.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        processNames = try values.decode([String].self, forKey: .processNames)
        pathContains = try values.decode([String].self, forKey: .pathContains)
        sessionPaths = try values.decode([String].self, forKey: .sessionPaths)
        verified = try values.decode(Bool.self, forKey: .verified)
        appBundleIds = try values.decodeIfPresent([String].self, forKey: .appBundleIds) ?? []
        mark = try values.decodeIfPresent(String.self, forKey: .mark)
    }

    public func matches(_ process: ProcessEntry) -> Bool {
        if !process.name.isEmpty, processNames.contains(process.name) { return true }
        return pathContains.contains { !$0.isEmpty && process.path.contains($0) }
    }
}

public struct AgentCatalog: Codable, Sendable, Equatable {
    public var agents: [AgentDefinition]

    public init(agents: [AgentDefinition]) {
        self.agents = agents
    }

    public static func load(from url: URL) throws -> AgentCatalog {
        try JSONDecoder().decode(AgentCatalog.self, from: Data(contentsOf: url))
    }
}
