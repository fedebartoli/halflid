import SwiftUI

/// A switch with a short explanation under its name, as in System Settings.
struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                if let detail {
                    Text(verbatim: detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A number with a stepper at the right edge. The value is shown as text so it can carry its unit.
struct StepperRow<Value: Strideable>: View {
    let title: String
    let valueText: String
    @Binding var value: Value
    let range: ClosedRange<Value>
    let step: Value.Stride

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Text(verbatim: valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Stepper(value: $value, in: range, step: step) {
                    Text(verbatim: title)
                }
                .labelsHidden()
                .accessibilityValue(valueText)
            }
        } label: {
            Text(verbatim: title)
        }
    }
}

/// A small muted line of explanation.
struct Note: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The short paragraph that opens a pane, above its first group (in the place System Settings puts it).
struct SectionIntro: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(.callout)
            .fontWeight(.regular)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// An explanation with its action under it, so the text keeps the full width of the pane.
struct ActionRow: View {
    let text: String
    let buttonTitle: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle, action: action)
                .disabled(disabled)
        }
        .padding(.vertical, 2)
    }
}
