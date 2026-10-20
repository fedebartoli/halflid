import SwiftUI

struct NotificationsPane: View {
    @Bindable var model: SettingsModel

    private var enabled: Bool { model.preferences.notifications.enabled }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { enabled }, set: { model.setNotifications(enabled: $0) })) {
                    Text(model, "settings.notifications.master")
                }
                .disabled(!model.canChangeNotifications)
                accessRow
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if !model.menuBarAppRunning {
                        Text(model, "settings.needsMenuBarApp")
                    } else if model.notificationAccess == .notDetermined {
                        Text(model, "settings.notifications.status.undetermined")
                    } else if model.notificationAccess == .unavailable {
                        Text(model, "settings.notifications.status.unavailable")
                    }
                    Text(model, "settings.notifications.footer")
                }
            }

            Section {
                ToggleRow(title: model.text("settings.notifications.onStop"), isOn: model.binding(\.notifications.onStop))
                ToggleRow(title: model.text("settings.notifications.onWarning"), isOn: model.binding(\.notifications.onWarning))
                ToggleRow(title: model.text("settings.notifications.onHoldEnding"), isOn: model.binding(\.notifications.onHoldEnding))
                ToggleRow(title: model.text("settings.notifications.onWorkFinished"), isOn: model.binding(\.notifications.onWorkFinished))
            } header: {
                Text(model, "settings.notifications.when")
            }
            .disabled(!enabled)

            Section {
                Button(model.text("settings.notifications.test")) { model.sendTestNotification() }
                    .disabled(!model.canChangeNotifications || model.notificationAccess == .denied)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var accessRow: some View {
        switch model.notificationAccess {
        case .allowed:
            Label {
                Text(model, "settings.notifications.status.allowed")
            } icon: {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            .font(.footnote)
        case .denied:
            LabeledContent {
                Button(model.text("settings.notifications.openSettings")) { SystemLinks.openNotificationSettings() }
            } label: {
                Label {
                    Text(model, "settings.notifications.status.denied")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        case .notDetermined, .unavailable, .unknown, nil:
            EmptyView()
        }
    }
}
