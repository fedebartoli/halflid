import HalfLidCore
import SwiftUI

struct AgentsPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                ForEach(model.agents.agents, id: \.id) { agent in
                    AgentRow(model: model, agent: agent)
                }
            } header: {
                SectionIntro(text: model.text("settings.agents.intro"))
            } footer: {
                Text(model, "settings.agents.privacy")
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                model.refreshLive()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}

private struct AgentRow: View {
    let model: SettingsModel
    let agent: AgentDefinition

    var body: some View {
        let name = model.text("agent.\(agent.id)")
        let watched = model.isWatching(agent.id)
        let working = watched && model.published?.workingAgents.contains(agent.id) == true

        HStack(spacing: 12) {
            Image(nsImage: AgentIcon.image(for: agent, name: name, side: 32, dimmed: !watched, resources: model.resources))
                .resizable()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                Text(verbatim: model.text(agent.id == "cursor" ? "settings.agents.cursor" : "settings.agents.cli"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Said plainly until someone has tried the agent on a real install (`verified` in agents.json).
                if !agent.verified {
                    Text(verbatim: model.text("settings.agents.untested"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if working {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(model, "settings.agents.workingNow")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { watched }, set: { model.setWatching(agent.id, $0) })) {
                Text(verbatim: model.text("panel.watch", ["agent": name]))
            }
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }
}
