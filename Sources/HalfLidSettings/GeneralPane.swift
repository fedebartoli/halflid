import SwiftUI

struct GeneralPane: View {
    @Bindable var model: SettingsModel
    @State private var confirmingReset = false

    var body: some View {
        Form {
            startupSection
            languageSection
            commandLineSection
            resetSection
        }
        .formStyle(.grouped)
        .confirmationDialog(
            model.text("settings.general.reset.title"), isPresented: $confirmingReset, titleVisibility: .visible
        ) {
            Button(model.text("settings.general.reset.confirm"), role: .destructive) { model.resetAll() }
            Button(model.text("settings.cancel"), role: .cancel) {}
        } message: {
            Text(model, "settings.general.reset.message")
        }
    }

    // MARK: startup

    private var startupSection: some View {
        Section {
            ToggleRow(
                title: model.text("settings.general.login"),
                detail: model.text("settings.general.login.detail"),
                isOn: Binding(get: { model.loginSwitchIsOn }, set: { model.setOpenAtLogin($0) })
            )
            .disabled(!model.canChangeLogin)

            if model.login == .requiresApproval {
                LabeledContent {
                    Button(model.text("settings.general.login.openItems")) { model.openLoginItemsSettings() }
                } label: {
                    Label {
                        Text(model, "settings.general.login.approval")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text(model, "settings.general.startup")
        } footer: {
            // No footer at all when there is nothing to say, so no empty band is left between the sections.
            if !startupNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(startupNotes, id: \.self) { Text(verbatim: $0) }
                }
            }
        }
    }

    private var startupNotes: [String] {
        var notes: [String] = []
        if !model.menuBarAppRunning {
            notes.append(model.text("settings.needsMenuBarApp"))
        } else if model.login == .unavailable {
            notes.append(model.text("settings.general.login.unavailable"))
        }
        if let message = model.loginMessage { notes.append(message) }
        return notes
    }

    // MARK: language

    private var languageSection: some View {
        Section {
            Picker(selection: model.binding(\.language)) {
                Text(model, "settings.general.language.system").tag(String?.none)
                Divider()
                ForEach(model.languages) { language in
                    Text(verbatim: language.name).tag(String?.some(language.code))
                }
            } label: {
                Text(model, "settings.general.language")
            }
        }
    }

    // MARK: command line

    private var commandLineSection: some View {
        Section {
            ToggleRow(
                title: model.text("settings.general.commandLine.toggle"),
                detail: model.text("settings.general.commandLine.detail"),
                isOn: model.binding(\.commandLineControl)
            )
            if let path = model.commandLinePath {
                LabeledContent {
                    Button(model.text("settings.general.commandLine.copy")) { model.copyCommandLinePath() }
                } label: {
                    Text(verbatim: path)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text(model, "settings.general.commandLine")
        }
    }

    // MARK: reset

    private var resetSection: some View {
        Section {
            Button(role: .destructive) {
                confirmingReset = true
            } label: {
                Text(model, "settings.general.reset")
            }
        }
    }
}
