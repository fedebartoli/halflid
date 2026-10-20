import AppKit
import SwiftUI

struct AboutPane: View {
    let model: SettingsModel

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                identity
                VStack(alignment: .leading, spacing: 14) {
                    paragraph("settings.about.privacy.title", "settings.about.privacy")
                    paragraph("settings.about.license.title", "settings.about.license")
                    paragraph("settings.about.marks.title", "settings.about.marks")
                    if let notices = noticesURL {
                        Button(model.text("settings.about.notices")) { NSWorkspace.shared.open(notices) }
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
                Text(model, "settings.about.copyright")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
        }
    }

    private var identity: some View {
        VStack(spacing: 8) {
            Image(nsImage: AppIcon.image)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text(model, "app.name")
                .font(.title.bold())
            Text(verbatim: model.versionLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(model, "settings.about.tagline")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
    }

    private func paragraph(_ titleKey: String, _ bodyKey: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(model, titleKey)
                .font(.headline)
            Text(model, bodyKey)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The licence texts for the bundled marks, shipped next to the translations.
    private var noticesURL: URL? {
        guard let url = model.resources?.appendingPathComponent("NOTICE.txt"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
