import SwiftUI

struct DiagnosticsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            stateSection
            holdersSection
            screenSection
            menuBarSection
            repairSection
            reportSection
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                model.refreshLive()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    // MARK: sections

    private var stateSection: some View {
        Section {
            if let status = model.published {
                LabeledContent(model.text("settings.diagnostics.menuBarApp")) {
                    Text(model, "settings.diagnostics.running")
                }
                LabeledContent(model.text("settings.diagnostics.state")) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(verbatim: status.title)
                        if let detail = status.detail {
                            Text(verbatim: detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.trailing)
                }
            } else {
                LabeledContent(model.text("settings.diagnostics.menuBarApp")) {
                    Text(model, "settings.diagnostics.notRunning")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Text(model, "settings.diagnostics.status")
        }
    }

    private var holdersSection: some View {
        Section {
            if model.sleepHolders.isEmpty {
                Text(model, "settings.diagnostics.holders.none")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.sleepHolders) { holder in
                    LabeledContent {
                        Text(model, holder.kindKey)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: holder.process)
                            if !holder.reason.isEmpty {
                                Text(verbatim: holder.reason)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                }
            }
        } header: {
            Text(model, "settings.diagnostics.holders")
        } footer: {
            Text(model, "settings.diagnostics.holders.note")
        }
    }

    /// Whether the macOS functions behind the lid-closed screen steps exist. Looked up when the pane is shown, not at launch.
    private var screenSection: some View {
        Section {
            LabeledContent(model.text("settings.lid.lock")) { availability(model.canLockScreen) }
            LabeledContent(model.text("settings.diagnostics.screen.brightness")) { availability(model.canSetBrightness) }
        } header: {
            Text(model, "settings.diagnostics.screen")
        } footer: {
            Text(model, "settings.diagnostics.screen.note")
        }
    }

    @ViewBuilder
    private func availability(_ available: Bool) -> some View {
        if available {
            Text(model, "settings.diagnostics.available")
        } else {
            Text(model, "settings.diagnostics.unavailable")
                .foregroundStyle(.orange)
        }
    }

    private var menuBarSection: some View {
        Section {
            ActionRow(
                text: model.text("settings.diagnostics.menuBar.detail"), buttonTitle: model.text("settings.diagnostics.menuBar.open")
            ) { SystemLinks.openMenuBarSettings() }
        } header: {
            Text(model, "settings.diagnostics.menuBar")
        }
    }

    private var repairSection: some View {
        let busy = model.published?.armed == true
        return Section {
            ActionRow(
                text: model.text("settings.diagnostics.repair.detail"), buttonTitle: model.text("settings.diagnostics.repair.button"),
                disabled: busy
            ) { model.repair() }
            if busy {
                Note(text: model.text("settings.diagnostics.repair.busy"))
            }
            if let message = model.repairMessage {
                Note(text: message)
            }
        } header: {
            Text(model, "settings.diagnostics.repair")
        }
    }

    private var reportSection: some View {
        Section {
            ActionRow(
                text: model.text("settings.diagnostics.copy.detail"),
                buttonTitle: model.text(model.reportCopied ? "settings.diagnostics.copied" : "settings.diagnostics.copy")
            ) { model.copyReport() }
        } header: {
            Text(model, "settings.diagnostics.report")
        }
    }
}
