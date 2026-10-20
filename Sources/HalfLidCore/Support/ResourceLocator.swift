import Foundation

/// Finds the directory that holds `i18n/` and `agents.json`: inside the app bundle when packaged (for the settings program,
/// which is an application nested in the bundle, that is the outer bundle), or the repository's `Resources/` folder when
/// running a build product directly from `build/bin/`.
public enum ResourceLocator {
    public static func resourcesDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        mainBundleResources: URL? = Bundle.main.resourceURL,
        executable: URL? = Bundle.main.executableURL,
        fileManager: FileManager = .default
    ) -> URL? {
        var candidates: [URL] = []
        if let override = environment["HALFLID_RESOURCES"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let bundled = mainBundleResources { candidates.append(bundled) }
        if let executable {
            // <repo>/build/bin/<exe> -> <repo>/Resources, and
            // Half Lid.app/Contents/Helpers/Half Lid Settings.app/Contents/MacOS/<exe> -> Half Lid.app/Contents/Resources
            var folder = executable.resolvingSymlinksInPath()
            for _ in 1...6 {
                folder = folder.deletingLastPathComponent()
                candidates.append(folder.appendingPathComponent("Resources"))
            }
        }
        return candidates.first { fileManager.fileExists(atPath: $0.appendingPathComponent("i18n/en.json").path) }
    }

    /// The `halflid` command-line tool: next to the running executable, or, when that is the settings app nested inside the
    /// main app (`Half Lid.app/Contents/Helpers/Half Lid Settings.app/Contents/MacOS/`), in the main app's own `MacOS` folder.
    public static func commandLineTool(
        executable: URL? = Bundle.main.executableURL, fileManager: FileManager = .default
    ) -> URL? {
        guard let executable else { return nil }
        let sibling = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        var outer = sibling
        for _ in 1...4 { outer = outer.deletingLastPathComponent() } // MacOS, Contents, Half Lid Settings.app, Helpers -> Contents
        return [sibling, outer.appendingPathComponent("MacOS")]
            .map { $0.appendingPathComponent("halflid") }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
