import Foundation

/// Looks at modification times only. File contents are never opened.
public enum SessionActivityProbe {
    /// Newest modification date of a regular file under `root`, looking at most `maxDepth` levels deep and at most
    /// `maxEntries` entries. Directories are ignored: their time changes whenever anything is created inside them.
    public static func newestModification(under root: URL, maxDepth: Int = 4, maxEntries: Int = 5_000, fileManager: FileManager = .default) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return nil }
        var newest: Date?
        var seen = 0
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            seen += 1
            if seen > maxEntries { break }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let date = values.contentModificationDate else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest
    }

    /// Age in seconds of the newest modification across all of an agent's session paths; `nil` if none can be read.
    public static func newestAgeSeconds(for agent: AgentDefinition, now: Date) -> Double? {
        var newest: Date?
        for path in agent.sessionPaths {
            let expanded = (path as NSString).expandingTildeInPath
            guard let date = newestModification(under: URL(fileURLWithPath: expanded)) else { continue }
            if newest == nil || date > newest! { newest = date }
        }
        return newest.map { max(0, now.timeIntervalSince($0)) }
    }
}
