import HalfLidCore
import SwiftUI

struct SafetyPane: View {
    @Bindable var model: SettingsModel

    private var limits: Limits { model.preferences.limits }

    var body: some View {
        Form {
            batterySection
            timeSection
            heatSection
            afterWorkSection
            Section {
                Button(model.text("settings.safety.restore")) { model.resetLimits() }
                    .disabled(limits == Limits())
            }
        }
        .formStyle(.grouped)
    }

    // MARK: sections

    private var batterySection: some View {
        Section {
            StepperRow(
                title: model.text("settings.safety.batteryWarn"),
                valueText: percent(limits.batteryWarnPercent),
                value: model.binding(\.limits.batteryWarnPercent),
                range: (limits.batteryStopPercent + 5)...90, step: 5
            )
            StepperRow(
                title: model.text("settings.safety.batteryStop"),
                valueText: percent(limits.batteryStopPercent),
                value: model.binding(\.limits.batteryStopPercent), range: 5...50, step: 5
            )
        } header: {
            VStack(alignment: .leading, spacing: 14) {
                SectionIntro(text: model.text("settings.safety.intro"))
                Text(model, "settings.safety.battery")
            }
        } footer: {
            Text(model, "settings.safety.battery.detail")
        }
    }

    private var timeSection: some View {
        Section {
            StepperRow(
                title: model.text("settings.safety.maxBattery"),
                valueText: hours(limits.maxHoursOnBattery),
                value: model.binding(\.limits.maxHoursOnBattery), range: 0.5...24, step: 0.5
            )
            StepperRow(
                title: model.text("settings.safety.maxAC"),
                valueText: hours(limits.maxHoursOnAC),
                value: model.binding(\.limits.maxHoursOnAC), range: 0.5...72, step: 0.5
            )
        } header: {
            Text(model, "settings.safety.time")
        } footer: {
            Text(model, "settings.safety.time.detail")
        }
    }

    private var heatSection: some View {
        Section {
            Picker(selection: model.binding(\.limits.thermalStopAt)) {
                ForEach([ThermalLevel.fair, .serious, .critical], id: \.self) { level in
                    Text(model, "settings.safety.thermal.\(level.rawValue)").tag(level)
                }
            } label: {
                Text(model, "settings.safety.thermal")
            }
            StepperRow(
                title: model.text("settings.safety.batteryTempWarn"),
                valueText: celsius(limits.batteryTempWarnC),
                value: model.binding(\.limits.batteryTempWarnC), range: 35...(limits.batteryTempStopC - 1), step: 1
            )
            StepperRow(
                title: model.text("settings.safety.batteryTempStop"),
                valueText: celsius(limits.batteryTempStopC),
                value: model.binding(\.limits.batteryTempStopC), range: 38...50, step: 1
            )
        } header: {
            Text(model, "settings.safety.heat")
        } footer: {
            Text(model, "settings.safety.heat.detail")
        }
    }

    private var afterWorkSection: some View {
        Section {
            StepperRow(
                title: model.text("settings.safety.grace"),
                valueText: model.text("settings.unit.minutes", ["value": String(graceMinutes.wrappedValue)]),
                value: graceMinutes, range: 1...60, step: 1
            )
        } header: {
            Text(model, "settings.safety.afterWork")
        } footer: {
            Text(model, "settings.safety.grace.detail")
        }
    }

    // MARK: values

    /// The wait is stored in seconds but chosen in whole minutes.
    private var graceMinutes: Binding<Int> {
        Binding(
            get: { max(1, Int((limits.idleGraceSeconds / 60).rounded())) },
            set: { model.set(\.limits.idleGraceSeconds, Double($0) * 60) }
        )
    }

    private func percent(_ value: Int) -> String {
        model.text("settings.unit.percent", ["value": String(value)])
    }

    private func hours(_ value: Double) -> String {
        model.text("settings.unit.hours", ["value": value.formatted(.number.precision(.fractionLength(0...1)))])
    }

    private func celsius(_ value: Double) -> String {
        model.text("settings.unit.celsius", ["value": value.formatted(.number.precision(.fractionLength(0...1)))])
    }
}
