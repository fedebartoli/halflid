import Foundation

/// A flat translation catalog (`key -> text`) with English as the fallback, in the same shape as Pocket's catalogs.
///
/// Rules for catalog authors:
/// - Placeholders are written `{name}` and must be identical in every language.
/// - Texts must not depend on a count (no plural forms): write "Agents: {value}" instead of "{n} agents".
public struct Catalog: Sendable {
    public static let fallbackLanguage = "en"

    public let language: String
    private let messages: [String: String]
    private let fallback: [String: String]

    public init(language: String, messages: [String: String], fallback: [String: String]) {
        self.language = language
        self.messages = messages
        self.fallback = fallback
    }

    /// Text for `key` with `{placeholders}` replaced. Unknown keys return the key itself so a gap is visible, never a crash.
    public func text(_ key: String, _ params: [String: String] = [:]) -> String {
        guard var template = messages[key] ?? fallback[key] else { return key }
        for (name, value) in params {
            template = template.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return template
    }

    /// Language codes available in `directory` (file names without extension, e.g. `en`, `zh-Hans`).
    public static func availableLanguages(in directory: URL, fileManager: FileManager = .default) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// Picks the best supported language for a list of preferred BCP 47 tags (as in `Locale.preferredLanguages`).
    public static func pickLanguage(preferred: [String], supported: Set<String>) -> String {
        for tag in preferred {
            if let match = resolve(tag: tag, supported: supported) { return match }
        }
        return fallbackLanguage
    }

    static func resolve(tag: String, supported: Set<String>) -> String? {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let primary = parts.first?.lowercased() else { return nil }
        if primary == "zh" {
            let traditionalRegions: Set<String> = ["tw", "hk", "mo"]
            let isTraditional = parts.dropFirst().contains { $0.lowercased() == "hant" || traditionalRegions.contains($0.lowercased()) }
            let wanted = isTraditional ? "zh-Hant" : "zh-Hans"
            return supported.contains(wanted) ? wanted : nil
        }
        return supported.contains(primary) ? primary : nil
    }

    /// The catalog for the interface language: `language` (the user's choice in the settings) when given, otherwise the system's.
    public static func load(directory: URL, language: String?) -> Catalog {
        load(directory: directory, preferred: language.map { [$0] } ?? Locale.preferredLanguages)
    }

    public static func load(directory: URL, preferred: [String] = Locale.preferredLanguages) -> Catalog {
        let supported = Set(availableLanguages(in: directory))
        let language = pickLanguage(preferred: preferred, supported: supported)
        let fallback = read(directory.appendingPathComponent("\(fallbackLanguage).json"))
        let messages = language == fallbackLanguage ? fallback : read(directory.appendingPathComponent("\(language).json"))
        return Catalog(language: language, messages: messages, fallback: fallback)
    }

    public static func read(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return object
    }
}
