import SwiftUI

struct LidPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                ToggleRow(
                    title: model.text("settings.lid.lock"),
                    detail: model.text("settings.lid.lock.detail"),
                    isOn: model.binding(\.lockOnClose)
                )
                ToggleRow(
                    title: model.text("settings.lid.displayOff"),
                    detail: model.text("settings.lid.displayOff.detail"),
                    isOn: model.binding(\.displayOffOnClose)
                )
            } header: {
                SectionIntro(text: model.text("settings.lid.intro"))
            } footer: {
                Text(model, "settings.lid.footer")
            }
        }
        .formStyle(.grouped)
    }
}
