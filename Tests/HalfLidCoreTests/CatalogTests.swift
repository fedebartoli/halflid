import Foundation
import HalfLidCore

private func placeholders(in text: String) -> Set<String> {
    var found = Set<String>()
    var current: String?
    for character in text {
        if character == "{" { current = "" } else if character == "}", let name = current { found.insert(name); current = nil } else if current != nil { current!.append(character) }
    }
    return found
}

func runCatalogTests() {
    let supported: Set<String> = ["en", "it", "pt", "zh-Hans", "zh-Hant", "ja"]
    expect(Catalog.pickLanguage(preferred: ["it-IT", "en-US"], supported: supported) == "it", "picks the primary language")
    expect(Catalog.pickLanguage(preferred: ["pt-BR"], supported: supported) == "pt", "region does not matter for pt")
    expect(Catalog.pickLanguage(preferred: ["zh-Hant-TW"], supported: supported) == "zh-Hant", "Traditional Chinese by script")
    expect(Catalog.pickLanguage(preferred: ["zh-TW"], supported: supported) == "zh-Hant", "Traditional Chinese by region")
    expect(Catalog.pickLanguage(preferred: ["zh-CN"], supported: supported) == "zh-Hans", "Simplified Chinese by default")
    expect(Catalog.pickLanguage(preferred: ["zh"], supported: ["en", "zh-Hant"]) == "en", "no Simplified catalog falls back to English")
    expect(Catalog.pickLanguage(preferred: ["xx", "ja-JP"], supported: supported) == "ja", "skips unsupported tags")
    expect(Catalog.pickLanguage(preferred: ["xx"], supported: supported) == "en", "unknown language falls back to English")
    expect(Catalog.pickLanguage(preferred: [], supported: supported) == "en", "no preference falls back to English")

    let catalog = Catalog(language: "it", messages: ["a": "Ciao {name}"], fallback: ["a": "Hello {name}", "b": "Only English"])
    expect(catalog.text("a", ["name": "Fede"]) == "Ciao Fede", "replaces placeholders")
    expect(catalog.text("b") == "Only English", "falls back to English for missing keys")
    expect(catalog.text("missing") == "missing", "unknown key returns the key")

    // Every catalog must have exactly the keys and placeholders of the English one.
    let directory = repositoryRoot.appendingPathComponent("Resources/i18n")
    let english = Catalog.read(directory.appendingPathComponent("en.json"))
    expect(!english.isEmpty, "English catalog loads")
    for language in Catalog.availableLanguages(in: directory) where language != "en" {
        let other = Catalog.read(directory.appendingPathComponent("\(language).json"))
        expect(Set(other.keys) == Set(english.keys), "\(language): same keys as English")
        for (key, text) in other {
            expect(!text.isEmpty, "\(language).\(key): not empty")
            expect(placeholders(in: text) == placeholders(in: english[key] ?? ""), "\(language).\(key): same placeholders as English")
        }
    }
}
